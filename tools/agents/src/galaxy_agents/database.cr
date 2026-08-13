require "db"
require "sqlite3"
require "file_utils"

module GalaxyAgents
  # SQLite database for agent lifecycle tracking
  # Location: ~/.claude/galaxy/data/agents.db
  #
  # Provides:
  # - Schema creation and migration
  # - Agent records with session reference
  # - Backup and prune operations
  module Database
    DATABASE_PATH = GalaxyAgents::DATA_DIR / "agents.db"

    def self.database_path : Path
      Path.new(
        ENV.fetch(
          "GALAXY_AGENTS_DATABASE_PATH",
          DATABASE_PATH.to_s,
        ),
      )
    end

    def self.open(&)
      ensure_database_exists
      DB.open("sqlite3://#{database_path}") do |db|
        db.exec("PRAGMA busy_timeout=5000")
        db.exec("PRAGMA journal_mode=WAL")
        db.exec("PRAGMA foreign_keys=ON")
        Migrations.migrate_database(db)
        yield db
      end
    end

    def self.ensure_database_exists
      db_path = database_path
      data_dir = db_path.parent
      Dir.mkdir_p(data_dir) unless Dir.exists?(data_dir)
      unless File.exists?(db_path)
        create_schema
      end
    end

    def self.create_schema
      db_path = database_path
      data_dir = db_path.parent
      Dir.mkdir_p(data_dir) unless Dir.exists?(data_dir)

      DB.open("sqlite3://#{db_path}") do |db|
        db.exec(<<-SQL)
          CREATE TABLE IF NOT EXISTS schema_info (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        SQL

        db.exec(<<-SQL)
          CREATE TABLE IF NOT EXISTS agents (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ledger_session_id INTEGER NOT NULL,
            agent_id TEXT NOT NULL,
            agent_type TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'running',
            description TEXT,
            started_at TEXT NOT NULL
              DEFAULT (datetime('now')),
            completed_at TEXT,
            duration_ms INTEGER,
            prompt TEXT,
            last_message TEXT,
            transcript_path TEXT,
            created_at TEXT NOT NULL
              DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL
              DEFAULT (datetime('now')),
            UNIQUE(ledger_session_id, agent_id)
          )
        SQL

        db.exec(<<-SQL)
          CREATE INDEX IF NOT EXISTS
            idx_agents_session
          ON agents(ledger_session_id)
        SQL

        db.exec(<<-SQL)
          CREATE INDEX IF NOT EXISTS
            idx_agents_status
          ON agents(status)
        SQL

        db.exec(<<-SQL)
          CREATE INDEX IF NOT EXISTS
            idx_agents_agent_id
          ON agents(agent_id)
        SQL

        Migrations.set_database_version(
          db, GalaxyAgents::VERSION,
        )
      end
    end

    def self.database_file_size : Int64
      path = database_path
      return 0_i64 unless File.exists?(path)
      File.size(path)
    rescue
      0_i64
    end

    # ========================================================
    # Agent Operations
    # ========================================================

    # Upsert an agent with status=running.
    #
    # On conflict the row is returned to running and its
    # completion fields cleared, because the only thing that
    # runs this is an agent actually starting: a resumed
    # subagent is running again, whatever it was before.
    # Leaving the status alone made a stopped row read
    # 'stopped' forever, which defeated both lifecycle guards
    # at once — every later start looked like a fresh one and
    # published a duplicate, while the eventual stop looked
    # like a repeat of an already-terminal stop and published
    # nothing. An agent could therefore be started twice and
    # stopped never, as far as anything downstream could see.
    #
    # The incoming description is COALESCEd rather than
    # assigned because a resumed subagent re-runs this with
    # whatever the sidecar read returned that time —
    # frequently nothing, since MetaReader races the file
    # being written. Assigning would let a later start erase
    # a description an earlier one captured.
    def self.start_agent(
      ledger_session_id : Int64,
      agent_id : String,
      agent_type : String,
      description : String? = nil,
    ) : Int64?
      return nil if ledger_session_id <= 0

      begin
        open do |db|
          db.exec(
            <<-SQL,
              INSERT INTO agents (
                ledger_session_id, agent_id,
                agent_type, status, description
              )
              VALUES (?, ?, ?, 'running', ?)
              ON CONFLICT(ledger_session_id, agent_id)
              DO UPDATE SET
                status = 'running',
                completed_at = NULL,
                duration_ms = NULL,
                description = COALESCE(
                  excluded.description, description
                ),
                updated_at = datetime('now')
            SQL
            ledger_session_id,
            agent_id,
            agent_type,
            description,
          )
          db.query_one?(
            <<-SQL,
              SELECT id FROM agents
              WHERE ledger_session_id = ?
                AND agent_id = ?
            SQL
            ledger_session_id,
            agent_id,
            as: Int64,
          )
        end
      rescue
        nil
      end
    end

    TERMINAL_STATUSES = [
      "stopped", "failed", "abandoned",
    ]

    # A dropped completion write strands its row permanently and
    # reports nothing, so a lock held by a concurrent writer is
    # worth waiting out rather than swallowing. Retries sit on
    # top of the 5s busy_timeout each connection already sets.
    STOP_WRITE_ATTEMPTS = 3
    STOP_WRITE_BACKOFF  = 50.milliseconds

    # Update an existing agent to stopped/failed
    # status. Idempotent: if the agent is already in
    # a terminal state, selectively updates only
    # non-blank incoming fields without changing
    # status.
    def self.stop_agent(
      ledger_session_id : Int64,
      agent_id : String,
      status : String,
      prompt : String? = nil,
      last_message : String? = nil,
      transcript_path : String? = nil,
      duration_ms : Int64? = nil,
      # When the caller knows when this actually ended — a
      # recovered death reads the moment out of the agent's own
      # transcript — that beats stamping the moment we noticed.
      completed_at : String? = nil,
    ) : Bool
      return false if ledger_session_id <= 0

      attempt = 0
      loop do
        attempt += 1
        begin
          return stop_agent_once(
            ledger_session_id: ledger_session_id,
            agent_id: agent_id,
            status: status,
            prompt: prompt,
            last_message: last_message,
            transcript_path: transcript_path,
            duration_ms: duration_ms,
            completed_at: completed_at,
          )
        rescue
          # Out of attempts leaves the row running, for the
          # periodic reconcile to close later. That is still
          # better than the bare `rescue false` this replaced,
          # which gave a lock held for a millisecond the same
          # weight as a permanent failure.
          return false if attempt >= STOP_WRITE_ATTEMPTS
          sleep STOP_WRITE_BACKOFF
        end
      end
    end

    # One attempt at the completion write. Lets a locked
    # database raise, so the caller can decide to wait.
    private def self.stop_agent_once(
      ledger_session_id : Int64,
      agent_id : String,
      status : String,
      prompt : String?,
      last_message : String?,
      transcript_path : String?,
      duration_ms : Int64?,
      completed_at : String? = nil,
    ) : Bool
      open do |db|
        # Primary path: transition running -> terminal
        result = db.exec(
          <<-SQL,
              UPDATE agents
              SET status = ?,
                  completed_at =
                    COALESCE(?, datetime('now')),
                  duration_ms = ?,
                  prompt = ?,
                  last_message = ?,
                  transcript_path = ?,
                  updated_at = datetime('now')
              WHERE ledger_session_id = ?
                AND agent_id = ?
                AND status = 'running'
            SQL
          status,
          duration_ms,
          prompt,
          last_message,
          transcript_path,
          ledger_session_id,
          agent_id,
        )
        return true if result.rows_affected > 0

        # The session id is resolved again at stop time and can
        # land somewhere other than where the start recorded
        # it — a resumed session, a recycled pid, an absent env
        # var falling back to the parent pid. When that
        # happens the keyed update above matches nothing and
        # the row strands forever, silently, because the
        # dispatcher closes this process's stderr and nothing
        # anywhere records the miss.
        #
        # agent_id carries no session in it, so retrying on it
        # alone recovers the row. Guarded on being unambiguous:
        # the table's unique key is
        # (ledger_session_id, agent_id), which does not by
        # itself forbid one agent_id appearing under two
        # sessions, so a count of exactly one is what makes
        # this safe rather than the schema.
        orphan_matches = db.scalar(
          <<-SQL,
              SELECT COUNT(*) FROM agents
              WHERE agent_id = ? AND status = 'running'
            SQL
          agent_id,
        ).as(Int64)

        if orphan_matches == 1
          recovered = db.exec(
            <<-SQL,
                UPDATE agents
                SET status = ?,
                    completed_at =
                      COALESCE(?, datetime('now')),
                    duration_ms = ?,
                    prompt = ?,
                    last_message = ?,
                    transcript_path = ?,
                    updated_at = datetime('now')
                WHERE agent_id = ?
                  AND status = 'running'
              SQL
            status,
            completed_at,
            duration_ms,
            prompt,
            last_message,
            transcript_path,
            agent_id,
          )
          return true if recovered.rows_affected > 0
        end

        # Idempotent path: agent already terminal.
        # Selectively update only non-blank fields;
        # never overwrite existing values with blanks.
        existing_status = db.query_one?(
          <<-SQL,
              SELECT status FROM agents
              WHERE ledger_session_id = ?
                AND agent_id = ?
            SQL
          ledger_session_id,
          agent_id,
          as: String,
        )
        return false unless existing_status
        unless TERMINAL_STATUSES.includes?(
                 existing_status,
               )
          return false
        end

        db.exec(
          <<-SQL,
              UPDATE agents SET
                prompt = CASE
                  WHEN ? IS NOT NULL AND ? != ''
                  THEN ? ELSE prompt END,
                last_message = CASE
                  WHEN ? IS NOT NULL AND ? != ''
                  THEN ? ELSE last_message END,
                transcript_path = CASE
                  WHEN ? IS NOT NULL AND ? != ''
                  THEN ? ELSE transcript_path END,
                duration_ms = CASE
                  WHEN ? IS NOT NULL
                  THEN ? ELSE duration_ms END,
                updated_at = datetime('now')
              WHERE ledger_session_id = ?
                AND agent_id = ?
            SQL
          prompt, prompt, prompt,
          last_message, last_message, last_message,
          transcript_path, transcript_path,
          transcript_path,
          duration_ms, duration_ms,
          ledger_session_id,
          agent_id,
        )
        true
      end
    end

    # Bulk-update all running agents to abandoned.
    # Returns the list of abandoned agents (for
    # timeline/socket events).
    def self.abandon_running(
      ledger_session_id : Int64,
    ) : Array(Agent)
      abandoned = [] of Agent
      return abandoned if ledger_session_id <= 0

      begin
        open do |db|
          # Fetch running agents first
          db.query(
            <<-SQL,
              SELECT id, ledger_session_id, agent_id,
                     agent_type, status, description,
                     started_at, completed_at,
                     duration_ms, prompt, last_message,
                     transcript_path, created_at,
                     updated_at
              FROM agents
              WHERE ledger_session_id = ?
                AND status = 'running'
            SQL
            ledger_session_id,
          ) do |rs|
            rs.each do
              abandoned << Agent.from_row(rs)
            end
          end

          # Bulk update
          db.exec(
            <<-SQL,
              UPDATE agents
              SET status = 'abandoned',
                  completed_at = datetime('now'),
                  updated_at = datetime('now')
              WHERE ledger_session_id = ?
                AND status = 'running'
            SQL
            ledger_session_id,
          )
        end
      rescue
        # Return whatever we collected
      end
      abandoned
    end

    # Abandon a single running agent by agent_id.
    # Returns the pre-update Agent row when the transition
    # actually happened (status was 'running'), or nil when
    # the row doesn't exist or is already terminal.
    # Idempotent: callers can retry safely.
    #
    # Unlike `abandon_running`, this writes `duration_ms`
    # explicitly so JSON consumers (e.g. the SwiftUI detail
    # view) can render a concrete duration immediately
    # without re-deriving it from started_at.
    def self.abandon_agent(
      ledger_session_id : Int64,
      agent_id : String,
    ) : Agent?
      return nil if ledger_session_id <= 0

      begin
        open do |db|
          agent = db.query_one?(
            <<-SQL,
              SELECT id, ledger_session_id, agent_id,
                     agent_type, status, description,
                     started_at, completed_at,
                     duration_ms, prompt, last_message,
                     transcript_path, created_at,
                     updated_at
              FROM agents
              WHERE ledger_session_id = ?
                AND agent_id = ?
                AND status = 'running'
            SQL
            ledger_session_id,
            agent_id,
          ) do |rs|
            Agent.from_row(rs)
          end

          return nil unless agent

          duration_ms : Int64? = nil
          begin
            started = Time.parse_utc(
              agent.started_at, "%Y-%m-%d %H:%M:%S",
            )
            elapsed = Time.utc - started
            duration_ms = elapsed.total_milliseconds.to_i64
          rescue
            # Leave nil; UI still renders "—"
          end

          db.exec(
            <<-SQL,
              UPDATE agents
              SET status = 'abandoned',
                  completed_at = datetime('now'),
                  duration_ms = COALESCE(?, duration_ms),
                  updated_at = datetime('now')
              WHERE ledger_session_id = ?
                AND agent_id = ?
                AND status = 'running'
            SQL
            duration_ms,
            ledger_session_id,
            agent_id,
          )

          agent
        end
      rescue
        nil
      end
    end

    # A running row paired with the pid that owns its session.
    struct RunningOwner
      getter agent_id : String
      getter agent_type : String
      getter ledger_session_id : Int64
      getter owner_pid : Int64?
      # Carried so a declared death can be timed from when the
      # agent began rather than from when a sweep noticed.
      getter started_at : String

      def initialize(
        @agent_id, @agent_type,
        @ledger_session_id, @owner_pid, @started_at,
      )
      end
    end

    # The ledger database, read-only, for owner-pid resolution.
    #
    # Honours the same override the ledger tool itself reads, so
    # a spec or a relocated install points both at one file
    # rather than silently disagreeing about where the sessions
    # live.
    def self.ledger_database_path : Path
      Path.new(
        ENV.fetch(
          "GALAXY_LEDGER_DATABASE_PATH",
          (GalaxyAgents::DATA_DIR / "ledger.db").to_s,
        ),
      )
    end

    # Every running row, with the pid that owns its session.
    #
    # `ledger_sessions.current_claude_pid` is the only column that
    # names the owning process. It is tempting to reach instead
    # for `ledger_session_pids` and pick the registration nearest
    # the agent's start, on the theory that a resumed session
    # would otherwise be judged by a newer process than the one
    # that ran the agent. That was tried and it marked live agents
    # abandoned within a minute of starting.
    #
    # `ledger_session_pids` is not a handover log. It accumulates
    # EVERY pid that ever resolved to the session, including the
    # short-lived ones behind hook invocations — one real session
    # here held fifteen, arriving in bursts twenty seconds apart,
    # every one of them dead while the session ran on. The newest
    # registration is therefore usually an ephemeral corpse, and
    # judging by it sweeps agents that are running perfectly well.
    # A false sweep is unrecoverable, because `stop_agent` will
    # not move a terminal row back, so the agent completes and is
    # recorded as abandoned forever.
    #
    # The cost of this simpler rule is a miss, not a lie: an agent
    # stranded by a process that has since been replaced is judged
    # against the live replacement and kept. That leaves a count
    # too high, which the next honest sweep or a manual abandon
    # can still correct — the failure that cannot be corrected is
    # the one this avoids.
    #
    # Yields nil when the ledger has no row for the session at
    # all, which is itself proof that nothing is running.
    def self.running_with_owner_pids : Array(RunningOwner)
      rows = [] of RunningOwner
      ledger = ledger_database_path
      return rows unless File.exists?(ledger)

      begin
        open do |db|
          db.exec("ATTACH ? AS ledgerdb", ledger.to_s)
          begin
            db.query(<<-SQL) do |rs|
              SELECT a.agent_id, a.agent_type,
                     a.ledger_session_id,
                     (SELECT s.current_claude_pid
                        FROM ledgerdb.ledger_sessions s
                       WHERE s.id = a.ledger_session_id),
                     a.started_at
              FROM agents a
              WHERE a.status = 'running'
              ORDER BY a.id
            SQL
              rs.each do
                rows << RunningOwner.new(
                  rs.read(String),
                  rs.read(String),
                  rs.read(Int64),
                  rs.read(Int64?),
                  rs.read(String),
                )
              end
            end
          ensure
            db.exec("DETACH ledgerdb") rescue nil
          end
        end
      rescue
        # An unreadable ledger means liveness is unknowable, and
        # an unknowable owner must never be swept. Returning
        # nothing is the safe answer.
        return [] of RunningOwner
      end
      rows
    end

    # Running-agent counts keyed by ledger session id.
    #
    # Sessions with no running agents are absent rather than
    # zero — the caller knows which sessions it cares about and
    # reads a missing key as zero.
    def self.running_counts_by_session : Hash(Int64, Int64)
      counts = {} of Int64 => Int64
      begin
        open do |db|
          db.query(<<-SQL) do |rs|
            SELECT ledger_session_id, COUNT(*)
            FROM agents
            WHERE status = 'running'
            GROUP BY ledger_session_id
          SQL
            rs.each do
              counts[rs.read(Int64)] = rs.read(Int64)
            end
          end
        end
      rescue
        # An empty map is indistinguishable from "no agents
        # running", which is the conservative reading.
      end
      counts
    end

    # List agents for a session ordered by started_at.
    def self.list_agents(
      ledger_session_id : Int64,
      limit : Int32? = nil,
    ) : Array(Agent)
      agents = [] of Agent
      return agents if ledger_session_id <= 0

      begin
        open do |db|
          sql = <<-SQL
            SELECT id, ledger_session_id, agent_id,
                   agent_type, status, description,
                   started_at, completed_at,
                   duration_ms, prompt, last_message,
                   transcript_path, created_at,
                   updated_at
            FROM agents
            WHERE ledger_session_id = ?
            ORDER BY started_at ASC
          SQL
          sql += " LIMIT #{limit}" if limit
          db.query(
            sql,
            ledger_session_id,
          ) do |rs|
            rs.each do
              agents << Agent.from_row(rs)
            end
          end
        end
      rescue
        # Return empty on error
      end
      agents
    end

    # Get a single agent by session + agent_id.
    def self.get_agent(
      ledger_session_id : Int64,
      agent_id : String,
    ) : Agent?
      return nil if ledger_session_id <= 0

      begin
        open do |db|
          db.query_one?(
            <<-SQL,
              SELECT id, ledger_session_id, agent_id,
                     agent_type, status, description,
                     started_at, completed_at,
                     duration_ms, prompt, last_message,
                     transcript_path, created_at,
                     updated_at
              FROM agents
              WHERE ledger_session_id = ?
                AND agent_id = ?
            SQL
            ledger_session_id,
            agent_id,
          ) do |rs|
            Agent.from_row(rs)
          end
        end
      rescue
        nil
      end
    end

    # Count of all agents for a session.
    def self.agent_count(
      ledger_session_id : Int64,
    ) : Int32
      return 0 if ledger_session_id <= 0

      begin
        open do |db|
          db.query_one?(
            "SELECT COUNT(*) FROM agents " \
            "WHERE ledger_session_id = ?",
            ledger_session_id,
            as: Int64,
          ).try(&.to_i) || 0
        end
      rescue
        0
      end
    end

    # Count of running agents for a session.
    def self.running_count(
      ledger_session_id : Int64,
    ) : Int32
      return 0 if ledger_session_id <= 0

      begin
        open do |db|
          db.query_one?(
            "SELECT COUNT(*) FROM agents " \
            "WHERE ledger_session_id = ? " \
            "AND status = 'running'",
            ledger_session_id,
            as: Int64,
          ).try(&.to_i) || 0
        end
      rescue
        0
      end
    end

    # Count agents by status for stats.
    def self.status_counts(
      ledger_session_id : Int64,
    ) : Hash(String, Int32)
      counts = {
        "running"   => 0,
        "stopped"   => 0,
        "failed"    => 0,
        "abandoned" => 0,
      }
      return counts if ledger_session_id <= 0

      begin
        open do |db|
          db.query(
            "SELECT status, COUNT(*) FROM agents " \
            "WHERE ledger_session_id = ? " \
            "GROUP BY status",
            ledger_session_id,
          ) do |rs|
            rs.each do
              status = rs.read(String)
              count = rs.read(Int64).to_i
              counts[status] = count
            end
          end
        end
      rescue
        # Return zeroes
      end
      counts
    end

    # ========================================================
    # Backup Operations
    # ========================================================

    def self.vacuum_database : NamedTuple(
      before: Int64, after: Int64,
    )
      before = database_file_size
      begin
        open do |db|
          db.exec("VACUUM")
        end
      rescue
        return {before: before, after: before}
      end
      {before: before, after: database_file_size}
    end

    def self.backup(
      backup_dir : Path,
      session_id : Int64,
    ) : Path?
      today = Time.local.to_s("%Y-%m-%d")
      date_dir = backup_dir / today
      Dir.mkdir_p(date_dir) unless Dir.exists?(date_dir)

      backup_file = date_dir / "agents_#{session_id}.db"
      File.delete(backup_file) if File.exists?(backup_file)

      open do |db|
        db.exec("VACUUM INTO '#{backup_file}'")
      end

      backup_file
    rescue ex
      STDERR.puts(
        "[galaxy-agents] Backup failed: #{ex.message}",
      )
      nil
    end

    def self.prune_backups(
      backup_dir : Path,
      retention_days : Int32,
    ) : Int32
      return 0 unless Dir.exists?(backup_dir)

      cutoff = Time.local - retention_days.days
      pruned = 0

      Dir.each_child(backup_dir) do |entry|
        entry_path = backup_dir / entry
        next unless File.directory?(entry_path)

        begin
          dir_date = Time.parse(
            entry, "%Y-%m-%d", Time::Location.local,
          )
          if dir_date < cutoff
            FileUtils.rm_rf(entry_path)
            pruned += 1
          end
        rescue Time::Format::Error
          # Not a date-named directory
        end
      end

      pruned
    rescue ex
      STDERR.puts(
        "[galaxy-agents] Prune failed: #{ex.message}",
      )
      0
    end

    # ========================================================
    # Data Structs
    # ========================================================

    struct Agent
      getter id : Int64
      getter ledger_session_id : Int64
      getter agent_id : String
      getter agent_type : String
      getter status : String
      getter description : String?
      getter started_at : String
      getter completed_at : String?
      getter duration_ms : Int64?
      getter prompt : String?
      getter last_message : String?
      getter transcript_path : String?
      getter created_at : String
      getter updated_at : String

      def initialize(
        @id, @ledger_session_id, @agent_id,
        @agent_type, @status, @description,
        @started_at, @completed_at, @duration_ms,
        @prompt, @last_message, @transcript_path,
        @created_at, @updated_at,
      )
      end

      def self.from_row(rs) : Agent
        Agent.new(
          id: rs.read(Int64),
          ledger_session_id: rs.read(Int64),
          agent_id: rs.read(String),
          agent_type: rs.read(String),
          status: rs.read(String),
          description: rs.read(String?),
          started_at: rs.read(String),
          completed_at: rs.read(String?),
          duration_ms: rs.read(Int64?),
          prompt: rs.read(String?),
          last_message: rs.read(String?),
          transcript_path: rs.read(String?),
          created_at: rs.read(String),
          updated_at: rs.read(String),
        )
      end
    end
  end
end
