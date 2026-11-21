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
  #   session.dismiss {id, token}               -> {ok, id, dismissed:true}
  #       Needs the lock and a stopped session; already dismissed answers
  #       the same. Recorded as session:dismissed {initiated_by}; watchers
  #       get that line, then Galaxy hangs up.
  #   session.restore {id, token}               -> {ok, id, dismissed:false}
  #       Back in the sidebar, stopped, still locked, without taking focus;
  #       already open answers the same. Recorded as session:restored.
  #   session.status  {id}                      -> {ok, session}
  #   session.list    {owner?, include_dismissed} -> {ok, sessions:[session]}
  #   session: {id, name, owner, locked, last_locked_at, last_released_at,
  #     last_released_by ("owner"|"user"|null), running, in_turn,
  #     running_agents, inbox_depth, context_percentage, directory, persona,
  #     ledger_session_id, claude_session_id, dismissed}; times ISO 8601 UTC.
  #   status answers for a dismissed session too, with dismissed:true.
  #
  # Input ready: a driven session records session:input-ready {opening_event_id
  # (row id|null), released_by_hand?} the first time after each launch it can
  # take a prompt: after a persona's opening turn or Galaxy's /galaxy:resume
  # turn, at once otherwise. new and resume wait for it (or session:exited)
  # on the watch socket unless --no-wait.
  #
  # Watching: galaxy-watch.sock, one connection per subscriber.
  #   client -> {"v":1,"subscribe":"<galaxy session id>"}   (then only reads)
  #   server -> {"v":1,"subscribed":"<id>"}  or  {"v":1,"error":"…"}, close
  #     ("session dismissed <id>" when the session has been dismissed)
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

    EXIT_TIMEOUT   = 2
    EXIT_DISMISSED = 3

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
      when "dismiss"                   then cmd_token_op("dismiss", rest)
      when "restore"                   then cmd_token_op("restore", rest)
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
      wait = true
      timeout : Time::Span? = nil
      parse(args, "new") do |p|
        p.on("--dir=DIR", "Working directory (default: current)") { |v| dir = v }
        p.on("--persona=NAME", "claude-persona persona") { |v| persona = v }
        p.on("--name=NAME", "Session name shown in Galaxy") { |v| name = v }
        p.on("--as=OWNER", "Owner name (required)") { |v| owner = v }
        p.on("--no-wait", "Answer at once, without waiting for the session to take input") { wait = false }
        p.on("--timeout=SECONDS", "Stop waiting after this long (exit #{EXIT_TIMEOUT})") { |v| timeout = seconds(v) }
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
      reply = request("session.create", detail)
      return print_reply(reply) unless wait
      # A new session has no earlier rows, so everything it records counts.
      finish_waiting(reply, reply["id"].as_s, 0_i64, timeout)
    end

    private def self.cmd_token_op(op : String, args : Array(String))
      id, token = id_and_token(args, op)
      print_reply(request("session.#{op}", token_detail(id, token)))
    end

    private def self.cmd_resume(args : Array(String))
      stop_holder = false
      wait = true
      timeout : Time::Span? = nil
      id, token = id_and_token(args, "resume") do |p|
        p.on("--stop-holder", "Stop a process still holding the conversation") { stop_holder = true }
        p.on("--no-wait", "Answer at once, without waiting for the session to take input") { wait = false }
        p.on("--timeout=SECONDS", "Stop waiting after this long (exit #{EXIT_TIMEOUT})") { |v| timeout = seconds(v) }
      end
      # Taken before asking, so the earlier launches' input-ready rows can't
      # end the wait.
      cursor = wait ? resume_cursor(id) : 0_i64
      detail = token_detail(id, token)
      detail["stop_holder"] = JSON::Any.new(stop_holder)
      reply = request("session.resume", detail)
      return print_reply(reply) unless wait
      finish_waiting(reply, id, cursor, timeout)
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
      include_dismissed = false
      parse(args, "list") do |p|
        p.on("--owner=NAME", "Only sessions this owner created") { |v| owner = v }
        p.on("--include-dismissed", "Include dismissed sessions") { include_dismissed = true }
      end
      detail = {"include_dismissed" => JSON::Any.new(include_dismissed)}
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

      client = watch_client(id, STDOUT, EventFilter.new(events), stop_on_first, timeout)
      case client.run(after)
      in WatchClient::Outcome::Matched      then exit(0)
      in WatchClient::Outcome::OutputClosed then exit(0)
      in WatchClient::Outcome::TimedOut     then exit(EXIT_TIMEOUT)
      in WatchClient::Outcome::Failed       then exit(1)
      in WatchClient::Outcome::Dismissed    then exit(stop_on_first ? EXIT_DISMISSED : 0)
      end
    end

    # --- waiting for input ---

    # Prints the reply with what the wait found: opening_event_id once the
    # session can take its first prompt, or input_ready:false and a reason
    # (the reply still carries the id and token a driver needs).
    private def self.finish_waiting(reply : JSON::Any, id : String, after : Int64, timeout : Time::Span?)
      case result = await_input_ready(id, after, timeout)
      in ReadyWait::Ready
        opening = result.opening_event_id.try { |v| JSON::Any.new(v) } || JSON::Any.new(nil)
        print_reply(reply, {"opening_event_id" => opening})
      in ReadyWait::NotReady
        print_reply(reply, {"input_ready" => JSON::Any.new(false)})
        STDERR.puts "Error: #{result.message}"
        exit(result.exit_code)
      end
    end

    private def self.await_input_ready(id : String, after : Int64, timeout : Time::Span?) : ReadyWait::Ready | ReadyWait::NotReady
      output = IO::Memory.new
      client = watch_client(id, output, EventFilter.new(ReadyWait::FILTER), true, timeout)
      case client.run(after)
      in WatchClient::Outcome::Matched
        line = output.to_s.lines.last?.try { |l| WatchLine.parse?(l) }
        return ReadyWait::NotReady.new("could not read the event that ended the wait", 1) unless line
        ReadyWait.decide(line.type, line.detail || row_detail(id, line.event_id))
      in WatchClient::Outcome::TimedOut
        ReadyWait::NotReady.new("timed out waiting for the session to be ready for input", EXIT_TIMEOUT)
      in WatchClient::Outcome::Dismissed
        ReadyWait::NotReady.new("the session was dismissed before it was ready for input", EXIT_DISMISSED)
      in WatchClient::Outcome::Failed, WatchClient::Outcome::OutputClosed
        ReadyWait::NotReady.new("could not watch the session to see it become ready for input", 1)
      end
    end

    # The newest row before a resume, so the wait counts only what this
    # launch records.
    private def self.resume_cursor(id : String) : Int64
      lsid = session_status?(id).try(&.["ledger_session_id"]?).try(&.as_i64?)
      return 0_i64 unless lsid
      TimelineReader.latest_id(lsid) ||
        fail("could not read the session's timeline to tell this resume's events from earlier ones; pass --no-wait to skip waiting")
    end

    # A timeline row's detail, for a line that arrived without one.
    private def self.row_detail(id : String, event_id : Int64?) : JSON::Any?
      return nil unless event_id
      lsid = session_status?(id).try(&.["ledger_session_id"]?).try(&.as_i64?)
      return nil unless lsid
      row = TimelineReader.events(lsid, event_id - 1, 1).try(&.first?)
      row.try { |r| TimelineReader.readable(r)["detail"] }
    end

    # The ledger session id is looked up lazily and kept: a brand-new session
    # has none until Claude Code starts.
    private def self.watch_client(
      id : String,
      output : IO,
      filter : EventFilter,
      stop_on_first : Bool,
      timeout : Time::Span?,
    ) : WatchClient
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

      WatchClient.new(
        id, output, filter, backfill, latest,
        stop_on_first: stop_on_first,
        deadline: timeout.try { |t| Time.monotonic + t },
      )
    end

    # --- plumbing ---

    private def self.seconds(value : String) : Time::Span
      s = value.to_f?
      fail("--timeout needs a positive number of seconds") if s.nil? || s <= 0
      s.seconds
    end

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
    private def self.print_reply(reply : JSON::Any, extra = {} of String => JSON::Any)
      fields = reply.as_h.reject { |k, _| k == "ok" }.merge(extra)
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
                               [--no-wait] [--timeout SECONDS]
        galaxy session send    <id> --token T <file.json>
        galaxy session lock    <id> --token T
        galaxy session release <id> --token T
        galaxy session clear   <id> --token T
        galaxy session resume  <id> --token T [--stop-holder] [--no-wait] [--timeout SECONDS]
        galaxy session stop    <id> --token T
        galaxy session dismiss <id> --token T
        galaxy session restore <id> --token T
        galaxy session status  <id>
        galaxy session list    [--owner NAME] [--include-dismissed]
        galaxy session read    <id> [--after EVENT_ID] [--limit N]
        galaxy session wait    <id> [--after EVENT_ID] [--events TYPES] [--timeout SECONDS]
        galaxy session watch   <id> [--after EVENT_ID] [--events TYPES]

      A session made by `new` is driven: it is locked to its owner from the
      start, launches in vibe mode with no permission prompts, question UI or
      plan mode, and keeps that through /clear, handoff and resume. Only the
      owner, holding the token `new` printed, can lock, release, send, clear,
      resume, stop, dismiss or restore it, and send, clear, resume, stop and
      dismiss also need the lock. --dir must be a folder Claude Code already
      trusts: nobody can answer the trust dialog in a locked session, so
      `new` refuses any other.
      Kelly can force the lock open from Galaxy's Ledger tab; lock again with
      the same token afterwards. --token may come from GALAXY_SESSION_TOKEN.

      STARTING UP:
        new and resume wait until the session can take its first prompt,
        then print their reply with "opening_event_id". A persona with an
        opening message runs it first, and a resume runs /galaxy:resume
        first; opening_event_id is that turn's row. After a persona's
        opening, read it and make your first message respond to it:
          galaxy session read <id> --after <opening_event_id - 1> --limit 1
        null means the session started quietly. The moment is recorded as
        session:input-ready. If the session exits first, the reply carries
        "input_ready": false, the reason goes to stderr and the exit status
        is 1 (#{EXIT_TIMEOUT} on --timeout). The id and token are printed
        either way. --no-wait answers at once, as before; a send made then
        still waits in Galaxy until the session can take it.

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
        resume is refused with holder_pid when another process holds the
        conversation (unless --stop-holder). Otherwise it waits as above and
        prints {"accepted": true, "opening_event_id": ...}; with --no-wait it
        answers {"accepted": true} at once, and the resume is reported as
        session:resumed, or session.resume:failed with {"error"}.

      STOPPING:
        A driven session's process exiting is reported as session:exited,
        once Galaxy has marked it stopped: {"initiated_by"} names "user" or
        "driver" when someone asked for the stop and is absent for a crash,
        with {"exit_code"} when known. Wait for session:exited, not
        session:ended, before dismiss or resume:
          galaxy session stop <id> --token T
          galaxy session wait <id> --events session:exited
          galaxy session dismiss <id> --token T
        Quitting Galaxy produces no session:exited; after a restart, status is
        what says a session is stopped.

      DISMISS AND RESTORE (the menu's Dismiss session / Restore Session...):
        dismiss takes a stopped session out of the sidebar into the dismissed
        archive, keeping its owner, lock and token; stop it first. restore
        brings it back, stopped and still locked, without taking focus; then
        resume it. Both answer {"id","dismissed"} and are safe to repeat.
        A dismissal, yours or Kelly's from the menu, is reported as
        session:dismissed with {"initiated_by"}: watch prints it and exits 0,
        wait exits #{EXIT_DISMISSED} unless it was waiting for that event.
        status and list --include-dismissed still report a dismissed session.

      EVENTS:
        watch prints one JSON line per event and reconnects on its own; wait
        exits 0 after the first match, #{EXIT_TIMEOUT} on --timeout, #{EXIT_DISMISSED} if the
        session is dismissed first. Each line:
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
