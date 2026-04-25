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
    # On conflict, updates the description and
    # updated_at but leaves other fields untouched.
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
                description = excluded.description,
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
    ) : Bool
      return false if ledger_session_id <= 0

      begin
        open do |db|
          # Primary path: transition running -> terminal
          result = db.exec(
            <<-SQL,
              UPDATE agents
              SET status = ?,
                  completed_at = datetime('now'),
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
      rescue
        false
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
