require "db"
require "sqlite3"
require "digest/sha256"
require "json"

module GalaxyLedger
  # SQLite database for persistent ledger storage
  # Location: ~/.claude/galaxy/data/ledger.db
  #
  # Provides:
  # - Schema creation with FTS5 full-text search
  # - Session records (ledger_sessions) with metrics and context
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
        # Enable WAL mode for better concurrency
        db.exec("PRAGMA journal_mode=WAL")
        db.exec("PRAGMA foreign_keys=ON")
        # Set busy timeout for concurrent write safety (5 seconds)
        db.exec("PRAGMA busy_timeout=5000")
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
            session_identifier TEXT NOT NULL UNIQUE,
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
            cumulative_tokens_used INTEGER DEFAULT 0,
            cumulative_cost_usd INTEGER DEFAULT 0,
            lines_added INTEGER DEFAULT 0,
            lines_removed INTEGER DEFAULT 0,
            context TEXT NOT NULL DEFAULT '{}',
            last_interaction TEXT
          )
        SQL

        # Main ledger entries table
        db.exec(<<-SQL)
          CREATE TABLE IF NOT EXISTS ledger_entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT DEFAULT (datetime('now')),
            ledger_session_id INTEGER NOT NULL,
            session_identifier TEXT NOT NULL,
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
            session_identifier TEXT NOT NULL,
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
            UNIQUE(session_identifier, file_path, search_pattern),
            FOREIGN KEY (ledger_session_id) REFERENCES ledger_sessions(id) ON DELETE CASCADE
          )
        SQL

        # Indexes for ledger_sessions
        db.exec("CREATE INDEX IF NOT EXISTS idx_sessions_identifier ON ledger_sessions(session_identifier)")

        # Indexes for ledger_entries
        db.exec("CREATE INDEX IF NOT EXISTS idx_entries_session ON ledger_entries(session_identifier)")
        db.exec("CREATE INDEX IF NOT EXISTS idx_entries_session_type ON ledger_entries(session_identifier, entry_type)")
        db.exec("CREATE INDEX IF NOT EXISTS idx_entries_source ON ledger_entries(source)")
        db.exec("CREATE INDEX IF NOT EXISTS idx_entries_created ON ledger_entries(created_at)")
        db.exec("CREATE INDEX IF NOT EXISTS idx_entries_importance ON ledger_entries(importance)")
        db.exec("CREATE INDEX IF NOT EXISTS idx_entries_category ON ledger_entries(category)")
        db.exec("CREATE INDEX IF NOT EXISTS idx_entries_ledger_session ON ledger_entries(ledger_session_id)")

        # Unique constraint for deduplication
        db.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_content_dedup ON ledger_entries(session_identifier, entry_type, content_hash)")

        # Indexes for ledger_session_files
        db.exec("CREATE INDEX IF NOT EXISTS idx_files_session ON ledger_session_files(session_identifier)")
        db.exec("CREATE INDEX IF NOT EXISTS idx_files_ledger_session ON ledger_session_files(ledger_session_id)")

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
    # Session Record Operations
    # ============================================================

    # Upsert a session record. Creates if new, updates updated_at if existing.
    # Returns the integer PK (ledger_sessions.id).
    def self.upsert_session(
      session_identifier : String,
      cwd : String? = nil,
      project_dir : String? = nil,
      git_branch : String? = nil,
    ) : Int64
      return 0_i64 if session_identifier.empty?

      begin
        open do |db|
          db.exec(
            <<-SQL,
              INSERT INTO ledger_sessions (session_identifier, cwd, project_dir, git_branch)
              VALUES (?, ?, ?, ?)
              ON CONFLICT (session_identifier) DO UPDATE SET
                updated_at = datetime('now'),
                cwd = COALESCE(excluded.cwd, ledger_sessions.cwd),
                project_dir = COALESCE(excluded.project_dir, ledger_sessions.project_dir),
                git_branch = COALESCE(excluded.git_branch, ledger_sessions.git_branch)
            SQL
            session_identifier,
            cwd,
            project_dir,
            git_branch,
          )
          db.scalar(
            "SELECT id FROM ledger_sessions WHERE session_identifier = ?",
            session_identifier
          ).as(Int64)
        end
      rescue
        0_i64
      end
    end

    # Update session metrics from a ContextStatus payload (received via stdin from statusline)
    def self.update_session_metrics(session_identifier : String, status : ContextStatus) : Bool
      return false if session_identifier.empty?

      begin
        open do |db|
          db.exec(
            <<-SQL,
              UPDATE ledger_sessions SET
                updated_at = datetime('now'),
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
              WHERE session_identifier = ?
            SQL
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
            session_identifier,
          )
          true
        end
      rescue
        false
      end
    end

    # Update the last_interaction JSON for a session
    def self.update_session_last_interaction(session_identifier : String, json : String) : Bool
      return false if session_identifier.empty?

      begin
        open do |db|
          db.exec(
            "UPDATE ledger_sessions SET last_interaction = ?, updated_at = datetime('now') WHERE session_identifier = ?",
            json,
            session_identifier,
          )
          true
        end
      rescue
        false
      end
    end

    # Merge a key/value into the session's context JSON column.
    # Reads existing JSON, adds key, writes back.
    # If write_once is true, skips if key already exists.
    def self.merge_session_context(
      session_identifier : String,
      key : String,
      value : String,
      write_once : Bool = false,
    ) : Bool
      return false if session_identifier.empty?

      begin
        open do |db|
          # Read current context
          current = db.query_one?(
            "SELECT context FROM ledger_sessions WHERE session_identifier = ?",
            session_identifier,
            as: String
          ) || "{}"

          ctx = begin
            JSON.parse(current).as_h
          rescue
            {} of String => JSON::Any
          end

          # Write-once: skip if key exists
          if write_once && ctx.has_key?(key)
            return true
          end

          ctx[key] = JSON::Any.new(value)
          new_json = JSON::Any.new(ctx).to_json

          db.exec(
            "UPDATE ledger_sessions SET context = ?, updated_at = datetime('now') WHERE session_identifier = ?",
            new_json,
            session_identifier,
          )
          true
        end
      rescue
        false
      end
    end

    # Get a session record by identifier
    def self.get_session(session_identifier : String) : SessionRecord?
      return nil if session_identifier.empty?

      begin
        open do |db|
          db.query_one?(
            <<-SQL,
              SELECT id, session_identifier, started_at, updated_at, cwd, project_dir,
                     git_branch, model_id, model_display_name, claude_version,
                     context_percentage, tokens_used, tokens_max, cost_usd,
                     cumulative_tokens_used, cumulative_cost_usd,
                     lines_added, lines_removed, context, last_interaction
              FROM ledger_sessions
              WHERE session_identifier = ?
            SQL
            session_identifier,
          ) do |rs|
            SessionRecord.from_row(rs)
          end
        end
      rescue
        nil
      end
    end

    # List session records, most recent first
    def self.list_sessions(limit : Int32 = 50) : Array(SessionRecord)
      sessions = [] of SessionRecord
      begin
        open do |db|
          db.query(
            <<-SQL,
              SELECT id, session_identifier, started_at, updated_at, cwd, project_dir,
                     git_branch, model_id, model_display_name, claude_version,
                     context_percentage, tokens_used, tokens_max, cost_usd,
                     cumulative_tokens_used, cumulative_cost_usd,
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
    # File ops dedup on (session_identifier, file_path, '').
    # Search ops dedup on (session_identifier, directory_path, pattern).
    def self.upsert_session_file(
      session_identifier : String,
      file_path : String,
      operation : Symbol,
      search_pattern : String = "",
      metadata : String? = nil,
    ) : Bool
      return false if session_identifier.empty? || file_path.empty?

      is_read = operation == :read ? 1 : 0
      is_edited = operation == :edit ? 1 : 0
      is_written = operation == :write ? 1 : 0
      is_searched = operation == :search ? 1 : 0

      begin
        open do |db|
          db.exec(
            <<-SQL,
              INSERT INTO ledger_session_files (
                ledger_session_id, session_identifier, file_path, search_pattern,
                is_read, is_edited, is_written, is_searched, metadata
              )
              VALUES (
                (SELECT id FROM ledger_sessions WHERE session_identifier = ?),
                ?, ?, ?,
                ?, ?, ?, ?, ?
              )
              ON CONFLICT (session_identifier, file_path, search_pattern) DO UPDATE SET
                is_read = MAX(ledger_session_files.is_read, excluded.is_read),
                is_edited = MAX(ledger_session_files.is_edited, excluded.is_edited),
                is_written = MAX(ledger_session_files.is_written, excluded.is_written),
                is_searched = MAX(ledger_session_files.is_searched, excluded.is_searched),
                last_seen_at = datetime('now'),
                access_count = ledger_session_files.access_count + 1,
                metadata = COALESCE(excluded.metadata, ledger_session_files.metadata)
            SQL
            session_identifier,
            session_identifier,
            file_path,
            search_pattern,
            is_read,
            is_edited,
            is_written,
            is_searched,
            metadata,
          )
          true
        end
      rescue
        false
      end
    end

    # Get all file access records for a session
    def self.session_files(session_identifier : String) : Array(SessionFile)
      files = [] of SessionFile
      return files if session_identifier.empty?

      begin
        open do |db|
          db.query(
            <<-SQL,
              SELECT id, ledger_session_id, session_identifier, file_path, search_pattern,
                     is_read, is_edited, is_written, is_searched,
                     first_seen_at, last_seen_at, access_count, metadata
              FROM ledger_session_files
              WHERE session_identifier = ?
              ORDER BY last_seen_at DESC
            SQL
            session_identifier,
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
    def self.insert(session_identifier : String, entry : Entry) : Bool
      return false if session_identifier.empty?
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
                ledger_session_id, session_identifier, entry_type, source, content,
                content_hash, metadata, importance, created_at, category, keywords,
                applies_when, source_file
              )
              VALUES (
                (SELECT id FROM ledger_sessions WHERE session_identifier = ?),
                ?, ?, ?, ?,
                ?, ?, ?, ?, ?, ?,
                ?, ?
              )
              ON CONFLICT (session_identifier, entry_type, content_hash) DO NOTHING
            SQL
            session_identifier,
            session_identifier,
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
    def self.insert_many(session_identifier : String, entries : Array(Entry)) : Int32
      return 0 if session_identifier.empty?
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
                  ledger_session_id, session_identifier, entry_type, source, content,
                  content_hash, metadata, importance, created_at, category, keywords,
                  applies_when, source_file
                )
                VALUES (
                  (SELECT id FROM ledger_sessions WHERE session_identifier = ?),
                  ?, ?, ?, ?,
                  ?, ?, ?, ?, ?, ?,
                  ?, ?
                )
                ON CONFLICT (session_identifier, entry_type, content_hash) DO NOTHING
              SQL
              session_identifier,
              session_identifier,
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

    # Delete a session and all associated data (entries + files cascade via FK)
    # Returns count of entries deleted
    def self.delete_session(session_identifier : String) : Int32
      return 0 if session_identifier.empty?

      begin
        open do |db|
          # Count entries before delete for return value
          count = db.scalar(
            "SELECT COUNT(*) FROM ledger_entries WHERE session_identifier = ?",
            session_identifier
          ).as(Int64).to_i

          # Delete from ledger_sessions — FK cascade handles entries + files
          db.exec("DELETE FROM ledger_sessions WHERE session_identifier = ?", session_identifier)

          count
        end
      rescue
        0
      end
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
    def self.count_by_session(session_identifier : String) : Int32
      return 0 if session_identifier.empty?

      begin
        open do |db|
          db.scalar("SELECT COUNT(*) FROM ledger_entries WHERE session_identifier = ? #{INTERNAL_TYPE_EXCLUSION_SQL}", session_identifier).as(Int64).to_i
        end
      rescue
        0
      end
    end

    # Check if an extraction marker already exists for a source file in a session.
    def self.has_extracted_source_file?(session_identifier : String, source_file : String) : Bool
      return false if session_identifier.empty? || source_file.empty?

      begin
        open do |db|
          db.scalar(
            <<-SQL,
              SELECT COUNT(*) FROM ledger_entries
              WHERE session_identifier = ? AND source_file = ?
              AND entry_type = 'extraction_marker'
              LIMIT 1
            SQL
            session_identifier,
            source_file,
          ).as(Int64) > 0
        end
      rescue
        false
      end
    end

    # Mark all entries for a source file as stale within a session.
    def self.mark_entries_stale(session_identifier : String, source_file : String) : Int32
      return 0 if session_identifier.empty? || source_file.empty?

      begin
        open do |db|
          db.exec(
            <<-SQL,
              UPDATE ledger_entries SET stale = 1
              WHERE session_identifier = ? AND source_file = ?
            SQL
            session_identifier,
            source_file,
          )
          db.scalar("SELECT changes()").as(Int64).to_i
        end
      rescue
        0
      end
    end

    # Find source files with stale extraction markers in a session.
    # Returns the full path (from source_file) and the original extraction type
    # (from metadata) for each stale marker.
    def self.stale_entries(session_identifier : String) : Array(NamedTuple(source_file: String, full_path: String, entry_type: String))
      results = [] of NamedTuple(source_file: String, full_path: String, entry_type: String)
      return results if session_identifier.empty?

      begin
        open do |db|
          db.query(
            <<-SQL,
              SELECT DISTINCT source_file, content, metadata
              FROM ledger_entries
              WHERE session_identifier = ? AND stale = 1
                AND source_file IS NOT NULL
                AND entry_type = 'extraction_marker'
            SQL
            session_identifier,
          ) do |rs|
            rs.each do
              source_file = rs.read(String)
              full_path = rs.read(String)
              metadata_str = rs.read(String | Nil)

              # Recover the original extraction type from metadata
              extraction_type = "guideline" # default fallback
              if metadata_str
                begin
                  meta = JSON.parse(metadata_str)
                  if et = meta["extraction_type"]?.try(&.as_s?)
                    extraction_type = et
                  end
                rescue
                  # Use default
                end
              end

              results << {
                source_file: source_file,
                full_path:   full_path,
                entry_type:  extraction_type,
              }
            end
          end
        end
      rescue
        # Return empty on error
      end

      results
    end

    # Delete all guideline/implementation_plan/extraction_marker entries for a source file in a session.
    def self.delete_entries_by_source_file(session_identifier : String, source_file : String) : Int32
      return 0 if session_identifier.empty? || source_file.empty?

      begin
        open do |db|
          db.exec(
            <<-SQL,
              DELETE FROM ledger_entries
              WHERE session_identifier = ? AND source_file = ?
                AND entry_type IN ('guideline', 'implementation_plan', 'extraction_marker')
            SQL
            session_identifier,
            source_file,
          )
          db.scalar("SELECT changes()").as(Int64).to_i
        end
      rescue
        0
      end
    end

    # ============================================================
    # Query Operations
    # ============================================================

    # Query entries by session (most recent first, excludes internal entry types)
    def self.query_by_session(session_identifier : String, limit : Int32 = 100) : Array(StoredEntry)
      return [] of StoredEntry if session_identifier.empty?

      entries = [] of StoredEntry
      begin
        open do |db|
          db.query(
            <<-SQL,
              SELECT id, created_at, session_identifier, entry_type, source, content, content_hash, metadata, importance, category, keywords, applies_when, source_file
              FROM ledger_entries
              WHERE session_identifier = ? #{INTERNAL_TYPE_EXCLUSION_SQL}
              ORDER BY created_at DESC
              LIMIT ?
            SQL
            session_identifier,
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
    def self.query_by_type(session_identifier : String, entry_type : String, limit : Int32 = 100) : Array(StoredEntry)
      return [] of StoredEntry if session_identifier.empty?

      entries = [] of StoredEntry
      begin
        open do |db|
          db.query(
            <<-SQL,
              SELECT id, created_at, session_identifier, entry_type, source, content, content_hash, metadata, importance, category, keywords, applies_when, source_file
              FROM ledger_entries
              WHERE session_identifier = ? AND entry_type = ?
              ORDER BY created_at DESC
              LIMIT ?
            SQL
            session_identifier,
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
    def self.query_by_importance(session_identifier : String, importance : String, limit : Int32 = 100) : Array(StoredEntry)
      return [] of StoredEntry if session_identifier.empty?

      entries = [] of StoredEntry
      begin
        open do |db|
          db.query(
            <<-SQL,
              SELECT id, created_at, session_identifier, entry_type, source, content, content_hash, metadata, importance, category, keywords, applies_when, source_file
              FROM ledger_entries
              WHERE session_identifier = ? AND importance = ? #{INTERNAL_TYPE_EXCLUSION_SQL}
              ORDER BY created_at DESC
              LIMIT ?
            SQL
            session_identifier,
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
              SELECT e.id, e.created_at, e.session_identifier, e.entry_type, e.source, e.content, e.content_hash, e.metadata, e.importance, e.category, e.keywords, e.applies_when, e.source_file
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
      session_identifier : String,
      query : String,
      limit : Int32 = 50,
      entry_type : String? = nil,
      importance : String? = nil,
      category : String? = nil,
      prefix_match : Bool = true,
    ) : Array(StoredEntry)
      return [] of StoredEntry if session_identifier.empty?
      return [] of StoredEntry if query.strip.empty?

      fts_query = prepare_fts_query(query, prefix_match)
      entries = [] of StoredEntry

      begin
        open do |db|
          sql = String.build do |s|
            s << <<-SQL
              SELECT e.id, e.created_at, e.session_identifier, e.entry_type, e.source, e.content, e.content_hash, e.metadata, e.importance, e.category, e.keywords, e.applies_when, e.source_file
              FROM ledger_entries e
              JOIN ledger_fts f ON e.id = f.rowid
              WHERE e.session_identifier = ? AND ledger_fts MATCH ?
            SQL
            s << (entry_type ? " AND e.entry_type = ?" : " #{INTERNAL_TYPE_EXCLUSION_ALIAS_SQL}")

            s << " AND e.importance = ?" if importance
            s << " AND e.category = ?" if category
            s << " ORDER BY rank LIMIT ?"
          end

          args = [session_identifier, fts_query] of DB::Any
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
              SELECT session_identifier, COUNT(*) as entry_count, MAX(created_at) as last_entry
              FROM ledger_entries
              WHERE 1=1 #{INTERNAL_TYPE_EXCLUSION_SQL}
              GROUP BY session_identifier
              ORDER BY last_entry DESC
            SQL
          ) do |rs|
            rs.each do
              stats << SessionStat.new(
                session_identifier: rs.read(String),
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
      session_identifier : String? = nil,
    ) : Array(StoredEntry)
      entries = [] of StoredEntry
      begin
        open do |db|
          sql = String.build do |s|
            s << <<-SQL
              SELECT id, created_at, session_identifier, entry_type, source, content, content_hash, metadata, importance, category, keywords, applies_when, source_file
              FROM ledger_entries
              WHERE 1=1
            SQL
            s << " AND session_identifier = ?" if session_identifier
            s << (entry_type ? " AND entry_type = ?" : " #{INTERNAL_TYPE_EXCLUSION_SQL}")
            s << " AND importance = ?" if importance
            s << " AND category = ?" if category
            s << " ORDER BY created_at DESC LIMIT ?"
          end

          args = [] of DB::Any
          args << session_identifier if session_identifier
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
      getter guidelines : Array(StoredEntry)
      getter implementation_plans : Array(StoredEntry)
      getter high_importance_decisions : Array(StoredEntry)

      def initialize(@guidelines, @implementation_plans, @high_importance_decisions)
      end

      def total_count : Int32
        guidelines.size + implementation_plans.size + high_importance_decisions.size
      end
    end

    # Query Tier 1 essentials for a session
    def self.query_tier1(session_identifier : String, decision_limit : Int32 = 10) : Tier1Result
      guidelines = [] of StoredEntry
      impl_plans = [] of StoredEntry
      decisions = [] of StoredEntry

      return Tier1Result.new(guidelines, impl_plans, decisions) if session_identifier.empty?

      begin
        open do |db|
          db.query(
            <<-SQL,
              SELECT id, created_at, session_identifier, entry_type, source, content, content_hash, metadata, importance, category, keywords, applies_when, source_file
              FROM ledger_entries
              WHERE session_identifier = ? AND entry_type = 'guideline'
              ORDER BY created_at DESC
            SQL
            session_identifier
          ) do |rs|
            rs.each { guidelines << StoredEntry.from_row(rs) }
          end

          db.query(
            <<-SQL,
              SELECT id, created_at, session_identifier, entry_type, source, content, content_hash, metadata, importance, category, keywords, applies_when, source_file
              FROM ledger_entries
              WHERE session_identifier = ? AND entry_type = 'implementation_plan'
              ORDER BY created_at DESC
            SQL
            session_identifier
          ) do |rs|
            rs.each { impl_plans << StoredEntry.from_row(rs) }
          end

          db.query(
            <<-SQL,
              SELECT id, created_at, session_identifier, entry_type, source, content, content_hash, metadata, importance, category, keywords, applies_when, source_file
              FROM ledger_entries
              WHERE session_identifier = ? AND entry_type = 'decision' AND importance = 'high'
              ORDER BY created_at DESC
              LIMIT ?
            SQL
            session_identifier,
            decision_limit
          ) do |rs|
            rs.each { decisions << StoredEntry.from_row(rs) }
          end
        end
      rescue
        # Return empty on error
      end

      Tier1Result.new(guidelines, impl_plans, decisions)
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
      session_identifier : String,
      learnings_limit : Int32 = 5,
      decisions_limit : Int32 = 5,
    ) : Tier2Result
      learnings = [] of StoredEntry
      decisions = [] of StoredEntry

      return Tier2Result.new(learnings, decisions) if session_identifier.empty?

      begin
        open do |db|
          db.query(
            <<-SQL,
              SELECT id, created_at, session_identifier, entry_type, source, content, content_hash, metadata, importance, category, keywords, applies_when, source_file
              FROM ledger_entries
              WHERE session_identifier = ? AND entry_type = 'learning'
              ORDER BY created_at DESC
              LIMIT ?
            SQL
            session_identifier,
            learnings_limit
          ) do |rs|
            rs.each { learnings << StoredEntry.from_row(rs) }
          end

          db.query(
            <<-SQL,
              SELECT id, created_at, session_identifier, entry_type, source, content, content_hash, metadata, importance, category, keywords, applies_when, source_file
              FROM ledger_entries
              WHERE session_identifier = ? AND entry_type = 'decision' AND importance = 'medium'
              ORDER BY created_at DESC
              LIMIT ?
            SQL
            session_identifier,
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
      session_identifier : String,
      tier1_decision_limit : Int32 = 10,
      tier2_learnings_limit : Int32 = 5,
      tier2_decisions_limit : Int32 = 5,
    ) : RestorationResult
      tier1 = query_tier1(session_identifier, tier1_decision_limit)
      tier2 = query_tier2(session_identifier, tier2_learnings_limit, tier2_decisions_limit)
      RestorationResult.new(tier1, tier2)
    end

    # ============================================================
    # Data Structs
    # ============================================================

    # A session record from the database
    struct SessionRecord
      getter id : Int64
      getter session_identifier : String
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
      getter cumulative_tokens_used : Int64
      getter cumulative_cost_usd : Int64
      getter lines_added : Int64
      getter lines_removed : Int64
      getter context : String
      getter last_interaction : String?

      def initialize(
        @id, @session_identifier, @started_at, @updated_at,
        @cwd, @project_dir, @git_branch,
        @model_id, @model_display_name, @claude_version,
        @context_percentage, @tokens_used, @tokens_max, @cost_usd,
        @cumulative_tokens_used, @cumulative_cost_usd,
        @lines_added, @lines_removed, @context, @last_interaction,
      )
      end

      def self.from_row(rs) : SessionRecord
        SessionRecord.new(
          id: rs.read(Int64),
          session_identifier: rs.read(String),
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
          cumulative_tokens_used: rs.read(Int64),
          cumulative_cost_usd: rs.read(Int64),
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
      getter session_identifier : String
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

      def initialize(
        @id, @ledger_session_id, @session_identifier, @file_path, @search_pattern,
        @is_read, @is_edited, @is_written, @is_searched,
        @first_seen_at, @last_seen_at, @access_count, @metadata,
      )
      end

      def self.from_row(rs) : SessionFile
        SessionFile.new(
          id: rs.read(Int64),
          ledger_session_id: rs.read(Int64),
          session_identifier: rs.read(String),
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
        )
      end
    end

    # A ledger entry from the database
    struct StoredEntry
      getter id : Int64
      getter created_at : String
      getter session_identifier : String
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
        @session_identifier,
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
          session_identifier: rs.read(String),
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

    # Session statistics
    struct SessionStat
      getter session_identifier : String
      getter entry_count : Int32
      getter last_entry : String

      def initialize(@session_identifier, @entry_count, @last_entry)
      end
    end
  end
end
