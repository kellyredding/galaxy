require "db"
require "sqlite3"
require "digest/sha256"

module GalaxyLedger
  # SQLite database for persistent ledger storage
  # Location: ~/.claude/galaxy/data/ledger.db
  #
  # Provides:
  # - Schema creation with FTS5 full-text search
  # - Content hash deduplication (SHA256)
  # - Insert with ON CONFLICT DO NOTHING
  # - Query operations (by session, by type, FTS search)
  module Database
    # Database file path
    DATABASE_PATH = GalaxyLedger::GALAXY_DIR / "data" / "ledger.db"

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
    def self.create_schema
      db_path = database_path
      data_dir = db_path.parent
      Dir.mkdir_p(data_dir) unless Dir.exists?(data_dir)

      DB.open("sqlite3://#{db_path}") do |db|
        db.exec(<<-SQL)
          CREATE TABLE IF NOT EXISTS ledger_entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            entry_type TEXT NOT NULL,
            source TEXT,
            content TEXT NOT NULL,
            content_hash TEXT NOT NULL,
            metadata TEXT,
            importance TEXT DEFAULT 'medium',
            created_at TEXT DEFAULT (datetime('now'))
          )
        SQL

        # Indexes for common queries
        db.exec("CREATE INDEX IF NOT EXISTS idx_session ON ledger_entries(session_id)")
        db.exec("CREATE INDEX IF NOT EXISTS idx_session_type ON ledger_entries(session_id, entry_type)")
        db.exec("CREATE INDEX IF NOT EXISTS idx_source ON ledger_entries(source)")
        db.exec("CREATE INDEX IF NOT EXISTS idx_created ON ledger_entries(created_at)")
        db.exec("CREATE INDEX IF NOT EXISTS idx_importance ON ledger_entries(importance)")

        # Unique constraint for deduplication
        db.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_content_dedup ON ledger_entries(session_id, entry_type, content_hash)")

        # Full-text search virtual table
        db.exec(<<-SQL)
          CREATE VIRTUAL TABLE IF NOT EXISTS ledger_fts USING fts5(
            content,
            entry_type,
            content='ledger_entries',
            content_rowid='id'
          )
        SQL

        # Triggers to keep FTS in sync
        db.exec(<<-SQL)
          CREATE TRIGGER IF NOT EXISTS ledger_ai AFTER INSERT ON ledger_entries BEGIN
            INSERT INTO ledger_fts(rowid, content, entry_type)
            VALUES (new.id, new.content, new.entry_type);
          END
        SQL

        db.exec(<<-SQL)
          CREATE TRIGGER IF NOT EXISTS ledger_ad AFTER DELETE ON ledger_entries BEGIN
            INSERT INTO ledger_fts(ledger_fts, rowid, content, entry_type)
            VALUES('delete', old.id, old.content, old.entry_type);
          END
        SQL

        db.exec(<<-SQL)
          CREATE TRIGGER IF NOT EXISTS ledger_au AFTER UPDATE ON ledger_entries BEGIN
            INSERT INTO ledger_fts(ledger_fts, rowid, content, entry_type)
            VALUES('delete', old.id, old.content, old.entry_type);
            INSERT INTO ledger_fts(rowid, content, entry_type)
            VALUES (new.id, new.content, new.entry_type);
          END
        SQL
      end
    end

    # Insert a buffer entry into the database
    # Returns true if inserted, false if duplicate (content_hash conflict)
    def self.insert(session_id : String, entry : Buffer::Entry) : Bool
      return false if session_id.empty?
      return false unless entry.valid?

      hash = content_hash(entry.entry_type, entry.content)
      metadata_json = entry.metadata.try(&.to_json)

      begin
        open do |db|
          result = db.exec(
            <<-SQL,
              INSERT INTO ledger_entries (session_id, entry_type, source, content, content_hash, metadata, importance, created_at)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?)
              ON CONFLICT (session_id, entry_type, content_hash) DO NOTHING
            SQL
            session_id,
            entry.entry_type,
            entry.source,
            entry.content,
            hash,
            metadata_json,
            entry.importance,
            entry.created_at
          )
          result.rows_affected > 0
        end
      rescue
        false
      end
    end

    # Insert multiple entries (batch insert)
    # Returns count of entries actually inserted (excludes duplicates)
    def self.insert_many(session_id : String, entries : Array(Buffer::Entry)) : Int32
      return 0 if session_id.empty?
      return 0 if entries.empty?

      inserted = 0
      begin
        open do |db|
          entries.each do |entry|
            next unless entry.valid?

            hash = content_hash(entry.entry_type, entry.content)
            metadata_json = entry.metadata.try(&.to_json)

            result = db.exec(
              <<-SQL,
                INSERT INTO ledger_entries (session_id, entry_type, source, content, content_hash, metadata, importance, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (session_id, entry_type, content_hash) DO NOTHING
              SQL
              session_id,
              entry.entry_type,
              entry.source,
              entry.content,
              hash,
              metadata_json,
              entry.importance,
              entry.created_at
            )
            inserted += 1 if result.rows_affected > 0
          end
        end
      rescue
        # Return count so far
      end
      inserted
    end

    # Delete all entries for a session
    # Returns count of entries deleted
    def self.delete_session(session_id : String) : Int32
      return 0 if session_id.empty?

      begin
        open do |db|
          result = db.exec("DELETE FROM ledger_entries WHERE session_id = ?", session_id)
          result.rows_affected.to_i
        end
      rescue
        0
      end
    end

    # Count all entries
    def self.count : Int32
      begin
        open do |db|
          db.scalar("SELECT COUNT(*) FROM ledger_entries").as(Int64).to_i
        end
      rescue
        0
      end
    end

    # Count entries for a session
    def self.count_by_session(session_id : String) : Int32
      return 0 if session_id.empty?

      begin
        open do |db|
          db.scalar("SELECT COUNT(*) FROM ledger_entries WHERE session_id = ?", session_id).as(Int64).to_i
        end
      rescue
        0
      end
    end

    # Query entries by session (most recent first)
    def self.query_by_session(session_id : String, limit : Int32 = 100) : Array(LedgerEntry)
      return [] of LedgerEntry if session_id.empty?

      entries = [] of LedgerEntry
      begin
        open do |db|
          db.query(
            <<-SQL,
              SELECT id, session_id, entry_type, source, content, content_hash, metadata, importance, created_at
              FROM ledger_entries
              WHERE session_id = ?
              ORDER BY created_at DESC
              LIMIT ?
            SQL
            session_id,
            limit
          ) do |rs|
            rs.each do
              entries << LedgerEntry.from_row(rs)
            end
          end
        end
      rescue
        # Return empty on error
      end
      entries
    end

    # Query entries by type for a session
    def self.query_by_type(session_id : String, entry_type : String, limit : Int32 = 100) : Array(LedgerEntry)
      return [] of LedgerEntry if session_id.empty?

      entries = [] of LedgerEntry
      begin
        open do |db|
          db.query(
            <<-SQL,
              SELECT id, session_id, entry_type, source, content, content_hash, metadata, importance, created_at
              FROM ledger_entries
              WHERE session_id = ? AND entry_type = ?
              ORDER BY created_at DESC
              LIMIT ?
            SQL
            session_id,
            entry_type,
            limit
          ) do |rs|
            rs.each do
              entries << LedgerEntry.from_row(rs)
            end
          end
        end
      rescue
        # Return empty on error
      end
      entries
    end

    # Query entries by importance for a session
    def self.query_by_importance(session_id : String, importance : String, limit : Int32 = 100) : Array(LedgerEntry)
      return [] of LedgerEntry if session_id.empty?

      entries = [] of LedgerEntry
      begin
        open do |db|
          db.query(
            <<-SQL,
              SELECT id, session_id, entry_type, source, content, content_hash, metadata, importance, created_at
              FROM ledger_entries
              WHERE session_id = ? AND importance = ?
              ORDER BY created_at DESC
              LIMIT ?
            SQL
            session_id,
            importance,
            limit
          ) do |rs|
            rs.each do
              entries << LedgerEntry.from_row(rs)
            end
          end
        end
      rescue
        # Return empty on error
      end
      entries
    end

    # Query most recent entries across all sessions
    def self.query_recent(limit : Int32 = 100) : Array(LedgerEntry)
      entries = [] of LedgerEntry
      begin
        open do |db|
          db.query(
            <<-SQL,
              SELECT id, session_id, entry_type, source, content, content_hash, metadata, importance, created_at
              FROM ledger_entries
              ORDER BY created_at DESC
              LIMIT ?
            SQL
            limit
          ) do |rs|
            rs.each do
              entries << LedgerEntry.from_row(rs)
            end
          end
        end
      rescue
        # Return empty on error
      end
      entries
    end

    # Prepare FTS5 query with prefix matching
    # Adds * suffix to each word for prefix matching
    # Example: "trailing comma" -> "trailing* comma*"
    def self.prepare_fts_query(query : String, prefix_match : Bool = true) : String
      return query unless prefix_match

      # Split on whitespace, add * to each word, rejoin
      words = query.strip.split(/\s+/)
      words.map { |word|
        # Don't add * if word already ends with * or contains special FTS operators
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
      getter prefix_match : Bool

      def initialize(
        @entry_type : String? = nil,
        @importance : String? = nil,
        @prefix_match : Bool = true
      )
      end
    end

    # Full-text search across all entries with optional filters
    def self.search(
      query : String,
      limit : Int32 = 50,
      entry_type : String? = nil,
      importance : String? = nil,
      prefix_match : Bool = true
    ) : Array(LedgerEntry)
      return [] of LedgerEntry if query.strip.empty?

      fts_query = prepare_fts_query(query, prefix_match)
      entries = [] of LedgerEntry

      begin
        open do |db|
          # Build query with optional filters
          sql = String.build do |s|
            s << <<-SQL
              SELECT e.id, e.session_id, e.entry_type, e.source, e.content, e.content_hash, e.metadata, e.importance, e.created_at
              FROM ledger_entries e
              JOIN ledger_fts f ON e.id = f.rowid
              WHERE ledger_fts MATCH ?
            SQL
            s << " AND e.entry_type = ?" if entry_type
            s << " AND e.importance = ?" if importance
            s << " ORDER BY rank LIMIT ?"
          end

          # Build args array based on filters
          args = [fts_query] of DB::Any
          args << entry_type if entry_type
          args << importance if importance
          args << limit

          db.query(sql, args: args) do |rs|
            rs.each do
              entries << LedgerEntry.from_row(rs)
            end
          end
        end
      rescue
        # Return empty on error
      end
      entries
    end

    # Full-text search within a session with optional filters
    def self.search_in_session(
      session_id : String,
      query : String,
      limit : Int32 = 50,
      entry_type : String? = nil,
      importance : String? = nil,
      prefix_match : Bool = true
    ) : Array(LedgerEntry)
      return [] of LedgerEntry if session_id.empty?
      return [] of LedgerEntry if query.strip.empty?

      fts_query = prepare_fts_query(query, prefix_match)
      entries = [] of LedgerEntry

      begin
        open do |db|
          # Build query with optional filters
          sql = String.build do |s|
            s << <<-SQL
              SELECT e.id, e.session_id, e.entry_type, e.source, e.content, e.content_hash, e.metadata, e.importance, e.created_at
              FROM ledger_entries e
              JOIN ledger_fts f ON e.id = f.rowid
              WHERE e.session_id = ? AND ledger_fts MATCH ?
            SQL
            s << " AND e.entry_type = ?" if entry_type
            s << " AND e.importance = ?" if importance
            s << " ORDER BY rank LIMIT ?"
          end

          # Build args array based on filters
          args = [session_id, fts_query] of DB::Any
          args << entry_type if entry_type
          args << importance if importance
          args << limit

          db.query(sql, args: args) do |rs|
            rs.each do
              entries << LedgerEntry.from_row(rs)
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
              SELECT session_id, COUNT(*) as entry_count, MAX(created_at) as last_entry
              FROM ledger_entries
              GROUP BY session_id
              ORDER BY last_entry DESC
            SQL
          ) do |rs|
            rs.each do
              stats << SessionStat.new(
                session_id: rs.read(String),
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

    # Query recent entries with optional type and importance filters
    # Used by list command with filters
    def self.query_recent_filtered(
      limit : Int32 = 100,
      entry_type : String? = nil,
      importance : String? = nil
    ) : Array(LedgerEntry)
      entries = [] of LedgerEntry
      begin
        open do |db|
          sql = String.build do |s|
            s << <<-SQL
              SELECT id, session_id, entry_type, source, content, content_hash, metadata, importance, created_at
              FROM ledger_entries
              WHERE 1=1
            SQL
            s << " AND entry_type = ?" if entry_type
            s << " AND importance = ?" if importance
            s << " ORDER BY created_at DESC LIMIT ?"
          end

          args = [] of DB::Any
          args << entry_type if entry_type
          args << importance if importance
          args << limit

          db.query(sql, args: args) do |rs|
            rs.each do
              entries << LedgerEntry.from_row(rs)
            end
          end
        end
      rescue
        # Return empty on error
      end
      entries
    end

    # ============================================================
    # Tiered Restoration Queries (for Phase 7 context restoration)
    # ============================================================

    # Tier 1: Essential context that should always be restored
    # - Guidelines (extracted from guideline files)
    # - Implementation plans (extracted from implementation plan files)
    # - High-importance decisions
    struct Tier1Result
      getter guidelines : Array(LedgerEntry)
      getter implementation_plans : Array(LedgerEntry)
      getter high_importance_decisions : Array(LedgerEntry)

      def initialize(@guidelines, @implementation_plans, @high_importance_decisions)
      end

      def total_count : Int32
        guidelines.size + implementation_plans.size + high_importance_decisions.size
      end
    end

    # Query Tier 1 essentials for a session
    def self.query_tier1(session_id : String, decision_limit : Int32 = 10) : Tier1Result
      guidelines = [] of LedgerEntry
      impl_plans = [] of LedgerEntry
      decisions = [] of LedgerEntry

      return Tier1Result.new(guidelines, impl_plans, decisions) if session_id.empty?

      begin
        open do |db|
          # All guidelines for this session
          db.query(
            <<-SQL,
              SELECT id, session_id, entry_type, source, content, content_hash, metadata, importance, created_at
              FROM ledger_entries
              WHERE session_id = ? AND entry_type = 'guideline'
              ORDER BY created_at DESC
            SQL
            session_id
          ) do |rs|
            rs.each { guidelines << LedgerEntry.from_row(rs) }
          end

          # All implementation plans for this session
          db.query(
            <<-SQL,
              SELECT id, session_id, entry_type, source, content, content_hash, metadata, importance, created_at
              FROM ledger_entries
              WHERE session_id = ? AND entry_type = 'implementation_plan'
              ORDER BY created_at DESC
            SQL
            session_id
          ) do |rs|
            rs.each { impl_plans << LedgerEntry.from_row(rs) }
          end

          # High-importance decisions (limited)
          db.query(
            <<-SQL,
              SELECT id, session_id, entry_type, source, content, content_hash, metadata, importance, created_at
              FROM ledger_entries
              WHERE session_id = ? AND entry_type = 'decision' AND importance = 'high'
              ORDER BY created_at DESC
              LIMIT ?
            SQL
            session_id,
            decision_limit
          ) do |rs|
            rs.each { decisions << LedgerEntry.from_row(rs) }
          end
        end
      rescue
        # Return empty on error
      end

      Tier1Result.new(guidelines, impl_plans, decisions)
    end

    # Tier 2: Supporting context (most recent, configurable limits)
    # - Recent learnings
    # - Recent file edits
    # - Medium-importance decisions
    struct Tier2Result
      getter learnings : Array(LedgerEntry)
      getter file_edits : Array(LedgerEntry)
      getter medium_decisions : Array(LedgerEntry)

      def initialize(@learnings, @file_edits, @medium_decisions)
      end

      def total_count : Int32
        learnings.size + file_edits.size + medium_decisions.size
      end
    end

    # Query Tier 2 supporting context for a session
    def self.query_tier2(
      session_id : String,
      learnings_limit : Int32 = 5,
      file_edits_limit : Int32 = 10,
      decisions_limit : Int32 = 5
    ) : Tier2Result
      learnings = [] of LedgerEntry
      file_edits = [] of LedgerEntry
      decisions = [] of LedgerEntry

      return Tier2Result.new(learnings, file_edits, decisions) if session_id.empty?

      begin
        open do |db|
          # Recent learnings (all importance levels)
          db.query(
            <<-SQL,
              SELECT id, session_id, entry_type, source, content, content_hash, metadata, importance, created_at
              FROM ledger_entries
              WHERE session_id = ? AND entry_type = 'learning'
              ORDER BY created_at DESC
              LIMIT ?
            SQL
            session_id,
            learnings_limit
          ) do |rs|
            rs.each { learnings << LedgerEntry.from_row(rs) }
          end

          # Recent file edits
          db.query(
            <<-SQL,
              SELECT id, session_id, entry_type, source, content, content_hash, metadata, importance, created_at
              FROM ledger_entries
              WHERE session_id = ? AND entry_type = 'file_edit'
              ORDER BY created_at DESC
              LIMIT ?
            SQL
            session_id,
            file_edits_limit
          ) do |rs|
            rs.each { file_edits << LedgerEntry.from_row(rs) }
          end

          # Medium-importance decisions
          db.query(
            <<-SQL,
              SELECT id, session_id, entry_type, source, content, content_hash, metadata, importance, created_at
              FROM ledger_entries
              WHERE session_id = ? AND entry_type = 'decision' AND importance = 'medium'
              ORDER BY created_at DESC
              LIMIT ?
            SQL
            session_id,
            decisions_limit
          ) do |rs|
            rs.each { decisions << LedgerEntry.from_row(rs) }
          end
        end
      rescue
        # Return empty on error
      end

      Tier2Result.new(learnings, file_edits, decisions)
    end

    # Combined restoration query - returns both tiers
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
      session_id : String,
      tier1_decision_limit : Int32 = 10,
      tier2_learnings_limit : Int32 = 5,
      tier2_file_edits_limit : Int32 = 10,
      tier2_decisions_limit : Int32 = 5
    ) : RestorationResult
      tier1 = query_tier1(session_id, tier1_decision_limit)
      tier2 = query_tier2(session_id, tier2_learnings_limit, tier2_file_edits_limit, tier2_decisions_limit)
      RestorationResult.new(tier1, tier2)
    end

    # A ledger entry from the database
    struct LedgerEntry
      getter id : Int64
      getter session_id : String
      getter entry_type : String
      getter source : String?
      getter content : String
      getter content_hash : String
      getter metadata : String?
      getter importance : String
      getter created_at : String

      def initialize(
        @id,
        @session_id,
        @entry_type,
        @source,
        @content,
        @content_hash,
        @metadata,
        @importance,
        @created_at
      )
      end

      def self.from_row(rs) : LedgerEntry
        LedgerEntry.new(
          id: rs.read(Int64),
          session_id: rs.read(String),
          entry_type: rs.read(String),
          source: rs.read(String?),
          content: rs.read(String),
          content_hash: rs.read(String),
          metadata: rs.read(String?),
          importance: rs.read(String),
          created_at: rs.read(String)
        )
      end

      # Convert to Buffer::Entry for compatibility
      def to_buffer_entry : Buffer::Entry
        metadata_any = if m = metadata
                         JSON.parse(m)
                       else
                         nil
                       end

        Buffer::Entry.new(
          entry_type: entry_type,
          content: content,
          importance: importance,
          source: source,
          metadata: metadata_any,
          created_at: created_at
        )
      end
    end

    # Session statistics
    struct SessionStat
      getter session_id : String
      getter entry_count : Int32
      getter last_entry : String

      def initialize(@session_id, @entry_count, @last_entry)
      end
    end
  end
end
