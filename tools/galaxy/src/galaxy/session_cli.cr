require "json"
require "option_parser"

module Galaxy
  # `galaxy session`: lets another program create, drive and watch Galaxy
  # sessions. Galaxy only delivers input, publishes events and enforces the
  # owner's lock; everything a driver decides stays with the driver.
  #
  # CONTRACT with Galaxy.app (the Swift side implements against this).
  #
  # Requests: one envelope line on galaxy.sock, one reply line back.
  #   {"v":1,"event":"session.<op>","ledger_session_id":0,
  #    "session_identifiers":[],"ts":<unix>,"detail_data":{...}}
  # Every reply is a JSON object: {"ok":true,...} or {"ok":false,"error":"…"}.
  #   session.create  {directory, persona?, name?, owner}
  #                   -> {ok, id, token, name, owner}
  #   session.lock    {id, token}               -> {ok, id, locked:true}
  #   session.release {id, token}               -> {ok, id, locked:false}
  #   session.send    {id, token, input}        -> {ok, id, input_id, duplicate}
  #       input: {"id": s, "message": s}
  #            | {"id": s, "summary"?: s, "notes": [{"quote","note"}]}
  #       Answered on acceptance (token, lock, input, id checked); recording
  #       and delivery follow, reported on the watch stream as
  #       session.input:sent (detail carries input_id) or
  #       session.input:failed {input_id}. A resent id with the same content
  #       is a duplicate (nothing happens); with different content, refused.
  #   session.clear   {id, token}               -> {ok, id}
  #   session.resume  {id, token, stop_holder}  -> {ok, id, accepted:true}
  #       held elsewhere, no stop_holder -> {ok:false, error, holder_pid}
  #       Answered once decided; the resume follows, reported as
  #       session:resumed or session.resume:failed {error}.
  #   session.stop    {id, token}               -> {ok, id}
  #   session.status  {id}                      -> {ok, session}
  #   session.list    {owner?, include_closed}  -> {ok, sessions:[session]}
  #   session: {id, name, owner, locked, last_locked_at, last_released_at,
  #     last_released_by ("owner"|"user"|null), running, in_turn,
  #     running_agents, inbox_depth, context_percentage, directory, persona,
  #     ledger_session_id, claude_session_id, closed}; times ISO 8601 UTC.
  #
  # Watching: galaxy-watch.sock, one connection per subscriber.
  #   client -> {"v":1,"subscribe":"<galaxy session id>"}   (then only reads)
  #   server -> {"v":1,"subscribed":"<id>"}  or  {"v":1,"error":"…"}, close
  #   server -> one WatchLine per event for that session:
  #   {"v":1,"event_id":<row id|null>,"type":"turn:completed",
  #    "session_id":"<id>","occurred_at":"2026-11-20T19:39:20Z"}
  #   type is the envelope event with any "timeline." prefix removed;
  #   event_id is that envelope's ref (the row id) for timeline.* events,
  #   null otherwise. Events with no row to read carry "detail":{...}.
  #   A slow subscriber may be disconnected; it reconnects and backfills,
  #   so dropping is always safe.
  module SessionCLI
    class Failure < Exception
    end

    EXIT_TIMEOUT = 2

    def self.run(args : Array(String))
      sub = args.first?
      rest = args.size > 1 ? args[1..] : [] of String
      case sub
      when nil, "help", "-h", "--help" then puts help
      when "new"                       then cmd_new(rest)
      when "lock"                      then cmd_token_op("lock", rest)
      when "release"                   then cmd_token_op("release", rest)
      when "clear"                     then cmd_token_op("clear", rest)
      when "stop"                      then cmd_token_op("stop", rest)
      when "resume"                    then cmd_resume(rest)
      when "send"                      then cmd_send(rest)
      when "status"                    then cmd_status(rest)
      when "list"                      then cmd_list(rest)
      when "read"                      then cmd_read(rest)
      when "wait"                      then cmd_watch(rest, stop_on_first: true)
      when "watch"                     then cmd_watch(rest, stop_on_first: false)
      else
        fail("unknown session command '#{sub}'. Run 'galaxy session help' for usage")
      end
    rescue ex : Failure
      STDERR.puts "Error: #{ex.message}"
      exit(1)
    end

    # --- commands ---

    private def self.cmd_new(args : Array(String))
      dir = Dir.current
      persona : String? = nil
      name : String? = nil
      owner : String? = nil
      parse(args, "new") do |p|
        p.on("--dir=DIR", "Working directory (default: current)") { |v| dir = v }
        p.on("--persona=NAME", "claude-persona persona") { |v| persona = v }
        p.on("--name=NAME", "Session name shown in Galaxy") { |v| name = v }
        p.on("--as=OWNER", "Owner name (required)") { |v| owner = v }
      end

      owner_name = owner.try(&.strip)
      fail("--as OWNER is required") if owner_name.nil? || owner_name.empty?
      directory = Path[dir].expand(home: true).to_s
      fail("no such directory: #{directory}") unless Dir.exists?(directory)
      if p = persona
        fail("no persona named '#{p}'") unless CLI.persona_file_exists?(p)
      end

      detail = {"directory" => JSON::Any.new(directory), "owner" => JSON::Any.new(owner_name)}
      persona.try { |v| detail["persona"] = JSON::Any.new(v) }
      name.try { |v| detail["name"] = JSON::Any.new(v) }
      print_reply(request("session.create", detail))
    end

    private def self.cmd_token_op(op : String, args : Array(String))
      id, token = id_and_token(args, op)
      print_reply(request("session.#{op}", token_detail(id, token)))
    end

    private def self.cmd_resume(args : Array(String))
      stop_holder = false
      id, token = id_and_token(args, "resume") do |p|
        p.on("--stop-holder", "Stop a process still holding the conversation") { stop_holder = true }
      end
      detail = token_detail(id, token)
      detail["stop_holder"] = JSON::Any.new(stop_holder)
      print_reply(request("session.resume", detail))
    end

    private def self.cmd_send(args : Array(String))
      positional = [] of String
      id, token = id_and_token(args, "send", positional)
      path = positional.first? || fail("send needs a JSON file: galaxy session send <id> --token T <file.json>")
      fail("no such file: #{path}") unless File.file?(path)

      case parsed = InputFile.parse(File.read(path))
      in Array(String)
        STDERR.puts "Error: #{path} is not a valid input file:"
        parsed.each { |problem| STDERR.puts "  #{problem}" }
        STDERR.puts InputFile::SHAPES
        exit(1)
      in InputFile::Parsed
        detail = token_detail(id, token)
        detail["input"] = JSON::Any.new(parsed.to_detail)
        print_reply(request("session.send", detail))
      end
    end

    private def self.cmd_status(args : Array(String))
      id = single_id(args, "status")
      reply = request("session.status", {"id" => JSON::Any.new(id)})
      puts (reply["session"]? || reply).to_json
    end

    private def self.cmd_list(args : Array(String))
      owner : String? = nil
      include_closed = false
      parse(args, "list") do |p|
        p.on("--owner=NAME", "Only sessions this owner created") { |v| owner = v }
        p.on("--include-closed", "Include closed sessions") { include_closed = true }
      end
      detail = {"include_closed" => JSON::Any.new(include_closed)}
      owner.try { |v| detail["owner"] = JSON::Any.new(v) }
      reply = request("session.list", detail)
      puts({"sessions" => reply["sessions"]? || JSON::Any.new([] of JSON::Any)}.to_json)
    end

    private def self.cmd_read(args : Array(String))
      after = 0_i64
      limit = TimelineReader::DEFAULT_LIMIT
      ledger_id : Int64? = nil
      positional = [] of String
      parse(args, "read", positional) do |p|
        p.on("--after=EVENT_ID", "Only events after this id") { |v| after = event_id(v, "--after") }
        p.on("--limit=N", "Most events to return (default #{limit})") do |v|
          n = v.to_i?
          fail("--limit needs a positive number") if n.nil? || n <= 0
          limit = n
        end
        p.on("--ledger-session-id=N", "Read without asking Galaxy (works while it is down)") do |v|
          ledger_id = v.to_i64? || fail("--ledger-session-id needs a number")
        end
      end
      id = positional.first? || fail("read needs a session id")

      lsid = ledger_id || ledger_session_id(id)
      events = if l = lsid
                 TimelineReader.events(l, after, limit) || fail("could not read the timeline (is galaxy-timeline installed at #{TIMELINE_BIN}?)")
               else
                 [] of JSON::Any # Claude Code has not started yet: nothing recorded
               end
      puts({"events" => events.map { |e| TimelineReader.readable(e) }}.to_json)
    end

    private def self.cmd_watch(args : Array(String), stop_on_first : Bool)
      name = stop_on_first ? "wait" : "watch"
      after : Int64? = nil
      events : String? = nil
      timeout : Time::Span? = nil
      positional = [] of String
      parse(args, name, positional) do |p|
        p.on("--after=EVENT_ID", "Backfill events after this id first") { |v| after = event_id(v, "--after") }
        p.on("--events=TYPES", "Comma list of types; a trailing * matches a prefix") { |v| events = v }
        if stop_on_first
          p.on("--timeout=SECONDS", "Give up after this long (exit #{EXIT_TIMEOUT})") do |v|
            seconds = v.to_f? || fail("--timeout needs a number of seconds")
            timeout = seconds.seconds
          end
        end
      end
      id = positional.first? || fail("#{name} needs a session id")

      # The ledger session id is looked up lazily and kept: a brand-new
      # session has none until Claude Code starts.
      lsid : Int64? = nil
      resolve = -> { lsid ||= session_status?(id).try(&.["ledger_session_id"]?).try(&.as_i64?) }
      backfill = ->(cursor : Int64) do
        if l = resolve.call
          TimelineReader.events(l, cursor, WatchClient::BACKFILL_PAGE).try(&.compact_map { |e| WatchLine.from_timeline(e, id) })
        else
          [] of WatchLine # no ledger session yet: nothing recorded to fill in
        end
      end
      # 0 when Galaxy says nothing has been recorded yet, so a later
      # reconnect fills in from the start rather than from whatever is
      # newest by then; nil when that cannot be told.
      latest = -> do
        if l = resolve.call
          TimelineReader.latest_id(l)
        elsif status = session_status?(id)
          status["ledger_session_id"]?.try(&.raw.nil?) ? 0_i64 : nil
        end
      end

      client = WatchClient.new(
        id, STDOUT, EventFilter.new(events), backfill, latest,
        stop_on_first: stop_on_first,
        deadline: timeout.try { |t| Time.monotonic + t },
      )
      case client.run(after)
      in WatchClient::Outcome::Matched      then exit(0)
      in WatchClient::Outcome::OutputClosed then exit(0)
      in WatchClient::Outcome::TimedOut     then exit(EXIT_TIMEOUT)
      in WatchClient::Outcome::Failed       then exit(1)
      end
    end

    # --- plumbing ---

    private def self.request(event : String, detail : Hash(String, JSON::Any)) : JSON::Any
      reply = begin
        SocketClient.request(event, detail)
      rescue SocketClient::NotRunning
        fail("Galaxy isn't running (nothing is listening at #{SocketClient.socket_path})")
      rescue SocketClient::TimedOut
        fail("timed out after #{SocketClient::READ_TIMEOUT.total_seconds.to_i}s waiting for Galaxy to answer #{event}: " \
             "Galaxy is running but not responding")
      rescue SocketClient::NoReply
        fail("Galaxy did not answer #{event}: this Galaxy may not support driven sessions")
      end
      unless reply["ok"]?.try(&.as_bool?)
        fail(reply["error"]?.try(&.as_s?) || "Galaxy refused #{event}")
      end
      reply
    end

    # The reply minus its ok flag: what a driver acts on.
    private def self.print_reply(reply : JSON::Any)
      fields = reply.as_h.reject { |k, _| k == "ok" }
      puts fields.to_json
    end

    private def self.ledger_session_id(id : String) : Int64?
      request("session.status", {"id" => JSON::Any.new(id)})["session"]?
        .try(&.["ledger_session_id"]?).try(&.as_i64?)
    end

    # For a watcher that keeps going through a Galaxy restart: the session's
    # status, or nil when Galaxy cannot answer.
    private def self.session_status?(id : String) : JSON::Any?
      reply = SocketClient.request?("session.status", {"id" => JSON::Any.new(id)})
      return nil unless reply && reply["ok"]?.try(&.as_bool?)
      reply["session"]?
    end

    private def self.token_detail(id : String, token : String) : Hash(String, JSON::Any)
      {"id" => JSON::Any.new(id), "token" => JSON::Any.new(token)}
    end

    private def self.id_and_token(
      args : Array(String),
      name : String,
      positional : Array(String) = [] of String,
      &extra : OptionParser ->
    ) : {String, String}
      token = ENV["GALAXY_SESSION_TOKEN"]?
      parse(args, name, positional) do |p|
        p.on("--token=TOKEN", "The token session new returned (or GALAXY_SESSION_TOKEN)") { |v| token = v }
        extra.call(p)
      end
      id = positional.shift? || fail("#{name} needs a session id")
      t = token
      fail("#{name} needs --token (or GALAXY_SESSION_TOKEN)") if t.nil? || t.empty?
      {id, t}
    end

    private def self.id_and_token(args : Array(String), name : String, positional : Array(String) = [] of String) : {String, String}
      id_and_token(args, name, positional) { }
    end

    private def self.single_id(args : Array(String), name : String) : String
      positional = [] of String
      parse(args, name, positional) { }
      positional.first? || fail("#{name} needs a session id")
    end

    private def self.parse(
      args : Array(String),
      name : String,
      positional : Array(String) = [] of String,
      &block : OptionParser ->
    )
      parser = OptionParser.new do |p|
        p.banner = "Usage: galaxy session #{name} [options]"
        block.call(p)
        p.on("-h", "--help", "Show this help") do
          puts p
          exit(0)
        end
        p.invalid_option { |flag| fail("unknown flag '#{flag}' for session #{name}") }
        p.missing_option { |flag| fail("#{flag} needs a value") }
        p.unknown_args { |before, after| positional.concat(before).concat(after) }
      end
      parser.parse(args.dup)
    end

    private def self.event_id(value : String, flag : String) : Int64
      id = value.to_i64?
      fail("#{flag} needs an event id") if id.nil? || id < 0
      id
    end

    private def self.fail(message : String) : NoReturn
      raise Failure.new(message)
    end

    def self.help : String
      <<-HELP
      galaxy session - Drive Galaxy sessions from another program

      USAGE:
        galaxy session new --as OWNER [--dir DIR] [--persona NAME] [--name NAME]
        galaxy session send    <id> --token T <file.json>
        galaxy session lock    <id> --token T
        galaxy session release <id> --token T
        galaxy session clear   <id> --token T
        galaxy session resume  <id> --token T [--stop-holder]
        galaxy session stop    <id> --token T
        galaxy session status  <id>
        galaxy session list    [--owner NAME] [--include-closed]
        galaxy session read    <id> [--after EVENT_ID] [--limit N]
        galaxy session wait    <id> [--after EVENT_ID] [--events TYPES] [--timeout SECONDS]
        galaxy session watch   <id> [--after EVENT_ID] [--events TYPES]

      A session made by `new` is driven: it is locked to its owner from the
      start, launches in vibe mode with no permission prompts, question UI or
      plan mode, and keeps that through /clear, handoff and resume. Only the
      owner, holding the token `new` printed, can lock, release, send, clear,
      resume or stop it, and send, clear, resume and stop also need the lock.
      Kelly can force the lock open from Galaxy's Ledger tab; lock again with
      the same token afterwards. --token may come from GALAXY_SESSION_TOKEN.

      SEND FILE (JSON, validated; every problem is reported):
        {"id": "lead-0007", "message": "Plain text, any length."}
        {"id": "lead-0008", "summary": "Optional overall comment.",
         "notes": [{"quote": "text being answered", "note": "the reply"}]}
      id is yours to choose: 1-128 characters of A-Z a-z 0-9 . _ : -, unique
      per session. send answers as soon as Galaxy accepts the input, before
      it is recorded: {"id","input_id","duplicate"}. Retrying is always safe:
      resend the same file, and a repeat of an id already accepted answers
      "duplicate": true without sending anything again. Reusing an id for
      different content is refused. The outcome arrives as an event:
      session.input:sent (its detail carries input_id) once it is recorded
      and handed to the session, or session.input:failed with
      {"input_id"} if it could not be, after which the id may be sent again.
      The session reads it through a short pointer, never typed raw.

      RESUME:
        resume answers once it has decided: refused with holder_pid when
        another process holds the conversation (unless --stop-holder), or
        {"accepted": true}. The resume itself follows, reported as
        session:resumed, or session.resume:failed with {"error"}.

      EVENTS:
        watch prints one JSON line per event and reconnects on its own; wait
        exits 0 after the first match, #{EXIT_TIMEOUT} on --timeout. Each line:
          {"v":1,"event_id":171809,"type":"turn:completed",
           "session_id":"<id>","occurred_at":"2026-11-20T19:39:20Z"}
        event_id is null for events with no timeline row; those Galaxy raises
        itself carry a "detail" object instead. Read details with
        `galaxy session read <id> --after <event_id>`. --events takes exact
        types or prefixes ending in *, e.g. turn:completed,lock:*,session:*

        Keep your own place in a session by what `read` returns, never by
        notification ids: notifications can arrive out of order, and the
        timeline cannot. Treat each notification as the signal to read.

      OUTPUT:
        Every command prints JSON. Errors go to stderr as "Error: ..." with
        exit status 1.
      HELP
    end
  end
end
