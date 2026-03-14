require "db"
require "sqlite3"
require "digest/sha256"
require "file_utils"
require "json"

module GalaxyLedger
  # SQLite database for persistent ledger storage
  # Location: ~/.claude/galaxy/data/ledger.db
  #
  # Provides:
  # - Schema creation with FTS5 full-text search
  # - Session records (ledger_sessions) with metrics and context
  # - Session identity mapping tables (identifiers + PIDs)
  # - Content hash deduplication (SHA256)
  # - File access tracking (ledger_session_files)
  # - Insert with ON CONFLICT DO NOTHING
  # - Query operations (by session, by type, FTS search)
  module Database
    # Database file path
    DATABASE_PATH = GalaxyLedger::GALAXY_DIR / "data" / "ledger.db"

    # Internal entry types excluded from all public-facing queries (list, search, count, etc.).
    # These are used for internal tracking only and should never be exposed to CLI users.
    INTERNAL_ENTRY_TYPES = [
      "extraction_marker",
      "guideline",
      "implementation_plan",
    ]

    # SQL fragments for excluding internal types from queries.
    # Pre-built at compile time for use in query strings.
    # Use the aliased version when the query uses a table alias (e.g., "e.entry_type").
    private INTERNAL_TYPES_LIST               = INTERNAL_ENTRY_TYPES.map { |t| "'#{t}'" }.join(", ")
    INTERNAL_TYPE_EXCLUSION_SQL       = "AND entry_type NOT IN (#{INTERNAL_TYPES_LIST})"
    INTERNAL_TYPE_EXCLUSION_ALIAS_SQL = "AND e.entry_type NOT IN (#{INTERNAL_TYPES_LIST})"

    # Get database path (allows override via env for testing)
    def self.database_path : Path
      if custom = ENV["GALAXY_LEDGER_DATABASE_PATH"]?
        Path.new(custom)
      else
        DATABASE_PATH
      end
    end

    # Generate SHA256 content hash for deduplication
    def self.content_hash(entry_type : String, content : String) : String
      Digest::SHA256.hexdigest("#{entry_type}:#{content}")
    end

    # Open a database connection (creates database and schema if needed)
    def self.open(&)
      ensure_database_exists
      DB.open("sqlite3://#{database_path}") do |db|
        # Set busy timeout FIRST — before any write operations that could
        # encounter a lock from concurrent processes (e.g., hook subprocesses).
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

        # Session records table
        db.exec(<<-SQL)
          CREATE TABLE IF NOT EXISTS ledger_sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            suggested_name TEXT,
            suggested_name_data TEXT NOT NULL DEFAULT '{}',
            current_session_identifier TEXT,
            current_claude_pid INTEGER,
            started_at TEXT DEFAULT (datetime('now')),
            updated_at TEXT DEFAULT (datetime('now')),
            cwd TEXT,
            project_dir TEXT,
            git_branch TEXT,
            model_id TEXT,
            model_display_name TEXT,
            claude_version TEXT,
            context_percentage REAL DEFAULT 0.0,
            tokens_used INTEGER DEFAULT 0,
            tokens_max INTEGER DEFAULT 0,
            cost_usd REAL DEFAULT 0.0,
            lines_added INTEGER DEFAULT 0,
            lines_removed INTEGER DEFAULT 0,
            context TEXT NOT NULL DEFAULT '{}',
            last_interaction TEXT
          )
        SQL

        # Session identifier mapping table (many-to-one: identifiers → session)
        db.exec(<<-SQL)
          CREATE TABLE IF NOT EXISTS ledger_session_identifiers (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ledger_session_id INTEGER NOT NULL,
            session_identifier TEXT NOT NULL UNIQUE,
            registered_at TEXT DEFAULT (datetime('now')),
            FOREIGN KEY (ledger_session_id) REFERENCES ledger_sessions(id) ON DELETE CASCADE
          )
        SQL

        # Session PID mapping table (many-to-one: PIDs → session)
        db.exec(<<-SQL)
          CREATE TABLE IF NOT EXISTS ledger_session_pids (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ledger_session_id INTEGER NOT NULL,
            claude_pid INTEGER NOT NULL UNIQUE,
            registered_at TEXT DEFAULT (datetime('now')),
            FOREIGN KEY (ledger_session_id) REFERENCES ledger_sessions(id) ON DELETE CASCADE
          )
        SQL

        # Main ledger entries table
        db.exec(<<-SQL)
          CREATE TABLE IF NOT EXISTS ledger_entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT DEFAULT (datetime('now')),
            ledger_session_id INTEGER NOT NULL,
            entry_type TEXT NOT NULL,
            source TEXT,
            content TEXT NOT NULL,
            content_hash TEXT NOT NULL,
            metadata TEXT,
            importance TEXT DEFAULT 'medium',
            category TEXT,
            keywords TEXT,
            applies_when TEXT,
            source_file TEXT,
            stale INTEGER DEFAULT 0,
            FOREIGN KEY (ledger_session_id) REFERENCES ledger_sessions(id) ON DELETE CASCADE
          )
        SQL

        # Session file access tracking table
        db.exec(<<-SQL)
          CREATE TABLE IF NOT EXISTS ledger_session_files (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ledger_session_id INTEGER NOT NULL,
            file_path TEXT NOT NULL,
            search_pattern TEXT NOT NULL DEFAULT '',
            is_read INTEGER DEFAULT 0,
            is_edited INTEGER DEFAULT 0,
            is_written INTEGER DEFAULT 0,
            is_searched INTEGER DEFAULT 0,
            first_seen_at TEXT DEFAULT (datetime('now')),
            last_seen_at TEXT DEFAULT (datetime('now')),
            access_count INTEGER DEFAULT 1,
            metadata TEXT,
            file_type TEXT NOT NULL DEFAULT 'other',
            UNIQUE(ledger_session_id, file_path, search_pattern),
            FOREIGN KEY (ledger_session_id) REFERENCES ledger_sessions(id) ON DELETE CASCADE
          )
        SQL

        # Daily usage tracking table (one record per session per UTC day)
        db.exec(<<-SQL)
          CREATE TABLE IF NOT EXISTS ledger_session_daily_usages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ledger_session_id INTEGER NOT NULL,
            date TEXT NOT NULL,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now')),
            baseline_cost_usd REAL NOT NULL DEFAULT 0.0,
            current_cost_usd REAL NOT NULL DEFAULT 0.0,
            cumulative_cost_usd REAL NOT NULL DEFAULT 0.0,
            baseline_tokens INTEGER NOT NULL DEFAULT 0,
            current_tokens INTEGER NOT NULL DEFAULT 0,
            cumulative_tokens INTEGER NOT NULL DEFAULT 0,
            oneshot_cost_usd REAL NOT NULL DEFAULT 0.0,
            oneshot_tokens INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY (ledger_session_id) REFERENCES ledger_sessions(id) ON DELETE CASCADE,
            UNIQUE(ledger_session_id, date)
          )
        SQL

        # Indexes for mapping tables
        db.exec("CREATE INDEX IF NOT EXISTS idx_session_ids_session ON ledger_session_identifiers(ledger_session_id)")
        db.exec("CREATE INDEX IF NOT EXISTS idx_session_pids_session ON ledger_session_pids(ledger_session_id)")

        # Indexes for ledger_entries
        db.exec("CREATE INDEX IF NOT EXISTS idx_entries_session ON ledger_entries(ledger_session_id)")
        db.exec("CREATE INDEX IF NOT EXISTS idx_entries_session_type ON ledger_entries(ledger_session_id, entry_type)")
        db.exec("CREATE INDEX IF NOT EXISTS idx_entries_source ON ledger_entries(source)")
        db.exec("CREATE INDEX IF NOT EXISTS idx_entries_created ON ledger_entries(created_at)")
        db.exec("CREATE INDEX IF NOT EXISTS idx_entries_importance ON ledger_entries(importance)")
        db.exec("CREATE INDEX IF NOT EXISTS idx_entries_category ON ledger_entries(category)")

        # Unique constraint for deduplication
        db.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_content_dedup ON ledger_entries(ledger_session_id, entry_type, content_hash)")

        # Snapshot table for preserving verbatim exchanges
        db.exec(<<-SQL)
          CREATE TABLE IF NOT EXISTS ledger_snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ledger_session_id INTEGER NOT NULL,
            number INTEGER NOT NULL,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now')),
            title TEXT NOT NULL,
            content TEXT NOT NULL,
            exchange_count INTEGER NOT NULL DEFAULT 1,
            char_count INTEGER NOT NULL DEFAULT 0,
            metadata TEXT,
            UNIQUE(ledger_session_id, number),
            FOREIGN KEY (ledger_session_id)
              REFERENCES ledger_sessions(id) ON DELETE CASCADE
          )
        SQL

        # Artifact table for session-produced documents
        db.exec(<<-SQL)
          CREATE TABLE IF NOT EXISTS ledger_artifacts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ledger_session_id INTEGER NOT NULL,
            number INTEGER NOT NULL,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now')),
            title TEXT NOT NULL,
            artifact_type TEXT NOT NULL,
            mime_type TEXT NOT NULL,
            original_filename TEXT NOT NULL,
            stored_path TEXT NOT NULL,
            source_path TEXT,
            file_size INTEGER NOT NULL DEFAULT 0,
            content_hash TEXT NOT NULL,
            description TEXT,
            metadata TEXT,
            UNIQUE(ledger_session_id, number),
            FOREIGN KEY (ledger_session_id)
              REFERENCES ledger_sessions(id) ON DELETE CASCADE
          )
        SQL

        # Indexes for ledger_session_daily_usages
        db.exec("CREATE INDEX IF NOT EXISTS idx_daily_usages_date ON ledger_session_daily_usages(date)")
        db.exec("CREATE INDEX IF NOT EXISTS idx_daily_usages_session ON ledger_session_daily_usages(ledger_session_id)")

        # Snapshot annotation table for inline annotations on snapshot content
        db.exec(<<-SQL)
          CREATE TABLE IF NOT EXISTS ledger_snapshot_annotations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now')),
            ledger_snapshot_id INTEGER NOT NULL,
            number INTEGER NOT NULL,
            start_line INTEGER NOT NULL,
            end_line INTEGER NOT NULL,
            content TEXT NOT NULL,
            UNIQUE(ledger_snapshot_id, number),
            FOREIGN KEY (ledger_snapshot_id)
              REFERENCES ledger_snapshots(id) ON DELETE CASCADE
          )
        SQL

        # Snapshot review table for batching annotations into review submissions
        db.exec(<<-SQL)
          CREATE TABLE IF NOT EXISTS ledger_snapshot_reviews (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now')),
            ledger_snapshot_id INTEGER NOT NULL,
            number INTEGER NOT NULL,
            reviewed_at TEXT,
            UNIQUE(ledger_snapshot_id, number),
            FOREIGN KEY (ledger_snapshot_id)
              REFERENCES ledger_snapshots(id) ON DELETE CASCADE
          )
        SQL

        # Add review FK to annotations (safe to run multiple times)
        begin
          db.exec(<<-SQL)
            ALTER TABLE ledger_snapshot_annotations
              ADD COLUMN ledger_snapshot_review_id INTEGER
              REFERENCES ledger_snapshot_reviews(id) ON DELETE SET NULL
          SQL
        rescue
          # Column already exists — ignore
        end

        # Indexes for ledger_snapshots
        db.exec("CREATE INDEX IF NOT EXISTS idx_snapshots_session ON ledger_snapshots(ledger_session_id)")

        # Indexes for ledger_snapshot_annotations
        db.exec("CREATE INDEX IF NOT EXISTS idx_snapshot_annotations_snapshot ON ledger_snapshot_annotations(ledger_snapshot_id)")

        # Indexes for ledger_snapshot_reviews
        db.exec("CREATE INDEX IF NOT EXISTS idx_snapshot_reviews_snapshot ON ledger_snapshot_reviews(ledger_snapshot_id)")

        # Indexes for ledger_artifacts
        db.exec("CREATE INDEX IF NOT EXISTS idx_artifacts_session ON ledger_artifacts(ledger_session_id)")
        db.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_artifacts_source_path ON ledger_artifacts(ledger_session_id, source_path) WHERE source_path IS NOT NULL")

        # Indexes for ledger_session_files
        db.exec("CREATE INDEX IF NOT EXISTS idx_files_session ON ledger_session_files(ledger_session_id)")

        # FTS5 full-text search
        db.exec(<<-SQL)
          CREATE VIRTUAL TABLE IF NOT EXISTS ledger_fts USING fts5(
            content,
            entry_type,
            category,
            keywords,
            source_file,
            content='ledger_entries',
            content_rowid='id'
          )
        SQL

        # Triggers to keep FTS in sync
        db.exec(<<-SQL)
          CREATE TRIGGER IF NOT EXISTS ledger_ai AFTER INSERT ON ledger_entries BEGIN
            INSERT INTO ledger_fts(rowid, content, entry_type, category, keywords, source_file)
            VALUES (new.id, new.content, new.entry_type, new.category, new.keywords, new.source_file);
          END
        SQL

        db.exec(<<-SQL)
          CREATE TRIGGER IF NOT EXISTS ledger_ad AFTER DELETE ON ledger_entries BEGIN
            INSERT INTO ledger_fts(ledger_fts, rowid, content, entry_type, category, keywords, source_file)
            VALUES('delete', old.id, old.content, old.entry_type, old.category, old.keywords, old.source_file);
          END
        SQL

        db.exec(<<-SQL)
          CREATE TRIGGER IF NOT EXISTS ledger_au AFTER UPDATE ON ledger_entries BEGIN
            INSERT INTO ledger_fts(ledger_fts, rowid, content, entry_type, category, keywords, source_file)
            VALUES('delete', old.id, old.content, old.entry_type, old.category, old.keywords, old.source_file);
            INSERT INTO ledger_fts(rowid, content, entry_type, category, keywords, source_file)
            VALUES (new.id, new.content, new.entry_type, new.category, new.keywords, new.source_file);
          END
        SQL

        # Stamp with current version (fresh installs get latest schema)
        Migrations.set_database_version(db, GalaxyLedger::VERSION)
      end
    end

    # ============================================================
    # Session Identity Resolution & Registration
    # ============================================================

    # Resolve a Claude session identifier to a ledger_session_id via mapping table.
    def self.resolve_session_identifier(session_identifier : String) : Int64?
      return nil if session_identifier.empty?

      begin
        open do |db|
          db.query_one?(
            "SELECT ledger_session_id FROM ledger_session_identifiers WHERE session_identifier = ?",
            session_identifier,
            as: Int64,
          )
        end
      rescue
        nil
      end
    end

    # Resolve a Claude Code PID to a ledger_session_id via mapping table.
    def self.resolve_claude_pid(claude_pid : Int64) : Int64?
      return nil if claude_pid <= 0

      begin
        open do |db|
          db.query_one?(
            "SELECT ledger_session_id FROM ledger_session_pids WHERE claude_pid = ?",
            claude_pid,
            as: Int64,
          )
        end
      rescue
        nil
      end
    end

    # Register a session identifier mapping (public, opens own connection).
    def self.register_session_identifier(ledger_session_id : Int64, session_identifier : String)
      return if ledger_session_id <= 0 || session_identifier.empty?

      begin
        open do |db|
          register_session_identifier_in(db, ledger_session_id, session_identifier)
        end
      rescue
        # Silently ignore
      end
    end

    # Register a PID mapping (public, opens own connection).
    def self.register_claude_pid(ledger_session_id : Int64, claude_pid : Int64)
      return if ledger_session_id <= 0 || claude_pid <= 0

      begin
        open do |db|
          register_claude_pid_in(db, ledger_session_id, claude_pid)
        end
      rescue
        # Silently ignore
      end
    end

    # Internal: register session identifier within an existing connection.
    # Wrapped in a transaction to make the check-then-write atomic,
    # preventing TOCTOU races when hooks and statusline fire concurrently.
    # Queries first to avoid burning autoincrement IDs on redundant
    # re-registrations (SQLite bumps the counter even on ON CONFLICT
    # no-ops).  Only INSERTs for genuinely new identifiers, UPDATEs
    # when an identifier moves to a different session.
    private def self.register_session_identifier_in(db, ledger_session_id : Int64, session_identifier : String)
      db.transaction do |tx|
        c = tx.connection
        existing = c.query_one?(
          "SELECT ledger_session_id FROM ledger_session_identifiers WHERE session_identifier = ?",
          session_identifier,
          as: Int64,
        )
        if existing == ledger_session_id
          next # Already mapped correctly
        elsif existing
          # Identifier moved to different session — update in place
          c.exec(
            "UPDATE ledger_session_identifiers SET ledger_session_id = ?, registered_at = datetime('now') WHERE session_identifier = ?",
            ledger_session_id,
            session_identifier,
          )
        else
          # New identifier
          c.exec(
            "INSERT INTO ledger_session_identifiers (ledger_session_id, session_identifier) VALUES (?, ?)",
            ledger_session_id,
            session_identifier,
          )
        end
      end
    end

    # Internal: register PID within an existing connection.
    # Wrapped in a transaction to make the check-then-write atomic,
    # preventing TOCTOU races when hooks and statusline fire concurrently.
    # Queries first to avoid burning autoincrement IDs on redundant
    # re-registrations (SQLite bumps the counter even on ON CONFLICT
    # no-ops).  Only INSERTs for genuinely new PIDs, UPDATEs when a
    # PID moves to a different session (stale PID recycling).
    private def self.register_claude_pid_in(db, ledger_session_id : Int64, claude_pid : Int64)
      db.transaction do |tx|
        c = tx.connection
        existing = c.query_one?(
          "SELECT ledger_session_id FROM ledger_session_pids WHERE claude_pid = ?",
          claude_pid,
          as: Int64,
        )
        if existing == ledger_session_id
          next # Already mapped correctly
        elsif existing
          # PID moved to different session — update in place
          c.exec(
            "UPDATE ledger_session_pids SET ledger_session_id = ?, registered_at = datetime('now') WHERE claude_pid = ?",
            ledger_session_id,
            claude_pid,
          )
        else
          # New PID
          c.exec(
            "INSERT INTO ledger_session_pids (ledger_session_id, claude_pid) VALUES (?, ?)",
            ledger_session_id,
            claude_pid,
          )
        end
      end
    end

    # Return all session identifiers registered to a session.
    def self.session_identifiers(ledger_session_id : Int64) : Array(String)
      return [] of String if ledger_session_id <= 0

      begin
        open do |db|
          results = [] of String
          db.query(
            "SELECT session_identifier FROM ledger_session_identifiers WHERE ledger_session_id = ?",
            ledger_session_id,
          ) do |rs|
            rs.each { results << rs.read(String) }
          end
          results
        end
      rescue
        [] of String
      end
    end

    # Return all Claude PIDs registered to a session.
    def self.session_pids(ledger_session_id : Int64) : Array(Int64)
      return [] of Int64 if ledger_session_id <= 0

      begin
        open do |db|
          results = [] of Int64
          db.query(
            "SELECT claude_pid FROM ledger_session_pids WHERE ledger_session_id = ?",
            ledger_session_id,
          ) do |rs|
            rs.each { results << rs.read(Int64) }
          end
          results
        end
      rescue
        [] of Int64
      end
    end

    # ============================================================
    # Session Record Operations
    # ============================================================

    # Create a new session record. Returns the integer PK (ledger_sessions.id).
    # Registers the session_identifier and optional claude_pid in mapping tables.
    def self.create_session(
      session_identifier : String,
      claude_pid : Int64? = nil,
      cwd : String? = nil,
      project_dir : String? = nil,
      git_branch : String? = nil,
    ) : Int64
      return 0_i64 if session_identifier.empty?

      begin
        open do |db|
          db.exec(
            <<-SQL,
              INSERT INTO ledger_sessions (current_session_identifier, current_claude_pid, cwd, project_dir, git_branch)
              VALUES (?, ?, ?, ?, ?)
            SQL
            session_identifier,
            claude_pid,
            cwd,
            project_dir,
            git_branch,
          )
          ledger_session_id = db.scalar("SELECT last_insert_rowid()").as(Int64)

          # Register mappings
          register_session_identifier_in(db, ledger_session_id, session_identifier)
          if pid = claude_pid
            register_claude_pid_in(db, ledger_session_id, pid)
          end

          ledger_session_id
        end
      rescue
        0_i64
      end
    end

    # Update an existing session record by PK.
    # Registers any new session_identifier or claude_pid in mapping tables.
    def self.update_session(
      ledger_session_id : Int64,
      session_identifier : String? = nil,
      claude_pid : Int64? = nil,
      cwd : String? = nil,
      project_dir : String? = nil,
      git_branch : String? = nil,
    ) : Bool
      return false if ledger_session_id <= 0

      begin
        open do |db|
          db.exec(
            <<-SQL,
              UPDATE ledger_sessions SET
                updated_at = datetime('now'),
                current_session_identifier = COALESCE(?, current_session_identifier),
                current_claude_pid = COALESCE(?, current_claude_pid),
                cwd = COALESCE(?, cwd),
                project_dir = COALESCE(?, project_dir),
                git_branch = COALESCE(?, git_branch)
              WHERE id = ?
            SQL
            session_identifier,
            claude_pid,
            cwd,
            project_dir,
            git_branch,
            ledger_session_id,
          )

          # Register new mappings if provided
          if sid = session_identifier
            register_session_identifier_in(db, ledger_session_id, sid)
          end
          if pid = claude_pid
            register_claude_pid_in(db, ledger_session_id, pid)
          end

          true
        end
      rescue
        false
      end
    end

    # Convenience: resolve an existing session by identifier, or create a new one.
    # Used by CLI commands (like `add`) that need a session to exist.
    def self.ensure_session(
      session_identifier : String,
      claude_pid : Int64? = nil,
      cwd : String? = nil,
      project_dir : String? = nil,
      git_branch : String? = nil,
    ) : Int64
      return 0_i64 if session_identifier.empty?

      # Try to resolve existing
      if id = resolve_session_identifier(session_identifier)
        return id
      end

      # Create new
      create_session(session_identifier, claude_pid: claude_pid, cwd: cwd, project_dir: project_dir, git_branch: git_branch)
    end

    # Update session metrics from a ContextStatus payload (received via stdin from statusline)
    def self.update_session_metrics(
      ledger_session_id : Int64,
      status : ContextStatus,
    ) : Bool
      return false if ledger_session_id <= 0

      begin
        open do |db|
          db.exec(
            <<-SQL,
              UPDATE ledger_sessions SET
                updated_at = datetime('now'),
                context = CASE
                  WHEN ? IS NOT NULL AND cwd IS NOT NULL AND ? != cwd
                    THEN json_set(context, '$.previous_cwd', cwd)
                  ELSE context
                END,
                cwd = COALESCE(?, cwd),
                project_dir = COALESCE(?, project_dir),
                git_branch = COALESCE(?, git_branch),
                model_id = COALESCE(?, model_id),
                model_display_name = COALESCE(?, model_display_name),
                claude_version = COALESCE(?, claude_version),
                context_percentage = COALESCE(?, context_percentage),
                tokens_used = COALESCE(?, tokens_used),
                tokens_max = COALESCE(?, tokens_max),
                cost_usd = COALESCE(?, cost_usd),
                lines_added = COALESCE(?, lines_added),
                lines_removed = COALESCE(?, lines_removed)
              WHERE id = ?
            SQL
            status.cwd,
            status.cwd,
            status.cwd,
            status.project_dir,
            status.git_branch,
            status.model_id,
            status.model_display_name,
            status.claude_version,
            status.percentage,
            status.tokens_used,
            status.tokens_max,
            status.cost_usd,
            status.lines_added,
            status.lines_removed,
            ledger_session_id,
          )

          # Record daily usage
          record_daily_usage(db, ledger_session_id, status)

          true
        end
      rescue
        false
      end
    end

    # Record daily usage for the current UTC day.
    # Uses dynamic baseline for both cost and tokens: each tick diffs
    # from the last observed value and accumulates positive deltas.
    # On reset (compaction/new process), the baseline resets to the
    # new value and previously accumulated totals are preserved.
    private def self.record_daily_usage(
      db : DB::Database,
      ledger_session_id : Int64,
      status : ContextStatus,
    )
      new_cost = status.cost_usd
      new_tokens = status.tokens_used

      # Skip if we don't have any values to record
      return if new_cost.nil? && new_tokens.nil?

      # Default nil values to 0
      cost_val = new_cost || 0.0
      tokens_val = new_tokens || 0_i64

      today = Time.utc.to_s("%Y-%m-%d")

      # Check for existing record today
      existing = db.query_one?(
        <<-SQL,
          SELECT id, baseline_cost_usd, current_cost_usd, cumulative_cost_usd,
                 baseline_tokens, current_tokens, cumulative_tokens
          FROM ledger_session_daily_usages
          WHERE ledger_session_id = ? AND date = ?
        SQL
        ledger_session_id, today,
      ) do |rs|
        {
          id:                  rs.read(Int64),
          baseline_cost_usd:   rs.read(Float64),
          current_cost_usd:    rs.read(Float64),
          cumulative_cost_usd: rs.read(Float64),
          baseline_tokens:     rs.read(Int64),
          current_tokens:      rs.read(Int64),
          cumulative_tokens:   rs.read(Int64),
        }
      end

      if existing.nil?
        # --- New day record ---
        # Look up previous day's current values as baseline
        prev = db.query_one?(
          <<-SQL,
            SELECT current_cost_usd, current_tokens
            FROM ledger_session_daily_usages
            WHERE ledger_session_id = ? AND date < ?
            ORDER BY date DESC LIMIT 1
          SQL
          ledger_session_id, today,
        ) do |rs|
          {cost: rs.read(Float64), tokens: rs.read(Int64)}
        end

        prev_cost = prev ? prev[:cost] : 0.0
        prev_tokens = prev ? prev[:tokens] : 0_i64

        # Cost: initial diff from previous day's final value
        cost_diff = cost_val - prev_cost
        if cost_diff < 0
          # Reset happened between days — cost_val is from a fresh process
          cost_diff = cost_val
        end
        cumulative_cost = cost_diff

        # Tokens: handle potential cross-day compaction
        token_diff = tokens_val - prev_tokens
        if token_diff < 0
          # Compaction happened between days — reset baseline
          token_diff = 0_i64
        end
        cumulative_tokens = token_diff

        # Store baselines as current values for dynamic diffing
        insert_baseline_cost = cost_val
        insert_baseline_tokens = tokens_val

        db.exec(
          <<-SQL,
            INSERT INTO ledger_session_daily_usages (
              ledger_session_id, date,
              baseline_cost_usd, current_cost_usd, cumulative_cost_usd,
              baseline_tokens, current_tokens, cumulative_tokens
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          SQL
          ledger_session_id, today,
          insert_baseline_cost, cost_val, cumulative_cost,
          insert_baseline_tokens, tokens_val, cumulative_tokens,
        )
      else
        # --- Existing record for today ---

        # Cost: incremental diff from dynamic baseline
        cost_diff = cost_val - existing[:baseline_cost_usd]
        if cost_diff >= 0
          cumulative_cost = existing[:cumulative_cost_usd] + cost_diff
          new_baseline_cost = cost_val
        else
          # Cost counter reset (new process) — preserve accumulated total
          # and add the new process's initial cost (already incurred but
          # not yet counted since this is our first observation of it)
          cumulative_cost = existing[:cumulative_cost_usd] + cost_val
          new_baseline_cost = cost_val
        end

        # Tokens: incremental diff from dynamic baseline
        token_diff = tokens_val - existing[:baseline_tokens]
        if token_diff >= 0
          cumulative_tokens = existing[:cumulative_tokens] + token_diff
          new_baseline_tokens = tokens_val
        else
          # Compaction detected — reset baseline, preserve cumulative
          cumulative_tokens = existing[:cumulative_tokens]
          new_baseline_tokens = tokens_val
        end

        db.exec(
          <<-SQL,
            UPDATE ledger_session_daily_usages SET
              baseline_cost_usd = ?,
              current_cost_usd = ?,
              cumulative_cost_usd = ?,
              baseline_tokens = ?,
              current_tokens = ?,
              cumulative_tokens = ?,
              updated_at = datetime('now')
            WHERE id = ?
          SQL
          new_baseline_cost, cost_val, cumulative_cost,
          new_baseline_tokens, tokens_val, cumulative_tokens,
          existing[:id],
        )
      end
    end

    # Record one-shot usage (cost and tokens) for a session.
    # Atomically increments the oneshot columns on the existing daily
    # record, or creates one if none exists yet (e.g., one-shots fire
    # before the first status line tick).
    def self.record_oneshot_usage(
      ledger_session_id : Int64,
      cost_usd : Float64,
      tokens : Int64,
    ) : Bool
      return false if ledger_session_id <= 0

      begin
        open do |db|
          today = Time.utc.to_s("%Y-%m-%d")

          # Check for existing record today
          existing_id = db.query_one?(
            "SELECT id FROM ledger_session_daily_usages WHERE ledger_session_id = ? AND date = ?",
            ledger_session_id, today,
            as: Int64,
          )

          if existing_id
            # Atomically increment oneshot columns
            db.exec(
              <<-SQL,
                UPDATE ledger_session_daily_usages SET
                  oneshot_cost_usd = oneshot_cost_usd + ?,
                  oneshot_tokens = oneshot_tokens + ?,
                  updated_at = datetime('now')
                WHERE id = ?
              SQL
              cost_usd,
              tokens,
              existing_id,
            )
          else
            # Create a new record with zero baseline/cumulative, only oneshot populated
            db.exec(
              <<-SQL,
                INSERT INTO ledger_session_daily_usages (
                  ledger_session_id, date,
                  baseline_cost_usd, current_cost_usd, cumulative_cost_usd,
                  baseline_tokens, current_tokens, cumulative_tokens,
                  oneshot_cost_usd, oneshot_tokens
                ) VALUES (?, ?, 0.0, 0.0, 0.0, 0, 0, 0, ?, ?)
              SQL
              ledger_session_id, today,
              cost_usd, tokens,
            )
          end

          true
        end
      rescue
        false
      end
    end

    # ============================================================
    # Daily Usage Aggregation Queries
    # ============================================================

    # Summary stats for a date range
    struct SpendSummary
      getter total_cost : Float64
      getter total_tokens : Int64
      getter active_days : Int32
      getter active_sessions : Int32

      def initialize(@total_cost, @total_tokens, @active_days, @active_sessions)
      end
    end

    # Daily breakdown row
    struct SpendDay
      getter date : String
      getter cost : Float64
      getter tokens : Int64

      def initialize(@date, @cost, @tokens)
      end
    end

    # Returns summary stats for a date range
    def self.spend_summary(from_date : String, to_date : String) : SpendSummary
      begin
        open do |db|
          total_cost = 0.0
          total_tokens = 0_i64
          active_days = 0
          active_sessions = 0

          db.query_one?(
            <<-SQL,
              SELECT
                COALESCE(SUM(cumulative_cost_usd + oneshot_cost_usd), 0.0) as total_cost,
                COALESCE(SUM(cumulative_tokens + oneshot_tokens), 0) as total_tokens,
                COUNT(DISTINCT date) as active_days,
                COUNT(DISTINCT ledger_session_id) as active_sessions
              FROM ledger_session_daily_usages
              WHERE date >= ? AND date <= ?
            SQL
            from_date, to_date,
          ) do |rs|
            total_cost = rs.read(Float64)
            total_tokens = rs.read(Int64)
            active_days = rs.read(Int64).to_i
            active_sessions = rs.read(Int64).to_i
          end

          SpendSummary.new(total_cost, total_tokens, active_days, active_sessions)
        end
      rescue
        SpendSummary.new(0.0, 0_i64, 0, 0)
      end
    end

    # Returns daily breakdown for a date range
    def self.spend_daily(from_date : String, to_date : String) : Array(SpendDay)
      days = [] of SpendDay
      begin
        open do |db|
          db.query(
            <<-SQL,
              SELECT
                date,
                SUM(cumulative_cost_usd + oneshot_cost_usd) as daily_cost,
                SUM(cumulative_tokens + oneshot_tokens) as daily_tokens
              FROM ledger_session_daily_usages
              WHERE date >= ? AND date <= ?
              GROUP BY date ORDER BY date
            SQL
            from_date, to_date,
          ) do |rs|
            rs.each do
              days << SpendDay.new(
                date: rs.read(String),
                cost: rs.read(Float64),
                tokens: rs.read(Int64),
              )
            end
          end
        end
      rescue
        # Return empty on error
      end
      days
    end

    # Returns average daily cost over a period
    def self.spend_avg_daily(from_date : String, to_date : String) : Float64
      begin
        open do |db|
          result = db.query_one?(
            <<-SQL,
              SELECT AVG(daily_cost) FROM (
                SELECT SUM(cumulative_cost_usd + oneshot_cost_usd) as daily_cost
                FROM ledger_session_daily_usages
                WHERE date >= ? AND date <= ?
                GROUP BY date
                HAVING daily_cost > 0
              )
            SQL
            from_date, to_date,
          ) do |rs|
            rs.read(Float64?)
          end
          result || 0.0
        end
      rescue
        0.0
      end
    end

    # Update the suggested name for a session.
    def self.update_suggested_name(ledger_session_id : Int64, name : String?) : Bool
      return false if ledger_session_id <= 0
      return false unless name

      begin
        open do |db|
          db.exec(
            "UPDATE ledger_sessions SET suggested_name = ?, updated_at = datetime('now') WHERE id = ?",
            name,
            ledger_session_id,
          )
          true
        end
      rescue
        false
      end
    end

    # Update the suggested name state machine data for a session.
    def self.update_suggested_name_data(ledger_session_id : Int64, data_json : String) : Bool
      return false if ledger_session_id <= 0

      begin
        open do |db|
          db.exec(
            "UPDATE ledger_sessions SET suggested_name_data = ?, updated_at = datetime('now') WHERE id = ?",
            data_json,
            ledger_session_id,
          )
          true
        end
      rescue
        false
      end
    end

    # Update both suggested name and state machine data atomically.
    def self.update_suggested_name_with_data(
      ledger_session_id : Int64,
      name : String?,
      data_json : String,
    ) : Bool
      return false if ledger_session_id <= 0

      begin
        open do |db|
          db.exec(
            "UPDATE ledger_sessions SET suggested_name = ?, suggested_name_data = ?, updated_at = datetime('now') WHERE id = ?",
            name,
            data_json,
            ledger_session_id,
          )
          true
        end
      rescue
        false
      end
    end

    # Update the last_interaction JSON for a session
    def self.update_session_last_interaction(ledger_session_id : Int64, json : String) : Bool
      return false if ledger_session_id <= 0

      begin
        open do |db|
          db.exec(
            "UPDATE ledger_sessions SET last_interaction = ?, updated_at = datetime('now') WHERE id = ?",
            json,
            ledger_session_id,
          )
          true
        end
      rescue
        false
      end
    end

    # Atomically stamp last_stop_cwd into the session's context JSON.
    # Uses json_set in SQL — no read-modify-write, safe against concurrent
    # writes from the status line (which uses the same json_set pattern for
    # previous_cwd).  WAL + busy_timeout serializes the two writers.
    def self.stamp_stop_cwd(ledger_session_id : Int64, cwd : String) : Bool
      return false if ledger_session_id <= 0 || cwd.empty?

      begin
        open do |db|
          db.exec(
            <<-SQL,
              UPDATE ledger_sessions SET
                context = json_set(context, '$.last_stop_cwd', ?),
                updated_at = datetime('now')
              WHERE id = ?
            SQL
            cwd,
            ledger_session_id,
          )
          true
        end
      rescue
        false
      end
    end

    # Merge a key/value into the session's context JSON column.
    # Uses json_set in SQL — no read-modify-write, safe against concurrent
    # writes from other hooks and the status line.
    # If write_once is true, only sets the key when it doesn't already exist.
    def self.merge_session_context(
      ledger_session_id : Int64,
      key : String,
      value : String,
      write_once : Bool = false,
    ) : Bool
      return false if ledger_session_id <= 0

      begin
        open do |db|
          if write_once
            # Atomic write-once: only set if key is absent in the JSON.
            # json_extract returns NULL for missing keys; existing keys
            # (even empty strings) are preserved.
            db.exec(
              <<-SQL,
                UPDATE ledger_sessions SET
                  context = CASE
                    WHEN json_extract(context, ?) IS NULL
                      THEN json_set(context, ?, ?)
                    ELSE context
                  END,
                  updated_at = datetime('now')
                WHERE id = ?
              SQL
              "$.#{key}",
              "$.#{key}",
              value,
              ledger_session_id,
            )
          else
            db.exec(
              <<-SQL,
                UPDATE ledger_sessions SET
                  context = json_set(context, ?, ?),
                  updated_at = datetime('now')
                WHERE id = ?
              SQL
              "$.#{key}",
              value,
              ledger_session_id,
            )
          end
          true
        end
      rescue
        false
      end
    end

    # Get a session record by PK
    def self.get_session_by_id(ledger_session_id : Int64) : SessionRecord?
      return nil if ledger_session_id <= 0

      begin
        open do |db|
          db.query_one?(
            <<-SQL,
              SELECT id, suggested_name, suggested_name_data, current_session_identifier, current_claude_pid, started_at, updated_at, cwd, project_dir,
                     git_branch, model_id, model_display_name, claude_version,
                     context_percentage, tokens_used, tokens_max, cost_usd,
                     lines_added, lines_removed, context, last_interaction
              FROM ledger_sessions
              WHERE id = ?
            SQL
            ledger_session_id,
          ) do |rs|
            SessionRecord.from_row(rs)
          end
        end
      rescue
        nil
      end
    end

    # Convenience: get a session record by identifier (resolves through mapping table)
    def self.get_session(session_identifier : String) : SessionRecord?
      return nil if session_identifier.empty?

      ledger_session_id = resolve_session_identifier(session_identifier)
      return nil unless ledger_session_id

      get_session_by_id(ledger_session_id)
    end

    # List session records, most recent first
    def self.list_sessions(limit : Int32 = 50) : Array(SessionRecord)
      sessions = [] of SessionRecord
      begin
        open do |db|
          db.query(
            <<-SQL,
              SELECT id, suggested_name, suggested_name_data, current_session_identifier, current_claude_pid, started_at, updated_at, cwd, project_dir,
                     git_branch, model_id, model_display_name, claude_version,
                     context_percentage, tokens_used, tokens_max, cost_usd,
                     lines_added, lines_removed, context, last_interaction
              FROM ledger_sessions
              ORDER BY updated_at DESC
              LIMIT ?
            SQL
            limit,
          ) do |rs|
            rs.each do
              sessions << SessionRecord.from_row(rs)
            end
          end
        end
      rescue
        # Return empty on error
      end
      sessions
    end

    # ============================================================
    # Session File Operations
    # ============================================================

    # Upsert a file access record for a session.
    # File ops dedup on (ledger_session_id, file_path, '').
    # Search ops dedup on (ledger_session_id, directory_path, pattern).
    def self.upsert_session_file(
      ledger_session_id : Int64,
      file_path : String,
      operation : Symbol,
      search_pattern : String = "",
      metadata : String? = nil,
      file_type : String = "other",
    ) : Bool
      return false if ledger_session_id <= 0 || file_path.empty?

      is_read = operation == :read ? 1 : 0
      is_edited = operation == :edit ? 1 : 0
      is_written = operation == :write ? 1 : 0
      is_searched = operation == :search ? 1 : 0

      begin
        open do |db|
          db.exec(
            <<-SQL,
              INSERT INTO ledger_session_files (
                ledger_session_id, file_path, search_pattern,
                is_read, is_edited, is_written, is_searched,
                metadata, file_type
              )
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
              ON CONFLICT (ledger_session_id, file_path, search_pattern) DO UPDATE SET
                is_read = MAX(ledger_session_files.is_read, excluded.is_read),
                is_edited = MAX(ledger_session_files.is_edited, excluded.is_edited),
                is_written = MAX(ledger_session_files.is_written, excluded.is_written),
                is_searched = MAX(ledger_session_files.is_searched, excluded.is_searched),
                last_seen_at = datetime('now'),
                access_count = ledger_session_files.access_count + 1,
                metadata = COALESCE(excluded.metadata, ledger_session_files.metadata)
            SQL
            ledger_session_id,
            file_path,
            search_pattern,
            is_read,
            is_edited,
            is_written,
            is_searched,
            metadata,
            file_type,
          )
          true
        end
      rescue
        false
      end
    end

    # Get all file access records for a session
    def self.session_files(ledger_session_id : Int64) : Array(SessionFile)
      files = [] of SessionFile
      return files if ledger_session_id <= 0

      begin
        open do |db|
          db.query(
            <<-SQL,
              SELECT id, ledger_session_id, file_path, search_pattern,
                     is_read, is_edited, is_written, is_searched,
                     first_seen_at, last_seen_at, access_count, metadata,
                     file_type
              FROM ledger_session_files
              WHERE ledger_session_id = ?
              ORDER BY last_seen_at DESC
            SQL
            ledger_session_id,
          ) do |rs|
            rs.each do
              files << SessionFile.from_row(rs)
            end
          end
        end
      rescue
        # Return empty on error
      end
      files
    end

    # ============================================================
    # Entry Operations
    # ============================================================

    # Insert an entry into the database
    # Returns true if inserted, false if duplicate (content_hash conflict)
    def self.insert(ledger_session_id : Int64, entry : Entry) : Bool
      return false if ledger_session_id <= 0
      return false unless entry.valid?

      hash = content_hash(entry.entry_type, entry.content)
      metadata_json = entry.metadata.try(&.to_json)
      kw = entry.keywords_array
      keywords_json = kw.empty? ? nil : kw.to_json

      begin
        open do |db|
          result = db.exec(
            <<-SQL,
              INSERT INTO ledger_entries (
                ledger_session_id, entry_type, source, content,
                content_hash, metadata, importance, created_at, category, keywords,
                applies_when, source_file
              )
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
              ON CONFLICT (ledger_session_id, entry_type, content_hash) DO NOTHING
            SQL
            ledger_session_id,
            entry.entry_type,
            entry.source,
            entry.content,
            hash,
            metadata_json,
            entry.importance,
            entry.created_at,
            entry.category,
            keywords_json,
            entry.applies_when,
            entry.source_file
          )
          result.rows_affected > 0
        end
      rescue
        false
      end
    end

    # Insert multiple entries (batch insert)
    # Returns count of entries actually inserted (excludes duplicates)
    def self.insert_many(ledger_session_id : Int64, entries : Array(Entry)) : Int32
      return 0 if ledger_session_id <= 0
      return 0 if entries.empty?

      inserted = 0
      begin
        open do |db|
          entries.each do |entry|
            next unless entry.valid?

            hash = content_hash(entry.entry_type, entry.content)
            metadata_json = entry.metadata.try(&.to_json)
            kw = entry.keywords_array
            keywords_json = kw.empty? ? nil : kw.to_json

            result = db.exec(
              <<-SQL,
                INSERT INTO ledger_entries (
                  ledger_session_id, entry_type, source, content,
                  content_hash, metadata, importance, created_at, category, keywords,
                  applies_when, source_file
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (ledger_session_id, entry_type, content_hash) DO NOTHING
              SQL
              ledger_session_id,
              entry.entry_type,
              entry.source,
              entry.content,
              hash,
              metadata_json,
              entry.importance,
              entry.created_at,
              entry.category,
              keywords_json,
              entry.applies_when,
              entry.source_file
            )
            inserted += 1 if result.rows_affected > 0
          end
        end
      rescue
        # Return count so far
      end
      inserted
    end

    # Delete a session and all associated data (entries + files + mappings cascade via FK)
    # Returns count of entries deleted
    def self.delete_session(ledger_session_id : Int64) : Int32
      return 0 if ledger_session_id <= 0

      begin
        open do |db|
          # Count entries before delete for return value
          count = db.scalar(
            "SELECT COUNT(*) FROM ledger_entries WHERE ledger_session_id = ?",
            ledger_session_id
          ).as(Int64).to_i

          # Delete from ledger_sessions — FK cascade handles entries + files + mappings
          db.exec("DELETE FROM ledger_sessions WHERE id = ?", ledger_session_id)

          count
        end
      rescue
        0
      end
    end

    # Convenience: delete a session by identifier (resolves through mapping table)
    def self.delete_session(session_identifier : String) : Int32
      return 0 if session_identifier.empty?

      ledger_session_id = resolve_session_identifier(session_identifier)
      return 0 unless ledger_session_id

      delete_session(ledger_session_id)
    end

    # Count all entries (excludes internal entry types)
    def self.count : Int32
      begin
        open do |db|
          db.scalar("SELECT COUNT(*) FROM ledger_entries WHERE 1=1 #{INTERNAL_TYPE_EXCLUSION_SQL}").as(Int64).to_i
        end
      rescue
        0
      end
    end

    # Count entries for a session (excludes internal entry types)
    def self.count_by_session(ledger_session_id : Int64) : Int32
      return 0 if ledger_session_id <= 0

      begin
        open do |db|
          db.scalar("SELECT COUNT(*) FROM ledger_entries WHERE ledger_session_id = ? #{INTERNAL_TYPE_EXCLUSION_SQL}", ledger_session_id).as(Int64).to_i
        end
      rescue
        0
      end
    end

    # Check if an extraction marker already exists for a source file in a session.
    # ============================================================
    # Query Operations
    # ============================================================

    # Query entries by session (most recent first, excludes internal entry types)
    def self.query_by_session(ledger_session_id : Int64, limit : Int32 = 100) : Array(StoredEntry)
      return [] of StoredEntry if ledger_session_id <= 0

      entries = [] of StoredEntry
      begin
        open do |db|
          db.query(
            <<-SQL,
              SELECT id, created_at, ledger_session_id, entry_type, source, content, content_hash, metadata, importance, category, keywords, applies_when, source_file
              FROM ledger_entries
              WHERE ledger_session_id = ? #{INTERNAL_TYPE_EXCLUSION_SQL}
              ORDER BY created_at DESC
              LIMIT ?
            SQL
            ledger_session_id,
            limit
          ) do |rs|
            rs.each do
              entries << StoredEntry.from_row(rs)
            end
          end
        end
      rescue
        # Return empty on error
      end
      entries
    end

    # Query entries by type for a session
    def self.query_by_type(ledger_session_id : Int64, entry_type : String, limit : Int32 = 100) : Array(StoredEntry)
      return [] of StoredEntry if ledger_session_id <= 0

      entries = [] of StoredEntry
      begin
        open do |db|
          db.query(
            <<-SQL,
              SELECT id, created_at, ledger_session_id, entry_type, source, content, content_hash, metadata, importance, category, keywords, applies_when, source_file
              FROM ledger_entries
              WHERE ledger_session_id = ? AND entry_type = ?
              ORDER BY created_at DESC
              LIMIT ?
            SQL
            ledger_session_id,
            entry_type,
            limit
          ) do |rs|
            rs.each do
              entries << StoredEntry.from_row(rs)
            end
          end
        end
      rescue
        # Return empty on error
      end
      entries
    end

    # Query entries by importance for a session
    def self.query_by_importance(ledger_session_id : Int64, importance : String, limit : Int32 = 100) : Array(StoredEntry)
      return [] of StoredEntry if ledger_session_id <= 0

      entries = [] of StoredEntry
      begin
        open do |db|
          db.query(
            <<-SQL,
              SELECT id, created_at, ledger_session_id, entry_type, source, content, content_hash, metadata, importance, category, keywords, applies_when, source_file
              FROM ledger_entries
              WHERE ledger_session_id = ? AND importance = ? #{INTERNAL_TYPE_EXCLUSION_SQL}
              ORDER BY created_at DESC
              LIMIT ?
            SQL
            ledger_session_id,
            importance,
            limit
          ) do |rs|
            rs.each do
              entries << StoredEntry.from_row(rs)
            end
          end
        end
      rescue
        # Return empty on error
      end
      entries
    end

    # Prepare FTS5 query with prefix matching
    def self.prepare_fts_query(query : String, prefix_match : Bool = true) : String
      return query unless prefix_match

      words = query.strip.split(/\s+/)
      words.map { |word|
        if word.ends_with?("*") || word.includes?(":") || word.starts_with?("-") || word.starts_with?("+")
          word
        else
          "#{word}*"
        end
      }.join(" ")
    end

    # Search options for filtering
    struct SearchOptions
      getter entry_type : String?
      getter importance : String?
      getter category : String?
      getter prefix_match : Bool

      def initialize(
        @entry_type : String? = nil,
        @importance : String? = nil,
        @category : String? = nil,
        @prefix_match : Bool = true,
      )
      end
    end

    # Full-text search across all entries with optional filters
    # Excludes internal entry types unless explicitly requested via entry_type filter.
    def self.search(
      query : String,
      limit : Int32 = 50,
      entry_type : String? = nil,
      importance : String? = nil,
      category : String? = nil,
      prefix_match : Bool = true,
    ) : Array(StoredEntry)
      return [] of StoredEntry if query.strip.empty?

      fts_query = prepare_fts_query(query, prefix_match)
      entries = [] of StoredEntry

      begin
        open do |db|
          sql = String.build do |s|
            s << <<-SQL
              SELECT e.id, e.created_at, e.ledger_session_id, e.entry_type, e.source, e.content, e.content_hash, e.metadata, e.importance, e.category, e.keywords, e.applies_when, e.source_file
              FROM ledger_entries e
              JOIN ledger_fts f ON e.id = f.rowid
              WHERE ledger_fts MATCH ?
            SQL
            s << (entry_type ? " AND e.entry_type = ?" : " #{INTERNAL_TYPE_EXCLUSION_ALIAS_SQL}")
            s << " AND e.importance = ?" if importance
            s << " AND e.category = ?" if category
            s << " ORDER BY rank LIMIT ?"
          end

          args = [fts_query] of DB::Any
          args << entry_type if entry_type
          args << importance if importance
          args << category if category
          args << limit

          db.query(sql, args: args) do |rs|
            rs.each do
              entries << StoredEntry.from_row(rs)
            end
          end
        end
      rescue
        # Return empty on error
      end
      entries
    end

    # Full-text search within a session with optional filters
    # (excludes internal entry types)
    def self.search_in_session(
      ledger_session_id : Int64,
      query : String,
      limit : Int32 = 50,
      entry_type : String? = nil,
      importance : String? = nil,
      category : String? = nil,
      prefix_match : Bool = true,
    ) : Array(StoredEntry)
      return [] of StoredEntry if ledger_session_id <= 0
      return [] of StoredEntry if query.strip.empty?

      fts_query = prepare_fts_query(query, prefix_match)
      entries = [] of StoredEntry

      begin
        open do |db|
          sql = String.build do |s|
            s << <<-SQL
              SELECT e.id, e.created_at, e.ledger_session_id, e.entry_type, e.source, e.content, e.content_hash, e.metadata, e.importance, e.category, e.keywords, e.applies_when, e.source_file
              FROM ledger_entries e
              JOIN ledger_fts f ON e.id = f.rowid
              WHERE e.ledger_session_id = ? AND ledger_fts MATCH ?
            SQL
            s << (entry_type ? " AND e.entry_type = ?" : " #{INTERNAL_TYPE_EXCLUSION_ALIAS_SQL}")

            s << " AND e.importance = ?" if importance
            s << " AND e.category = ?" if category
            s << " ORDER BY rank LIMIT ?"
          end

          args = [ledger_session_id, fts_query] of DB::Any
          args << entry_type if entry_type
          args << importance if importance
          args << category if category
          args << limit

          db.query(sql, args: args) do |rs|
            rs.each do
              entries << StoredEntry.from_row(rs)
            end
          end
        end
      rescue
        # Return empty on error
      end
      entries
    end

    # Get distinct session IDs with entry counts
    def self.session_stats : Array(SessionStat)
      stats = [] of SessionStat
      begin
        open do |db|
          db.query(
            <<-SQL
              SELECT e.ledger_session_id, COUNT(*) as entry_count, MAX(e.created_at) as last_entry
              FROM ledger_entries e
              WHERE 1=1 #{INTERNAL_TYPE_EXCLUSION_ALIAS_SQL}
              GROUP BY e.ledger_session_id
              ORDER BY last_entry DESC
            SQL
          ) do |rs|
            rs.each do
              stats << SessionStat.new(
                ledger_session_id: rs.read(Int64),
                entry_count: rs.read(Int64).to_i,
                last_entry: rs.read(String)
              )
            end
          end
        end
      rescue
        # Return empty on error
      end
      stats
    end

    # Query recent entries with optional type, importance, category, and session filters
    def self.query_recent_filtered(
      limit : Int32 = 100,
      entry_type : String? = nil,
      importance : String? = nil,
      category : String? = nil,
      ledger_session_id : Int64? = nil,
    ) : Array(StoredEntry)
      entries = [] of StoredEntry
      begin
        open do |db|
          sql = String.build do |s|
            s << <<-SQL
              SELECT id, created_at, ledger_session_id, entry_type, source, content, content_hash, metadata, importance, category, keywords, applies_when, source_file
              FROM ledger_entries
              WHERE 1=1
            SQL
            s << " AND ledger_session_id = ?" if ledger_session_id
            s << (entry_type ? " AND entry_type = ?" : " #{INTERNAL_TYPE_EXCLUSION_SQL}")
            s << " AND importance = ?" if importance
            s << " AND category = ?" if category
            s << " ORDER BY created_at DESC LIMIT ?"
          end

          args = [] of DB::Any
          args << ledger_session_id if ledger_session_id
          args << entry_type if entry_type
          args << importance if importance
          args << category if category
          args << limit

          db.query(sql, args: args) do |rs|
            rs.each do
              entries << StoredEntry.from_row(rs)
            end
          end
        end
      rescue
        # Return empty on error
      end
      entries
    end

    # ============================================================
    # Tiered Restoration Queries
    # ============================================================

    # Tier 1: Essential context that should always be restored
    struct Tier1Result
      getter high_importance_decisions : Array(StoredEntry)

      def initialize(@high_importance_decisions)
      end

      def total_count : Int32
        high_importance_decisions.size
      end
    end

    # Query Tier 1 essentials for a session
    def self.query_tier1(ledger_session_id : Int64, decision_limit : Int32 = 10) : Tier1Result
      decisions = [] of StoredEntry

      return Tier1Result.new(decisions) if ledger_session_id <= 0

      begin
        open do |db|
          db.query(
            <<-SQL,
              SELECT id, created_at, ledger_session_id, entry_type, source, content, content_hash, metadata, importance, category, keywords, applies_when, source_file
              FROM ledger_entries
              WHERE ledger_session_id = ? AND entry_type = 'decision' AND importance = 'high'
              ORDER BY created_at DESC
              LIMIT ?
            SQL
            ledger_session_id,
            decision_limit
          ) do |rs|
            rs.each { decisions << StoredEntry.from_row(rs) }
          end
        end
      rescue
        # Return empty on error
      end

      Tier1Result.new(decisions)
    end

    # Tier 2: Supporting context (learnings + medium decisions)
    struct Tier2Result
      getter learnings : Array(StoredEntry)
      getter medium_decisions : Array(StoredEntry)

      def initialize(@learnings, @medium_decisions)
      end

      def total_count : Int32
        learnings.size + medium_decisions.size
      end
    end

    # Query Tier 2 supporting context for a session
    def self.query_tier2(
      ledger_session_id : Int64,
      learnings_limit : Int32 = 5,
      decisions_limit : Int32 = 5,
    ) : Tier2Result
      learnings = [] of StoredEntry
      decisions = [] of StoredEntry

      return Tier2Result.new(learnings, decisions) if ledger_session_id <= 0

      begin
        open do |db|
          db.query(
            <<-SQL,
              SELECT id, created_at, ledger_session_id, entry_type, source, content, content_hash, metadata, importance, category, keywords, applies_when, source_file
              FROM ledger_entries
              WHERE ledger_session_id = ? AND entry_type = 'learning'
              ORDER BY created_at DESC
              LIMIT ?
            SQL
            ledger_session_id,
            learnings_limit
          ) do |rs|
            rs.each { learnings << StoredEntry.from_row(rs) }
          end

          db.query(
            <<-SQL,
              SELECT id, created_at, ledger_session_id, entry_type, source, content, content_hash, metadata, importance, category, keywords, applies_when, source_file
              FROM ledger_entries
              WHERE ledger_session_id = ? AND entry_type = 'decision' AND importance = 'medium'
              ORDER BY created_at DESC
              LIMIT ?
            SQL
            ledger_session_id,
            decisions_limit
          ) do |rs|
            rs.each { decisions << StoredEntry.from_row(rs) }
          end
        end
      rescue
        # Return empty on error
      end

      Tier2Result.new(learnings, decisions)
    end

    # Combined restoration query
    struct RestorationResult
      getter tier1 : Tier1Result
      getter tier2 : Tier2Result

      def initialize(@tier1, @tier2)
      end

      def total_count : Int32
        tier1.total_count + tier2.total_count
      end
    end

    # Query all restoration context for a session
    def self.query_for_restoration(
      ledger_session_id : Int64,
      tier1_decision_limit : Int32 = 10,
      tier2_learnings_limit : Int32 = 5,
      tier2_decisions_limit : Int32 = 5,
    ) : RestorationResult
      tier1 = query_tier1(ledger_session_id, tier1_decision_limit)
      tier2 = query_tier2(ledger_session_id, tier2_learnings_limit, tier2_decisions_limit)
      RestorationResult.new(tier1, tier2)
    end

    # ============================================================
    # Snapshot Operations
    # ============================================================

    # Save a snapshot of verbatim exchanges for a session.
    # Number is auto-assigned as session-scoped sequential (1, 2, 3, ...).
    # Returns the snapshot number (not the primary key).
    def self.save_snapshot(
      ledger_session_id : Int64,
      title : String,
      content : String,
      exchange_count : Int32 = 1,
      metadata : String? = nil,
    ) : Int32
      return 0 if ledger_session_id <= 0

      char_count = content.size

      begin
        open do |db|
          db.exec(
            <<-SQL,
              INSERT INTO ledger_snapshots (
                ledger_session_id, number, title, content,
                exchange_count, char_count, metadata
              )
              VALUES (
                ?, (SELECT COALESCE(MAX(number), 0) + 1 FROM ledger_snapshots WHERE ledger_session_id = ?),
                ?, ?, ?, ?, ?
              )
            SQL
            ledger_session_id,
            ledger_session_id,
            title,
            content,
            exchange_count,
            char_count,
            metadata,
          )
          # Retrieve the number that was just assigned
          db.query_one?(
            "SELECT number FROM ledger_snapshots WHERE id = last_insert_rowid()",
            as: Int64,
          ).try(&.to_i) || 0
        end
      rescue
        0
      end
    end

    # List all snapshots for a session, ordered by number (chronological).
    def self.list_snapshots(ledger_session_id : Int64, limit : Int32 = 50) : Array(Snapshot)
      snapshots = [] of Snapshot
      return snapshots if ledger_session_id <= 0

      begin
        open do |db|
          db.query(
            <<-SQL,
              SELECT id, ledger_session_id, number, created_at, updated_at,
                     title, content, exchange_count, char_count, metadata
              FROM ledger_snapshots
              WHERE ledger_session_id = ?
              ORDER BY number ASC
              LIMIT ?
            SQL
            ledger_session_id,
            limit,
          ) do |rs|
            rs.each do
              snapshots << Snapshot.from_row(rs)
            end
          end
        end
      rescue
        # Return empty on error
      end
      snapshots
    end

    # List snapshots with review counts for the index view.
    def self.list_snapshots_with_counts(
      ledger_session_id : Int64,
      limit : Int32 = 50,
    ) : Array(SnapshotListItem)
      items = [] of SnapshotListItem
      return items if ledger_session_id <= 0

      begin
        open do |db|
          db.query(
            <<-SQL,
              SELECT ls.id, ls.ledger_session_id, ls.number,
                     ls.created_at, ls.title,
                     ls.exchange_count, ls.char_count,
                     COUNT(sr.id) AS review_count
              FROM ledger_snapshots ls
              LEFT JOIN ledger_snapshot_reviews sr
                ON ls.id = sr.ledger_snapshot_id
              WHERE ls.ledger_session_id = ?
              GROUP BY ls.id
              ORDER BY ls.number ASC
              LIMIT ?
            SQL
            ledger_session_id,
            limit,
          ) do |rs|
            rs.each do
              items << SnapshotListItem.from_row(rs)
            end
          end
        end
      rescue
        # Return empty on error
      end
      items
    end

    # Get a snapshot by session + number (user-facing identifier).
    def self.get_snapshot_by_number(ledger_session_id : Int64, number : Int32) : Snapshot?
      return nil if ledger_session_id <= 0

      begin
        open do |db|
          db.query_one?(
            <<-SQL,
              SELECT id, ledger_session_id, number, created_at, updated_at,
                     title, content, exchange_count, char_count, metadata
              FROM ledger_snapshots
              WHERE ledger_session_id = ? AND number = ?
            SQL
            ledger_session_id,
            number,
          ) do |rs|
            Snapshot.from_row(rs)
          end
        end
      rescue
        nil
      end
    end

    # Delete a snapshot by session + number. Returns true if deleted.
    def self.delete_snapshot_by_number(ledger_session_id : Int64, number : Int32) : Bool
      return false if ledger_session_id <= 0

      begin
        open do |db|
          result = db.exec(
            "DELETE FROM ledger_snapshots WHERE ledger_session_id = ? AND number = ?",
            ledger_session_id,
            number,
          )
          result.rows_affected > 0
        end
      rescue
        false
      end
    end

    # Get snapshot stats for budget decisions without loading content.
    def self.session_snapshot_stats(ledger_session_id : Int64) : NamedTuple(count: Int32, total_chars: Int64)
      return {count: 0, total_chars: 0_i64} if ledger_session_id <= 0

      begin
        open do |db|
          count = 0
          total_chars = 0_i64

          db.query_one?(
            <<-SQL,
              SELECT COUNT(*), COALESCE(SUM(char_count), 0)
              FROM ledger_snapshots
              WHERE ledger_session_id = ?
            SQL
            ledger_session_id,
          ) do |rs|
            count = rs.read(Int64).to_i
            total_chars = rs.read(Int64)
          end

          {count: count, total_chars: total_chars}
        end
      rescue
        {count: 0, total_chars: 0_i64}
      end
    end

    # ============================================================
    # Snapshot Annotation Operations
    # ============================================================

    # Save a snapshot annotation. Number is auto-assigned as snapshot-scoped
    # sequential (1, 2, 3, ...). Returns the created annotation or nil on failure.
    def self.save_snapshot_annotation(
      ledger_snapshot_id : Int64,
      start_line : Int32,
      end_line : Int32,
      content : String,
    ) : SnapshotAnnotation?
      return nil if ledger_snapshot_id <= 0

      begin
        open do |db|
          db.exec(
            <<-SQL,
              INSERT INTO ledger_snapshot_annotations (
                ledger_snapshot_id, number, start_line, end_line, content
              )
              VALUES (
                ?,
                (SELECT COALESCE(MAX(number), 0) + 1 FROM ledger_snapshot_annotations WHERE ledger_snapshot_id = ?),
                ?, ?, ?
              )
            SQL
            ledger_snapshot_id,
            ledger_snapshot_id,
            start_line,
            end_line,
            content,
          )
          # Retrieve the full annotation that was just created
          db.query_one?(
            <<-SQL
              SELECT a.id, a.created_at, a.updated_at, a.ledger_snapshot_id,
                     a.number, a.start_line, a.end_line, a.content,
                     a.ledger_snapshot_review_id,
                     r.number AS review_number,
                     r.reviewed_at AS review_reviewed_at
              FROM ledger_snapshot_annotations a
              LEFT JOIN ledger_snapshot_reviews r
                ON a.ledger_snapshot_review_id = r.id
              WHERE a.id = last_insert_rowid()
            SQL
          ) do |rs|
            SnapshotAnnotation.from_row(rs)
          end
        end
      rescue
        nil
      end
    end

    # List all annotations for a snapshot, ordered by reading position.
    def self.list_snapshot_annotations(ledger_snapshot_id : Int64) : Array(SnapshotAnnotation)
      annotations = [] of SnapshotAnnotation
      return annotations if ledger_snapshot_id <= 0

      begin
        open do |db|
          db.query(
            <<-SQL,
              SELECT a.id, a.created_at, a.updated_at, a.ledger_snapshot_id,
                     a.number, a.start_line, a.end_line, a.content,
                     a.ledger_snapshot_review_id,
                     r.number AS review_number,
                     r.reviewed_at AS review_reviewed_at
              FROM ledger_snapshot_annotations a
              LEFT JOIN ledger_snapshot_reviews r
                ON a.ledger_snapshot_review_id = r.id
              WHERE a.ledger_snapshot_id = ?
              ORDER BY a.start_line ASC, a.end_line ASC, a.number ASC
            SQL
            ledger_snapshot_id,
          ) do |rs|
            rs.each do
              annotations << SnapshotAnnotation.from_row(rs)
            end
          end
        end
      rescue
        # Return empty on error
      end
      annotations
    end

    # Get a snapshot annotation by snapshot ID + number.
    def self.get_snapshot_annotation(ledger_snapshot_id : Int64, number : Int32) : SnapshotAnnotation?
      return nil if ledger_snapshot_id <= 0

      begin
        open do |db|
          db.query_one?(
            <<-SQL,
              SELECT a.id, a.created_at, a.updated_at, a.ledger_snapshot_id,
                     a.number, a.start_line, a.end_line, a.content,
                     a.ledger_snapshot_review_id,
                     r.number AS review_number,
                     r.reviewed_at AS review_reviewed_at
              FROM ledger_snapshot_annotations a
              LEFT JOIN ledger_snapshot_reviews r
                ON a.ledger_snapshot_review_id = r.id
              WHERE a.ledger_snapshot_id = ? AND a.number = ?
            SQL
            ledger_snapshot_id,
            number,
          ) do |rs|
            SnapshotAnnotation.from_row(rs)
          end
        end
      rescue
        nil
      end
    end

    # Update annotation content. Line ranges are immutable.
    # Returns the updated annotation or nil if not found.
    def self.update_snapshot_annotation(
      ledger_snapshot_id : Int64,
      number : Int32,
      content : String,
    ) : SnapshotAnnotation?
      return nil if ledger_snapshot_id <= 0

      begin
        open do |db|
          result = db.exec(
            <<-SQL,
              UPDATE ledger_snapshot_annotations
              SET content = ?, updated_at = datetime('now')
              WHERE ledger_snapshot_id = ? AND number = ?
            SQL
            content,
            ledger_snapshot_id,
            number,
          )
          return nil if result.rows_affected == 0

          # Return the updated annotation
          db.query_one?(
            <<-SQL,
              SELECT a.id, a.created_at, a.updated_at, a.ledger_snapshot_id,
                     a.number, a.start_line, a.end_line, a.content,
                     a.ledger_snapshot_review_id,
                     r.number AS review_number,
                     r.reviewed_at AS review_reviewed_at
              FROM ledger_snapshot_annotations a
              LEFT JOIN ledger_snapshot_reviews r
                ON a.ledger_snapshot_review_id = r.id
              WHERE a.ledger_snapshot_id = ? AND a.number = ?
            SQL
            ledger_snapshot_id,
            number,
          ) do |rs|
            SnapshotAnnotation.from_row(rs)
          end
        end
      rescue
        nil
      end
    end

    # Delete a snapshot annotation by snapshot ID + number. Returns true if deleted.
    def self.delete_snapshot_annotation(ledger_snapshot_id : Int64, number : Int32) : Bool
      return false if ledger_snapshot_id <= 0

      begin
        open do |db|
          result = db.exec(
            "DELETE FROM ledger_snapshot_annotations WHERE ledger_snapshot_id = ? AND number = ?",
            ledger_snapshot_id,
            number,
          )
          result.rows_affected > 0
        end
      rescue
        false
      end
    end

    # ============================================================
    # Snapshot Review Operations
    # ============================================================

    # Create a snapshot review and assign all unreviewed annotations.
    # Returns {review, annotation_count} or nil if no unreviewed
    # annotations exist.
    #
    # Uses an explicit transaction to ensure atomicity: the count
    # check, review INSERT, and annotation UPDATE all see a consistent
    # snapshot. Without this, concurrent calls could both COUNT the
    # same unreviewed annotations and race to assign them.
    def self.save_snapshot_review(
      ledger_snapshot_id : Int64,
    ) : {SnapshotReview, Int32}?
      return nil if ledger_snapshot_id <= 0

      begin
        open do |db|
          db.exec("BEGIN IMMEDIATE")

          count = db.scalar(
            <<-SQL,
              SELECT COUNT(*)
              FROM ledger_snapshot_annotations
              WHERE ledger_snapshot_id = ?
                AND ledger_snapshot_review_id IS NULL
            SQL
            ledger_snapshot_id,
          ).as(Int64).to_i

          if count == 0
            db.exec("ROLLBACK")
            return nil
          end

          # Create the review with auto-assigned number
          db.exec(
            <<-SQL,
              INSERT INTO ledger_snapshot_reviews (
                ledger_snapshot_id, number
              )
              VALUES (
                ?,
                (SELECT COALESCE(MAX(number), 0) + 1
                 FROM ledger_snapshot_reviews
                 WHERE ledger_snapshot_id = ?)
              )
            SQL
            ledger_snapshot_id,
            ledger_snapshot_id,
          )

          review = db.query_one?(
            <<-SQL
              SELECT id, created_at, updated_at, ledger_snapshot_id,
                     number, reviewed_at
              FROM ledger_snapshot_reviews
              WHERE id = last_insert_rowid()
            SQL
          ) do |rs|
            SnapshotReview.from_row(rs)
          end

          unless review
            db.exec("ROLLBACK")
            return nil
          end

          # Assign all unreviewed annotations to this review
          db.exec(
            <<-SQL,
              UPDATE ledger_snapshot_annotations
              SET ledger_snapshot_review_id = ?,
                  updated_at = datetime('now')
              WHERE ledger_snapshot_id = ?
                AND ledger_snapshot_review_id IS NULL
            SQL
            review.id,
            ledger_snapshot_id,
          )

          db.exec("COMMIT")
          {review, count.to_i}
        end
      rescue
        nil
      end
    end

    # List reviews for a snapshot. If pending_only is true, only
    # returns reviews where reviewed_at IS NULL.
    def self.list_snapshot_reviews(
      ledger_snapshot_id : Int64,
      pending_only : Bool = false,
    ) : Array(SnapshotReview)
      reviews = [] of SnapshotReview
      return reviews if ledger_snapshot_id <= 0

      begin
        open do |db|
          where_clause = "WHERE ledger_snapshot_id = ?"
          if pending_only
            where_clause += " AND reviewed_at IS NULL"
          end

          db.query(
            <<-SQL,
              SELECT id, created_at, updated_at, ledger_snapshot_id,
                     number, reviewed_at
              FROM ledger_snapshot_reviews
              #{where_clause}
              ORDER BY number ASC
            SQL
            ledger_snapshot_id,
          ) do |rs|
            rs.each do
              reviews << SnapshotReview.from_row(rs)
            end
          end
        end
      rescue
        # Return empty on error
      end
      reviews
    end

    # Get a snapshot review by snapshot ID + number.
    def self.get_snapshot_review(
      ledger_snapshot_id : Int64,
      number : Int32,
    ) : SnapshotReview?
      return nil if ledger_snapshot_id <= 0

      begin
        open do |db|
          db.query_one?(
            <<-SQL,
              SELECT id, created_at, updated_at, ledger_snapshot_id,
                     number, reviewed_at
              FROM ledger_snapshot_reviews
              WHERE ledger_snapshot_id = ? AND number = ?
            SQL
            ledger_snapshot_id,
            number,
          ) do |rs|
            SnapshotReview.from_row(rs)
          end
        end
      rescue
        nil
      end
    end

    # Mark a review as reviewed. Sets reviewed_at to current time.
    # Idempotent — calling again updates the timestamp.
    # Returns the updated review or nil if not found.
    def self.mark_snapshot_review_reviewed(
      ledger_snapshot_id : Int64,
      number : Int32,
    ) : SnapshotReview?
      return nil if ledger_snapshot_id <= 0

      begin
        open do |db|
          result = db.exec(
            <<-SQL,
              UPDATE ledger_snapshot_reviews
              SET reviewed_at = datetime('now'),
                  updated_at = datetime('now')
              WHERE ledger_snapshot_id = ? AND number = ?
            SQL
            ledger_snapshot_id,
            number,
          )
          return nil if result.rows_affected == 0

          db.query_one?(
            <<-SQL,
              SELECT id, created_at, updated_at, ledger_snapshot_id,
                     number, reviewed_at
              FROM ledger_snapshot_reviews
              WHERE ledger_snapshot_id = ? AND number = ?
            SQL
            ledger_snapshot_id,
            number,
          ) do |rs|
            SnapshotReview.from_row(rs)
          end
        end
      rescue
        nil
      end
    end

    # Get a snapshot by its database primary key.
    def self.get_snapshot_by_id(
      id : Int64,
    ) : Snapshot?
      return nil if id <= 0

      begin
        open do |db|
          db.query_one?(
            <<-SQL,
              SELECT id, ledger_session_id, number, created_at,
                     updated_at, title, content, exchange_count,
                     char_count, metadata
              FROM ledger_snapshots
              WHERE id = ?
            SQL
            id,
          ) do |rs|
            Snapshot.from_row(rs)
          end
        end
      rescue
        nil
      end
    end

    # Count annotations not assigned to any review.
    def self.count_unreviewed_annotations(
      ledger_snapshot_id : Int64,
    ) : Int32
      return 0 if ledger_snapshot_id <= 0

      begin
        open do |db|
          db.scalar(
            <<-SQL,
              SELECT COUNT(*)
              FROM ledger_snapshot_annotations
              WHERE ledger_snapshot_id = ?
                AND ledger_snapshot_review_id IS NULL
            SQL
            ledger_snapshot_id,
          ).as(Int64).to_i
        end
      rescue
        0
      end
    end

    # List annotations assigned to a specific review, ordered by
    # reading position.
    def self.list_annotations_for_review(
      review_id : Int64,
    ) : Array(SnapshotAnnotation)
      annotations = [] of SnapshotAnnotation
      return annotations if review_id <= 0

      begin
        open do |db|
          db.query(
            <<-SQL,
              SELECT a.id, a.created_at, a.updated_at, a.ledger_snapshot_id,
                     a.number, a.start_line, a.end_line, a.content,
                     a.ledger_snapshot_review_id,
                     r.number AS review_number,
                     r.reviewed_at AS review_reviewed_at
              FROM ledger_snapshot_annotations a
              LEFT JOIN ledger_snapshot_reviews r
                ON a.ledger_snapshot_review_id = r.id
              WHERE a.ledger_snapshot_review_id = ?
              ORDER BY a.start_line ASC, a.end_line ASC, a.number ASC
            SQL
            review_id,
          ) do |rs|
            rs.each do
              annotations << SnapshotAnnotation.from_row(rs)
            end
          end
        end
      rescue
        # Return empty on error
      end
      annotations
    end

    # ============================================================
    # Artifact Operations
    # ============================================================

    # Save an artifact record for a session.
    # Number is auto-assigned as session-scoped sequential (1, 2, 3, ...).
    # Returns the artifact number (not the primary key).
    def self.save_artifact(
      ledger_session_id : Int64,
      title : String,
      artifact_type : String,
      mime_type : String,
      original_filename : String,
      stored_path : String,
      source_path : String?,
      file_size : Int64,
      content_hash : String,
      description : String? = nil,
      metadata : String? = nil,
    ) : SaveArtifactResult
      failed = SaveArtifactResult.new(SaveArtifactAction::Failed, 0)
      return failed if ledger_session_id <= 0

      begin
        open do |db|
          # Check for existing artifact with same source_path (dedup).
          # NULL source_paths always insert new (no dedup).
          if source_path
            existing = db.query_one?(
              <<-SQL,
                SELECT number, content_hash
                FROM ledger_artifacts
                WHERE ledger_session_id = ? AND source_path = ?
              SQL
              ledger_session_id,
              source_path,
              as: {Int64, String},
            )

            if existing
              existing_number, existing_hash = existing

              if existing_hash == content_hash
                # Enrichment: same file, same content — update metadata only.
                # Title updates only if the new title is longer (richer).
                db.exec(
                  <<-SQL,
                    UPDATE ledger_artifacts
                    SET title = CASE WHEN length(?) > length(title) THEN ? ELSE title END,
                        description = COALESCE(?, description),
                        metadata = COALESCE(?, metadata),
                        updated_at = datetime('now')
                    WHERE ledger_session_id = ? AND number = ?
                  SQL
                  title,
                  title,
                  description,
                  metadata,
                  ledger_session_id,
                  existing_number,
                )
                return SaveArtifactResult.new(SaveArtifactAction::Enrichment, existing_number.to_i)
              else
                # Version update: same file path, new content — update all fields.
                db.exec(
                  <<-SQL,
                    UPDATE ledger_artifacts
                    SET title = CASE WHEN length(?) > length(title) THEN ? ELSE title END,
                        artifact_type = ?,
                        mime_type = ?,
                        original_filename = ?,
                        file_size = ?,
                        content_hash = ?,
                        description = COALESCE(?, description),
                        metadata = COALESCE(?, metadata),
                        updated_at = datetime('now')
                    WHERE ledger_session_id = ? AND number = ?
                  SQL
                  title,
                  title,
                  artifact_type,
                  mime_type,
                  original_filename,
                  file_size,
                  content_hash,
                  description,
                  metadata,
                  ledger_session_id,
                  existing_number,
                )
                return SaveArtifactResult.new(SaveArtifactAction::VersionUpdate, existing_number.to_i)
              end
            end
          end

          # No existing artifact — insert new.
          db.exec(
            <<-SQL,
              INSERT INTO ledger_artifacts (
                ledger_session_id, number, title, artifact_type,
                mime_type, original_filename, stored_path, source_path,
                file_size, content_hash, description, metadata
              )
              VALUES (
                ?,
                (SELECT COALESCE(MAX(number), 0) + 1
                 FROM ledger_artifacts
                 WHERE ledger_session_id = ?),
                ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
              )
            SQL
            ledger_session_id,
            ledger_session_id,
            title,
            artifact_type,
            mime_type,
            original_filename,
            stored_path,
            source_path,
            file_size,
            content_hash,
            description,
            metadata,
          )
          # Retrieve the number that was just assigned
          number = db.query_one?(
            "SELECT number FROM ledger_artifacts WHERE id = last_insert_rowid()",
            as: Int64,
          ).try(&.to_i) || 0

          if number > 0
            SaveArtifactResult.new(SaveArtifactAction::Insert, number)
          else
            failed
          end
        end
      rescue
        failed
      end
    end

    # List all artifacts for a session, ordered by number.
    def self.list_artifacts(
      ledger_session_id : Int64,
      limit : Int32 = 50,
    ) : Array(Artifact)
      artifacts = [] of Artifact
      return artifacts if ledger_session_id <= 0

      begin
        open do |db|
          db.query(
            <<-SQL,
              SELECT id, ledger_session_id, number, created_at,
                     updated_at, title, artifact_type, mime_type,
                     original_filename, stored_path, source_path,
                     file_size, content_hash, description, metadata
              FROM ledger_artifacts
              WHERE ledger_session_id = ?
              ORDER BY number ASC
              LIMIT ?
            SQL
            ledger_session_id,
            limit,
          ) do |rs|
            rs.each do
              artifacts << Artifact.from_row(rs)
            end
          end
        end
      rescue
        # Return empty on error
      end
      artifacts
    end

    # Get an artifact by session + number.
    def self.get_artifact_by_number(
      ledger_session_id : Int64,
      number : Int32,
    ) : Artifact?
      return nil if ledger_session_id <= 0

      begin
        open do |db|
          db.query_one?(
            <<-SQL,
              SELECT id, ledger_session_id, number, created_at,
                     updated_at, title, artifact_type, mime_type,
                     original_filename, stored_path, source_path,
                     file_size, content_hash, description, metadata
              FROM ledger_artifacts
              WHERE ledger_session_id = ? AND number = ?
            SQL
            ledger_session_id,
            number,
          ) do |rs|
            Artifact.from_row(rs)
          end
        end
      rescue
        nil
      end
    end

    # Delete an artifact by session + number.
    # Also removes the stored file from disk. Returns true if deleted.
    def self.delete_artifact_by_number(
      ledger_session_id : Int64,
      number : Int32,
    ) : Bool
      return false if ledger_session_id <= 0

      # Get stored_path before deleting the record
      artifact = get_artifact_by_number(ledger_session_id, number)
      return false unless artifact

      begin
        open do |db|
          result = db.exec(
            "DELETE FROM ledger_artifacts WHERE ledger_session_id = ? AND number = ?",
            ledger_session_id,
            number,
          )
          if result.rows_affected > 0
            # Clean up the file on disk
            File.delete(artifact.stored_path) if File.exists?(artifact.stored_path)
            # Remove session directory if now empty
            session_dir = Path.new(artifact.stored_path).parent
            if Dir.exists?(session_dir) && Dir.empty?(session_dir)
              Dir.delete(session_dir)
            end
            true
          else
            false
          end
        end
      rescue
        false
      end
    end

    # Get artifact count for a session (for handoff display).
    def self.session_artifact_count(
      ledger_session_id : Int64,
    ) : Int32
      return 0 if ledger_session_id <= 0

      begin
        open do |db|
          db.query_one?(
            "SELECT COUNT(*) FROM ledger_artifacts WHERE ledger_session_id = ?",
            ledger_session_id,
            as: Int64,
          ).try(&.to_i) || 0
        end
      rescue
        0
      end
    end

    # Update the stored_path for an artifact after file storage.
    def self.update_artifact_stored_path(
      ledger_session_id : Int64,
      number : Int32,
      stored_path : String,
    )
      open do |db|
        db.exec(
          "UPDATE ledger_artifacts SET stored_path = ? WHERE ledger_session_id = ? AND number = ?",
          stored_path,
          ledger_session_id,
          number,
        )
      end
    rescue
      # Best-effort
    end

    # ============================================================
    # Prune Operations
    # ============================================================

    # Standard prune duration periods and their day counts
    PRUNE_PERIODS = {
      "1w" => 7,
      "2w" => 14,
      "1m" => 30,
      "2m" => 60,
      "3m" => 90,
      "6m" => 180,
      "1y" => 365,
      "2y" => 730,
      "5y" => 1825,
    }

    # Counts for a single prune period
    struct PruneCounts
      getter sessions : Int32
      getter entries : Int32
      getter files : Int32
      getter daily_usages : Int32
      getter snapshots : Int32
      getter artifacts : Int32

      def initialize(
        @sessions, @entries, @files,
        @daily_usages, @snapshots, @artifacts,
      )
      end
    end

    # Count prunable data for all standard periods at once.
    # Returns a hash of period label => PruneCounts.
    def self.count_prunable_summary : Hash(String, PruneCounts)
      result = {} of String => PruneCounts

      begin
        open do |db|
          PRUNE_PERIODS.each do |label, days|
            cutoff = (Time.utc - days.days).to_s("%Y-%m-%d %H:%M:%S")
            result[label] = count_prunable_for_cutoff(db, cutoff)
          end
        end
      rescue
        # Return whatever we have on error
      end

      result
    end

    # Count prunable data for a specific cutoff date string.
    def self.count_prunable_data(cutoff_date : String) : PruneCounts
      begin
        open do |db|
          count_prunable_for_cutoff(db, cutoff_date)
        end
      rescue
        PruneCounts.new(0, 0, 0, 0, 0, 0)
      end
    end

    # Internal: count prunable + preserved data for a cutoff, using an existing db connection.
    private def self.count_prunable_for_cutoff(db : DB::Database, cutoff : String) : PruneCounts
      sessions = db.scalar(
        "SELECT COUNT(*) FROM ledger_sessions WHERE updated_at < ?", cutoff
      ).as(Int64).to_i

      entries = db.scalar(
        "SELECT COUNT(*) FROM ledger_entries WHERE ledger_session_id IN (SELECT id FROM ledger_sessions WHERE updated_at < ?)", cutoff
      ).as(Int64).to_i

      files = db.scalar(
        "SELECT COUNT(*) FROM ledger_session_files WHERE ledger_session_id IN (SELECT id FROM ledger_sessions WHERE updated_at < ?)", cutoff
      ).as(Int64).to_i

      daily_usages = db.scalar(
        "SELECT COUNT(*) FROM ledger_session_daily_usages WHERE ledger_session_id IN (SELECT id FROM ledger_sessions WHERE updated_at < ?)", cutoff
      ).as(Int64).to_i

      snapshots = db.scalar(
        "SELECT COUNT(*) FROM ledger_snapshots WHERE ledger_session_id IN (SELECT id FROM ledger_sessions WHERE updated_at < ?)", cutoff
      ).as(Int64).to_i

      artifacts = db.scalar(
        "SELECT COUNT(*) FROM ledger_artifacts WHERE ledger_session_id IN (SELECT id FROM ledger_sessions WHERE updated_at < ?)", cutoff
      ).as(Int64).to_i

      PruneCounts.new(sessions, entries, files, daily_usages, snapshots, artifacts)
    end

    # Prune entries and files for sessions older than cutoff.
    # Returns {entries_deleted, files_deleted}.
    def self.prune_session_data(cutoff_date : String) : NamedTuple(entries: Int32, files: Int32)
      begin
        open do |db|
          db.exec(
            "DELETE FROM ledger_entries WHERE ledger_session_id IN (SELECT id FROM ledger_sessions WHERE updated_at < ?)",
            cutoff_date,
          )
          entries_deleted = db.scalar("SELECT changes()").as(Int64).to_i

          db.exec(
            "DELETE FROM ledger_session_files WHERE ledger_session_id IN (SELECT id FROM ledger_sessions WHERE updated_at < ?)",
            cutoff_date,
          )
          files_deleted = db.scalar("SELECT changes()").as(Int64).to_i

          # Compact FTS tombstones from bulk entry deletes
          db.exec("INSERT INTO ledger_fts(ledger_fts) VALUES('optimize')")
          db.exec("PRAGMA optimize")

          {entries: entries_deleted, files: files_deleted}
        end
      rescue
        {entries: 0, files: 0}
      end
    end

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

    # Get the database file size in bytes.
    def self.database_file_size : Int64
      File.size(database_path).to_i64
    rescue
      0_i64
    end

    # Count sessions likely still active (updated within last 5 minutes).
    def self.active_session_count : Int32
      begin
        open do |db|
          db.scalar(
            "SELECT COUNT(*) FROM ledger_sessions WHERE updated_at > datetime('now', '-5 minutes')"
          ).as(Int64).to_i
        end
      rescue
        0
      end
    end

    # ============================================================
    # Backup Operations
    # ============================================================

    # Create a point-in-time backup of the database using VACUUM INTO.
    # Returns the backup file path on success, nil on failure.
    #
    # Layout: backup_dir/YYYY-MM-DD/ledger_SESSION_ID.db
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

      backup_file = date_dir / "ledger_#{session_id}.db"

      # Skip if backup already exists (idempotent — same session starting twice)
      return backup_file if File.exists?(backup_file)

      open do |db|
        db.exec("VACUUM INTO '#{backup_file}'")
      end

      backup_file
    rescue ex
      STDERR.puts "[galaxy-ledger] Backup failed: #{ex.message}"
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
      STDERR.puts "[galaxy-ledger] Prune failed: #{ex.message}"
      0
    end

    # ============================================================
    # Data Structs
    # ============================================================

    # A session record from the database
    struct SessionRecord
      getter id : Int64
      getter suggested_name : String?
      getter suggested_name_data : String
      getter current_session_identifier : String?
      getter current_claude_pid : Int64?
      getter started_at : String?
      getter updated_at : String?
      getter cwd : String?
      getter project_dir : String?
      getter git_branch : String?
      getter model_id : String?
      getter model_display_name : String?
      getter claude_version : String?
      getter context_percentage : Float64
      getter tokens_used : Int64
      getter tokens_max : Int64
      getter cost_usd : Float64
      getter lines_added : Int64
      getter lines_removed : Int64
      getter context : String
      getter last_interaction : String?

      def initialize(
        @id, @suggested_name, @suggested_name_data, @current_session_identifier, @current_claude_pid, @started_at, @updated_at,
        @cwd, @project_dir, @git_branch,
        @model_id, @model_display_name, @claude_version,
        @context_percentage, @tokens_used, @tokens_max, @cost_usd,
        @lines_added, @lines_removed, @context, @last_interaction,
      )
      end

      def self.from_row(rs) : SessionRecord
        SessionRecord.new(
          id: rs.read(Int64),
          suggested_name: rs.read(String?),
          suggested_name_data: rs.read(String),
          current_session_identifier: rs.read(String?),
          current_claude_pid: rs.read(Int64?),
          started_at: rs.read(String?),
          updated_at: rs.read(String?),
          cwd: rs.read(String?),
          project_dir: rs.read(String?),
          git_branch: rs.read(String?),
          model_id: rs.read(String?),
          model_display_name: rs.read(String?),
          claude_version: rs.read(String?),
          context_percentage: rs.read(Float64),
          tokens_used: rs.read(Int64),
          tokens_max: rs.read(Int64),
          cost_usd: rs.read(Float64),
          lines_added: rs.read(Int64),
          lines_removed: rs.read(Int64),
          context: rs.read(String),
          last_interaction: rs.read(String?),
        )
      end
    end

    # A file access record from the database
    struct SessionFile
      getter id : Int64
      getter ledger_session_id : Int64
      getter file_path : String
      getter search_pattern : String
      getter is_read : Bool
      getter is_edited : Bool
      getter is_written : Bool
      getter is_searched : Bool
      getter first_seen_at : String?
      getter last_seen_at : String?
      getter access_count : Int64
      getter metadata : String?
      getter file_type : String

      def initialize(
        @id, @ledger_session_id, @file_path, @search_pattern,
        @is_read, @is_edited, @is_written, @is_searched,
        @first_seen_at, @last_seen_at, @access_count, @metadata,
        @file_type = "other",
      )
      end

      def self.from_row(rs) : SessionFile
        SessionFile.new(
          id: rs.read(Int64),
          ledger_session_id: rs.read(Int64),
          file_path: rs.read(String),
          search_pattern: rs.read(String),
          is_read: rs.read(Int64) == 1,
          is_edited: rs.read(Int64) == 1,
          is_written: rs.read(Int64) == 1,
          is_searched: rs.read(Int64) == 1,
          first_seen_at: rs.read(String?),
          last_seen_at: rs.read(String?),
          access_count: rs.read(Int64),
          metadata: rs.read(String?),
          file_type: rs.read(String),
        )
      end
    end

    # A ledger entry from the database
    struct StoredEntry
      getter id : Int64
      getter created_at : String
      getter ledger_session_id : Int64
      getter entry_type : String
      getter source : String?
      getter content : String
      getter content_hash : String
      getter metadata : String?
      getter importance : String
      getter category : String?
      getter keywords : String?
      getter applies_when : String?
      getter source_file : String?

      def initialize(
        @id,
        @created_at,
        @ledger_session_id,
        @entry_type,
        @source,
        @content,
        @content_hash,
        @metadata,
        @importance,
        @category = nil,
        @keywords = nil,
        @applies_when = nil,
        @source_file = nil,
      )
      end

      def self.from_row(rs) : StoredEntry
        StoredEntry.new(
          id: rs.read(Int64),
          created_at: rs.read(String),
          ledger_session_id: rs.read(Int64),
          entry_type: rs.read(String),
          source: rs.read(String?),
          content: rs.read(String),
          content_hash: rs.read(String),
          metadata: rs.read(String?),
          importance: rs.read(String),
          category: rs.read(String?),
          keywords: rs.read(String?),
          applies_when: rs.read(String?),
          source_file: rs.read(String?)
        )
      end

      # Parse keywords from JSON string to array
      def keywords_array : Array(String)
        if kw = keywords
          begin
            JSON.parse(kw).as_a.map(&.as_s)
          rescue
            [] of String
          end
        else
          [] of String
        end
      end

      # Convert to Entry for compatibility
      def to_entry : Entry
        metadata_any = if m = metadata
                         JSON.parse(m)
                       else
                         nil
                       end

        Entry.new(
          entry_type: entry_type,
          content: content,
          importance: importance,
          source: source,
          metadata: metadata_any,
          created_at: created_at,
          category: category,
          keywords: keywords_array,
          applies_when: applies_when,
          source_file: source_file
        )
      end
    end

    # A snapshot record from the database
    struct Snapshot
      getter id : Int64
      getter ledger_session_id : Int64
      getter number : Int32
      getter created_at : String
      getter updated_at : String
      getter title : String
      getter content : String
      getter exchange_count : Int32
      getter char_count : Int32
      getter metadata : String?

      def initialize(
        @id, @ledger_session_id, @number, @created_at, @updated_at,
        @title, @content, @exchange_count, @char_count, @metadata,
      )
      end

      def self.from_row(rs) : Snapshot
        Snapshot.new(
          id: rs.read(Int64),
          ledger_session_id: rs.read(Int64),
          number: rs.read(Int64).to_i,
          created_at: rs.read(String),
          updated_at: rs.read(String),
          title: rs.read(String),
          content: rs.read(String),
          exchange_count: rs.read(Int64).to_i,
          char_count: rs.read(Int64).to_i,
          metadata: rs.read(String?),
        )
      end
    end

    # A snapshot list item with aggregated review count.
    # Separate from Snapshot because the review count comes from a
    # LEFT JOIN that only applies to list queries. Intentionally omits
    # content, metadata, and updated_at — none are used by the list
    # output (JSON or human-readable).
    struct SnapshotListItem
      getter id : Int64
      getter ledger_session_id : Int64
      getter number : Int32
      getter created_at : String
      getter title : String
      getter exchange_count : Int32
      getter char_count : Int32
      getter review_count : Int32

      def initialize(
        @id, @ledger_session_id, @number, @created_at,
        @title, @exchange_count, @char_count, @review_count,
      )
      end

      def self.from_row(rs) : SnapshotListItem
        SnapshotListItem.new(
          id: rs.read(Int64),
          ledger_session_id: rs.read(Int64),
          number: rs.read(Int64).to_i,
          created_at: rs.read(String),
          title: rs.read(String),
          exchange_count: rs.read(Int64).to_i,
          char_count: rs.read(Int64).to_i,
          review_count: rs.read(Int64).to_i,
        )
      end
    end

    # A snapshot annotation record from the database
    struct SnapshotAnnotation
      getter id : Int64
      getter created_at : String
      getter updated_at : String
      getter ledger_snapshot_id : Int64
      getter number : Int32
      getter start_line : Int32
      getter end_line : Int32
      getter content : String
      getter ledger_snapshot_review_id : Int64?
      getter review_number : Int32?
      getter review_reviewed_at : String?

      def initialize(
        @id, @created_at, @updated_at, @ledger_snapshot_id,
        @number, @start_line, @end_line, @content,
        @ledger_snapshot_review_id, @review_number, @review_reviewed_at,
      )
      end

      def self.from_row(rs) : SnapshotAnnotation
        SnapshotAnnotation.new(
          id: rs.read(Int64),
          created_at: rs.read(String),
          updated_at: rs.read(String),
          ledger_snapshot_id: rs.read(Int64),
          number: rs.read(Int64).to_i,
          start_line: rs.read(Int64).to_i,
          end_line: rs.read(Int64).to_i,
          content: rs.read(String),
          ledger_snapshot_review_id: rs.read(Int64?),
          review_number: rs.read(Int64?).try(&.to_i),
          review_reviewed_at: rs.read(String?),
        )
      end
    end

    # A snapshot review record from the database
    struct SnapshotReview
      getter id : Int64
      getter created_at : String
      getter updated_at : String
      getter ledger_snapshot_id : Int64
      getter number : Int32
      getter reviewed_at : String?

      def initialize(
        @id, @created_at, @updated_at, @ledger_snapshot_id,
        @number, @reviewed_at,
      )
      end

      def self.from_row(rs) : SnapshotReview
        SnapshotReview.new(
          id: rs.read(Int64),
          created_at: rs.read(String),
          updated_at: rs.read(String),
          ledger_snapshot_id: rs.read(Int64),
          number: rs.read(Int64).to_i,
          reviewed_at: rs.read(String?),
        )
      end
    end

    # An artifact record from the database
    struct Artifact
      getter id : Int64
      getter ledger_session_id : Int64
      getter number : Int32
      getter created_at : String
      getter updated_at : String
      getter title : String
      getter artifact_type : String
      getter mime_type : String
      getter original_filename : String
      getter stored_path : String
      getter source_path : String?
      getter file_size : Int64
      getter content_hash : String
      getter description : String?
      getter metadata : String?

      def initialize(
        @id, @ledger_session_id, @number, @created_at, @updated_at,
        @title, @artifact_type, @mime_type, @original_filename,
        @stored_path, @source_path, @file_size, @content_hash,
        @description, @metadata,
      )
      end

      def self.from_row(rs) : Artifact
        Artifact.new(
          id: rs.read(Int64),
          ledger_session_id: rs.read(Int64),
          number: rs.read(Int64).to_i,
          created_at: rs.read(String),
          updated_at: rs.read(String),
          title: rs.read(String),
          artifact_type: rs.read(String),
          mime_type: rs.read(String),
          original_filename: rs.read(String),
          stored_path: rs.read(String),
          source_path: rs.read(String?),
          file_size: rs.read(Int64),
          content_hash: rs.read(String),
          description: rs.read(String?),
          metadata: rs.read(String?),
        )
      end
    end

    # Result type for save_artifact upsert operations.
    # Communicates what happened so callers know whether to copy/overwrite files.
    enum SaveArtifactAction
      Insert        # New artifact created, caller should store file
      Enrichment    # Same file, same content — metadata updated, skip file copy
      VersionUpdate # Same file, new content — metadata updated, caller should re-copy
      Failed        # Operation failed
    end

    struct SaveArtifactResult
      getter action : SaveArtifactAction
      getter number : Int32

      def initialize(@action, @number)
      end
    end

    # Session statistics
    struct SessionStat
      getter ledger_session_id : Int64
      getter entry_count : Int32
      getter last_entry : String

      def initialize(@ledger_session_id, @entry_count, @last_entry)
      end
    end
  end
end
