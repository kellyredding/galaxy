require "db"
require "sqlite3"
require "file_utils"

module GalaxyTimeline
  # SQLite database for timeline event storage
  # Location: ~/.claude/galaxy/data/timeline.db
  #
  # Provides:
  # - Schema creation and migration
  # - Event records with session reference (ledger_session_id)
  # - Backup and prune operations
  module Database
    # Database file path
    DATABASE_PATH = GalaxyTimeline::DATA_DIR / "timeline.db"

    # Get database path (allows override via env for testing)
    def self.database_path : Path
      Path.new(
        ENV.fetch(
          "GALAXY_TIMELINE_DATABASE_PATH",
          DATABASE_PATH.to_s,
        ),
      )
    end

    # Open a database connection (creates database and schema if needed)
    def self.open(&)
      ensure_database_exists
      DB.open("sqlite3://#{database_path}") do |db|
        # Set busy timeout FIRST — before any write operations that could
        # encounter a lock from concurrent processes.
        db.exec("PRAGMA busy_timeout=5000")
        db.exec("PRAGMA journal_mode=WAL")
        db.exec("PRAGMA foreign_keys=ON")
        # Run migrations if needed (checks version, runs migrations, updates version)
        Migrations.migrate_database(db)
        yield db
      end
    end

    # Ensure database file and schema exist
    def self.ensure_database_exists
      db_path = database_path
      data_dir = db_path.parent

      # Create data directory if needed
      Dir.mkdir_p(data_dir) unless Dir.exists?(data_dir)

      # Create database and schema if file doesn't exist
      unless File.exists?(db_path)
        create_schema
      end
    end

    # Create database schema
    # This creates a fresh database with the latest schema and stamps it with the current version.
    # For migrations from older versions, see the Migrations module.
    def self.create_schema
      db_path = database_path
      data_dir = db_path.parent
      Dir.mkdir_p(data_dir) unless Dir.exists?(data_dir)

      DB.open("sqlite3://#{db_path}") do |db|
        # Schema version tracking table
        db.exec(<<-SQL)
          CREATE TABLE IF NOT EXISTS schema_info (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        SQL

        # Events table — created_at and updated_at first, then business columns
        db.exec(<<-SQL)
          CREATE TABLE IF NOT EXISTS events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now')),
            ledger_session_id INTEGER NOT NULL,
            event_type TEXT NOT NULL,
            occurred_at TEXT NOT NULL DEFAULT (datetime('now')),
            detail_data TEXT,
            source TEXT NOT NULL,
            duration_identifier TEXT
          )
        SQL

        db.exec(<<-SQL)
          CREATE INDEX IF NOT EXISTS idx_events_session
          ON events(ledger_session_id)
        SQL

        db.exec(<<-SQL)
          CREATE INDEX IF NOT EXISTS idx_events_type
          ON events(event_type)
        SQL

        db.exec(<<-SQL)
          CREATE INDEX IF NOT EXISTS idx_events_occurred
          ON events(occurred_at)
        SQL

        db.exec(<<-SQL)
          CREATE INDEX IF NOT EXISTS
            idx_events_duration_identifier
          ON events(duration_identifier)
        SQL

        # Stamp with current version
        Migrations.set_database_version(db, GalaxyTimeline::VERSION)
      end
    end

    # Get the database file size in bytes.
    def self.database_file_size : Int64
      path = database_path
      return 0_i64 unless File.exists?(path)
      File.size(path)
    rescue
      0_i64
    end

    # ============================================================
    # Event Operations
    # ============================================================

    # Record a new timeline event. Returns the event ID on success, 0 on failure.
    def self.record_event(
      ledger_session_id : Int64,
      event_type : String,
      source : String,
      occurred_at : String? = nil,
      detail_data : String? = nil,
      duration_identifier : String? = nil,
    ) : Int64
      return 0_i64 if ledger_session_id <= 0
      return 0_i64 if event_type.empty?
      return 0_i64 if source.empty?

      begin
        open do |db|
          if ts = occurred_at
            db.exec(
              <<-SQL,
                INSERT INTO events (
                  ledger_session_id, event_type,
                  occurred_at, detail_data, source,
                  duration_identifier
                )
                VALUES (?, ?, ?, ?, ?, ?)
              SQL
              ledger_session_id,
              event_type,
              ts,
              detail_data,
              source,
              duration_identifier,
            )
          else
            db.exec(
              <<-SQL,
                INSERT INTO events (
                  ledger_session_id, event_type,
                  detail_data, source,
                  duration_identifier
                )
                VALUES (?, ?, ?, ?, ?)
              SQL
              ledger_session_id,
              event_type,
              detail_data,
              source,
              duration_identifier,
            )
          end

          id = db.query_one?(
            "SELECT last_insert_rowid()",
            as: Int64,
          ) || 0_i64
          id
        end
      rescue
        0_i64
      end
    end

    # List events for a session, ordered by occurred_at.
    def self.list_events(
      ledger_session_id : Int64,
      event_type : String? = nil,
      limit : Int32 = 5000,
    ) : Array(Event)
      events = [] of Event
      return events if ledger_session_id <= 0

      begin
        open do |db|
          if et = event_type
            db.query(
              <<-SQL,
                SELECT id, created_at, updated_at,
                       ledger_session_id, event_type,
                       occurred_at, detail_data, source,
                       duration_identifier
                FROM events
                WHERE ledger_session_id = ?
                  AND event_type = ?
                ORDER BY occurred_at ASC
                LIMIT ?
              SQL
              ledger_session_id,
              et,
              limit,
            ) do |rs|
              rs.each do
                events << Event.from_row(rs)
              end
            end
          else
            db.query(
              <<-SQL,
                SELECT id, created_at, updated_at,
                       ledger_session_id, event_type,
                       occurred_at, detail_data, source,
                       duration_identifier
                FROM events
                WHERE ledger_session_id = ?
                ORDER BY occurred_at ASC
                LIMIT ?
              SQL
              ledger_session_id,
              limit,
            ) do |rs|
              rs.each do
                events << Event.from_row(rs)
              end
            end
          end
        end
      rescue
        # Return empty on error
      end
      events
    end

    # Get a single event by ID.
    def self.get_event(id : Int64) : Event?
      return nil if id <= 0

      begin
        open do |db|
          db.query_one?(
            <<-SQL,
              SELECT id, created_at, updated_at,
                     ledger_session_id, event_type,
                     occurred_at, detail_data, source,
                     duration_identifier
              FROM events
              WHERE id = ?
            SQL
            id,
          ) do |rs|
            Event.from_row(rs)
          end
        end
      rescue
        nil
      end
    end

    # Update detail_data on an existing event (replace).
    # Returns true if the event was found and updated.
    def self.update_event(
      id : Int64,
      detail_data : String?,
    ) : Bool
      return false if id <= 0

      begin
        open do |db|
          result = db.exec(
            <<-SQL,
              UPDATE events
              SET detail_data = ?,
                  updated_at = datetime('now')
              WHERE id = ?
            SQL
            detail_data,
            id,
          )
          result.rows_affected > 0
        end
      rescue
        false
      end
    end

    # Delete an event by ID. Returns true if deleted.
    def self.delete_event(id : Int64) : Bool
      return false if id <= 0

      begin
        open do |db|
          result = db.exec(
            "DELETE FROM events WHERE id = ?",
            id,
          )
          result.rows_affected > 0
        end
      rescue
        false
      end
    end

    # Get event count for a session.
    def self.session_event_count(
      ledger_session_id : Int64,
    ) : Int32
      return 0 if ledger_session_id <= 0

      begin
        open do |db|
          db.query_one?(
            <<-SQL,
              SELECT COUNT(*)
              FROM events
              WHERE ledger_session_id = ?
            SQL
            ledger_session_id,
            as: Int64,
          ).try(&.to_i) || 0
        end
      rescue
        0
      end
    end

    # ============================================================
    # Backup Operations
    # ============================================================

    # Run VACUUM to reclaim disk space. Must be in its own connection.
    # Returns {before_bytes, after_bytes}.
    def self.vacuum_database : NamedTuple(before: Int64, after: Int64)
      before = database_file_size
      begin
        open do |db|
          db.exec("VACUUM")
        end
      rescue ex
        return {before: before, after: before}
      end
      {before: before, after: database_file_size}
    end

    # Create a point-in-time backup of the database using VACUUM INTO.
    # Returns the backup file path on success, nil on failure.
    #
    # Layout: backup_dir/YYYY-MM-DD/timeline_SESSION_ID.db
    #
    # VACUUM INTO acquires only a shared read lock (same as SELECT),
    # so it is safe to run while other processes write to the database.
    # The backup is a clean, compacted, standalone .db file with no
    # WAL or SHM sidecars.
    def self.backup(
      backup_dir : Path,
      session_id : Int64,
    ) : Path?
      today = Time.local.to_s("%Y-%m-%d")
      date_dir = backup_dir / today
      Dir.mkdir_p(date_dir) unless Dir.exists?(date_dir)

      backup_file = date_dir / "timeline_#{session_id}.db"

      # Skip if backup already exists (idempotent — same session starting twice)
      return backup_file if File.exists?(backup_file)

      open do |db|
        db.exec("VACUUM INTO '#{backup_file}'")
      end

      backup_file
    rescue ex
      STDERR.puts "[galaxy-timeline] Backup failed: #{ex.message}"
      nil
    end

    # Remove backup directories older than retention_days.
    # Returns the number of directories pruned.
    #
    # Only deletes directories whose names parse as dates. Non-date entries
    # in the backup directory are ignored.
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
          dir_date = Time.parse(entry, "%Y-%m-%d", Time::Location.local)
          if dir_date < cutoff
            FileUtils.rm_rf(entry_path)
            pruned += 1
          end
        rescue Time::Format::Error
          # Not a date-named directory — skip
        end
      end

      pruned
    rescue ex
      STDERR.puts "[galaxy-timeline] Prune failed: #{ex.message}"
      0
    end

    # ============================================================
    # Data Structs
    # ============================================================

    # A timeline event record from the database
    struct Event
      getter id : Int64
      getter created_at : String
      getter updated_at : String
      getter ledger_session_id : Int64
      getter event_type : String
      getter occurred_at : String
      getter detail_data : String?
      getter source : String
      getter duration_identifier : String?

      def initialize(
        @id,
        @created_at,
        @updated_at,
        @ledger_session_id,
        @event_type,
        @occurred_at,
        @detail_data,
        @source,
        @duration_identifier = nil,
      )
      end

      def self.from_row(rs) : Event
        Event.new(
          id: rs.read(Int64),
          created_at: rs.read(String),
          updated_at: rs.read(String),
          ledger_session_id: rs.read(Int64),
          event_type: rs.read(String),
          occurred_at: rs.read(String),
          detail_data: rs.read(String?),
          source: rs.read(String),
          duration_identifier: rs.read(String?),
        )
      end
    end
  end
end
