require "json"
require "db"
require "sqlite3"

module GalaxyAgents
  # Background work a subagent launched and has not yet heard back from.
  #
  # Claude Code fires SubagentStop whenever a subagent ends a turn, including
  # a turn that ends to wait on background work it started; the work's
  # completion notification wakes it and SubagentStart fires again. Work
  # outstanding at a stop is what tells that pause apart from finishing.
  #
  # Launches are read from the subagent's own transcript. Closes are read
  # from it and from every transcript of its session: a subagent that
  # finishes first has its notifications delivered to the parent instead,
  # and the parent may have moved to a new transcript by /clear since. A
  # TaskStop the agent issued closes work too. Of 49 finished subagents that
  # launched background work, 2 still had work no transcript ever closed,
  # which is what reconcile's maximum wait is for.
  module BackgroundWork
    LAUNCH_KEYS = ["backgroundTaskId", "taskId"]
    TASK_ID     = /<task-id>([^<]+)<\/task-id>/
    STOPPED_ID  = /"name":"TaskStop".*?"(?:task_id|shell_id)":"([^"]+)"/

    # Ids of the background work a transcript launched.
    def self.launched(path : String) : Set(String)
      ids = Set(String).new
      return ids unless File.exists?(path)

      File.each_line(path) do |line|
        next unless line.includes?(%("toolUseResult")) &&
                    (line.includes?("backgroundTaskId") ||
                    line.includes?(%("isAsync")) ||
                    line.includes?(%("taskId")))

        result = begin
          JSON.parse(line)["toolUseResult"]?.try(&.as_h?)
        rescue
          nil
        end
        next unless result

        LAUNCH_KEYS.each do |key|
          if id = result[key]?.try(&.as_s?)
            ids << id unless id.empty?
          end
        end
        if result["isAsync"]?.try(&.as_bool?)
          if id = result["agentId"]?.try(&.as_s?)
            ids << id unless id.empty?
          end
        end
      end
      ids
    rescue
      Set(String).new
    end

    # Ids a transcript records as finished: a task notification, whatever
    # its status, or an explicit TaskStop.
    #
    # Matched rather than parsed: parent transcripts reach several megabytes
    # and the sweep reads them per waiting row, so a line that cannot match
    # must cost a substring check.
    def self.closed(path : String) : Set(String)
      ids = Set(String).new
      return ids unless File.exists?(path)

      File.each_line(path) do |line|
        if line.includes?("task-notification")
          line.scan(TASK_ID) { |m| ids << m[1] }
        end
        if line.includes?(%("TaskStop"))
          line.scan(STOPPED_ID) { |m| ids << m[1] }
        end
      end
      ids
    rescue
      Set(String).new
    end

    # Launched by the subagent and closed in none of its session's
    # transcripts.
    def self.outstanding(
      agent_path : String,
      session_transcripts : Array(String),
    ) : Set(String)
      pending = launched(agent_path)
      return pending if pending.empty?

      ([agent_path] + session_transcripts).each do |path|
        pending -= closed(path)
        break if pending.empty?
      end
      pending
    end

    # Every transcript the subagent's session has had: the parent beside its
    # subagents directory, and one per identifier the ledger holds for the
    # session, which is how a /clear's new transcript is found.
    def self.session_transcripts(
      agent_path : String,
      ledger_session_id : Int64,
    ) : Array(String)
      session_dir = File.dirname(File.dirname(agent_path))
      project_dir = File.dirname(session_dir)
      paths = ["#{session_dir}.jsonl"]

      identifiers(ledger_session_id).each do |identifier|
        paths << File.join(project_dir, "#{identifier}.jsonl")
      end
      paths.uniq.select { |path| File.exists?(path) }
    rescue
      [] of String
    end

    # Whether the transcript has been left alone for at least `grace`. A
    # subagent woken by its work's notification writes within seconds, so a
    # quiet one is not about to be.
    def self.quiet?(path : String, grace : Time::Span) : Bool
      info = File.info?(path)
      return true unless info
      Time.utc - info.modification_time >= grace
    rescue
      false
    end

    private def self.identifiers(ledger_session_id : Int64) : Array(String)
      ledger = Database.ledger_database_path
      return [] of String unless File.exists?(ledger)

      ids = [] of String
      DB.open("sqlite3://#{ledger}?mode=ro") do |db|
        db.query(
          "SELECT session_identifier FROM ledger_session_identifiers " \
          "WHERE ledger_session_id = ?",
          ledger_session_id,
        ) do |rs|
          rs.each { ids << rs.read(String) }
        end
      end
      ids
    rescue
      [] of String
    end
  end
end
