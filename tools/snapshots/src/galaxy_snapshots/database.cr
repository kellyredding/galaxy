require "db"
require "sqlite3"
require "file_utils"

module GalaxySnapshots
  # SQLite database for snapshot storage
  # Location: ~/.claude/galaxy/data/snapshots.db
  #
  # Provides:
  # - Schema creation and migration
  # - Snapshot records with session reference (ledger_session_id)
  # - Snapshot annotation and review records
  # - Backup and prune operations
  module Database
    # Database file path
    DATABASE_PATH = GalaxySnapshots::DATA_DIR / "snapshots.db"

    # Get database path (allows override via env for testing)
    def self.database_path : Path
      Path.new(
        ENV.fetch(
          "GALAXY_SNAPSHOTS_DATABASE_PATH",
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

        # Snapshots table (no FK on ledger_session_id — it's stored as a plain integer reference)
        db.exec(<<-SQL)
          CREATE TABLE IF NOT EXISTS snapshots (
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
            UNIQUE(ledger_session_id, number)
          )
        SQL

        db.exec(<<-SQL)
          CREATE INDEX IF NOT EXISTS idx_snapshots_session
          ON snapshots(ledger_session_id)
        SQL

        # Snapshot annotations table
        db.exec(<<-SQL)
          CREATE TABLE IF NOT EXISTS snapshot_annotations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now')),
            snapshot_id INTEGER NOT NULL,
            number INTEGER NOT NULL,
            start_line INTEGER NOT NULL,
            end_line INTEGER NOT NULL,
            content TEXT NOT NULL,
            snapshot_review_id INTEGER
              REFERENCES snapshot_reviews(id) ON DELETE SET NULL,
            UNIQUE(snapshot_id, number),
            FOREIGN KEY (snapshot_id)
              REFERENCES snapshots(id) ON DELETE CASCADE
          )
        SQL

        db.exec(<<-SQL)
          CREATE INDEX IF NOT EXISTS idx_snapshot_annotations_snapshot
          ON snapshot_annotations(snapshot_id)
        SQL

        # Snapshot reviews table
        db.exec(<<-SQL)
          CREATE TABLE IF NOT EXISTS snapshot_reviews (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now')),
            snapshot_id INTEGER NOT NULL,
            number INTEGER NOT NULL,
            reviewed_at TEXT,
            UNIQUE(snapshot_id, number),
            FOREIGN KEY (snapshot_id)
              REFERENCES snapshots(id) ON DELETE CASCADE
          )
        SQL

        db.exec(<<-SQL)
          CREATE INDEX IF NOT EXISTS idx_snapshot_reviews_snapshot
          ON snapshot_reviews(snapshot_id)
        SQL

        # Stamp with current version
        Migrations.set_database_version(db, GalaxySnapshots::VERSION)
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
              INSERT INTO snapshots (
                ledger_session_id, number, title, content,
                exchange_count, char_count, metadata
              )
              VALUES (
                ?, (SELECT COALESCE(MAX(number), 0) + 1 FROM snapshots WHERE ledger_session_id = ?),
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
            "SELECT number FROM snapshots WHERE id = last_insert_rowid()",
            as: Int64,
          ).try(&.to_i) || 0
        end
      rescue
        0
      end
    end

    # List all snapshots for a session, ordered by number (chronological).
    # `limit` is opt-in — nil returns every snapshot for the session.
    # Matches galaxy-agents' list_agents pattern and fixes the
    # silent-truncation bug from the previous default limit of 50.
    def self.list_snapshots(ledger_session_id : Int64, limit : Int32? = nil) : Array(Snapshot)
      snapshots = [] of Snapshot
      return snapshots if ledger_session_id <= 0

      begin
        open do |db|
          sql = <<-SQL
            SELECT id, ledger_session_id, number, created_at, updated_at,
                   title, content, exchange_count, char_count, metadata
            FROM snapshots
            WHERE ledger_session_id = ?
            ORDER BY number ASC
          SQL
          sql += " LIMIT #{limit}" if limit
          db.query(
            sql,
            ledger_session_id,
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
    # `limit` is opt-in — nil returns every snapshot for the session.
    def self.list_snapshots_with_counts(
      ledger_session_id : Int64,
      limit : Int32? = nil,
    ) : Array(SnapshotListItem)
      items = [] of SnapshotListItem
      return items if ledger_session_id <= 0

      begin
        open do |db|
          sql = <<-SQL
            SELECT s.id, s.ledger_session_id, s.number,
                   s.created_at, s.title,
                   s.exchange_count, s.char_count,
                   COUNT(sr.id) AS review_count
            FROM snapshots s
            LEFT JOIN snapshot_reviews sr
              ON s.id = sr.snapshot_id
            WHERE s.ledger_session_id = ?
            GROUP BY s.id
            ORDER BY s.number ASC
          SQL
          sql += " LIMIT #{limit}" if limit
          db.query(
            sql,
            ledger_session_id,
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
              FROM snapshots
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

    # Get a snapshot by its database primary key.
    def self.get_snapshot_by_id(id : Int64) : Snapshot?
      return nil if id <= 0

      begin
        open do |db|
          db.query_one?(
            <<-SQL,
              SELECT id, ledger_session_id, number, created_at,
                     updated_at, title, content, exchange_count,
                     char_count, metadata
              FROM snapshots
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

    # Delete a snapshot by session + number. Returns true if deleted.
    def self.delete_snapshot_by_number(ledger_session_id : Int64, number : Int32) : Bool
      return false if ledger_session_id <= 0

      begin
        open do |db|
          result = db.exec(
            "DELETE FROM snapshots WHERE ledger_session_id = ? AND number = ?",
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
              FROM snapshots
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
      snapshot_id : Int64,
      start_line : Int32,
      end_line : Int32,
      content : String,
    ) : SnapshotAnnotation?
      return nil if snapshot_id <= 0

      begin
        open do |db|
          db.exec(
            <<-SQL,
              INSERT INTO snapshot_annotations (
                snapshot_id, number, start_line, end_line, content
              )
              VALUES (
                ?,
                (SELECT COALESCE(MAX(number), 0) + 1 FROM snapshot_annotations WHERE snapshot_id = ?),
                ?, ?, ?
              )
            SQL
            snapshot_id,
            snapshot_id,
            start_line,
            end_line,
            content,
          )
          # Retrieve the full annotation that was just created
          db.query_one?(
            <<-SQL
              SELECT a.id, a.created_at, a.updated_at, a.snapshot_id,
                     a.number, a.start_line, a.end_line, a.content,
                     a.snapshot_review_id,
                     r.number AS review_number,
                     r.reviewed_at AS review_reviewed_at
              FROM snapshot_annotations a
              LEFT JOIN snapshot_reviews r
                ON a.snapshot_review_id = r.id
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
    def self.list_snapshot_annotations(snapshot_id : Int64) : Array(SnapshotAnnotation)
      annotations = [] of SnapshotAnnotation
      return annotations if snapshot_id <= 0

      begin
        open do |db|
          db.query(
            <<-SQL,
              SELECT a.id, a.created_at, a.updated_at, a.snapshot_id,
                     a.number, a.start_line, a.end_line, a.content,
                     a.snapshot_review_id,
                     r.number AS review_number,
                     r.reviewed_at AS review_reviewed_at
              FROM snapshot_annotations a
              LEFT JOIN snapshot_reviews r
                ON a.snapshot_review_id = r.id
              WHERE a.snapshot_id = ?
              ORDER BY a.start_line ASC, a.end_line ASC, a.number ASC
            SQL
            snapshot_id,
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
    def self.get_snapshot_annotation(snapshot_id : Int64, number : Int32) : SnapshotAnnotation?
      return nil if snapshot_id <= 0

      begin
        open do |db|
          db.query_one?(
            <<-SQL,
              SELECT a.id, a.created_at, a.updated_at, a.snapshot_id,
                     a.number, a.start_line, a.end_line, a.content,
                     a.snapshot_review_id,
                     r.number AS review_number,
                     r.reviewed_at AS review_reviewed_at
              FROM snapshot_annotations a
              LEFT JOIN snapshot_reviews r
                ON a.snapshot_review_id = r.id
              WHERE a.snapshot_id = ? AND a.number = ?
            SQL
            snapshot_id,
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
      snapshot_id : Int64,
      number : Int32,
      content : String,
    ) : SnapshotAnnotation?
      return nil if snapshot_id <= 0

      begin
        open do |db|
          result = db.exec(
            <<-SQL,
              UPDATE snapshot_annotations
              SET content = ?, updated_at = datetime('now')
              WHERE snapshot_id = ? AND number = ?
            SQL
            content,
            snapshot_id,
            number,
          )
          return nil if result.rows_affected == 0

          # Return the updated annotation
          db.query_one?(
            <<-SQL,
              SELECT a.id, a.created_at, a.updated_at, a.snapshot_id,
                     a.number, a.start_line, a.end_line, a.content,
                     a.snapshot_review_id,
                     r.number AS review_number,
                     r.reviewed_at AS review_reviewed_at
              FROM snapshot_annotations a
              LEFT JOIN snapshot_reviews r
                ON a.snapshot_review_id = r.id
              WHERE a.snapshot_id = ? AND a.number = ?
            SQL
            snapshot_id,
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
    def self.delete_snapshot_annotation(snapshot_id : Int64, number : Int32) : Bool
      return false if snapshot_id <= 0

      begin
        open do |db|
          result = db.exec(
            "DELETE FROM snapshot_annotations WHERE snapshot_id = ? AND number = ?",
            snapshot_id,
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
      snapshot_id : Int64,
    ) : {SnapshotReview, Int32}?
      return nil if snapshot_id <= 0

      begin
        open do |db|
          db.exec("BEGIN IMMEDIATE")

          count = db.scalar(
            <<-SQL,
              SELECT COUNT(*)
              FROM snapshot_annotations
              WHERE snapshot_id = ?
                AND snapshot_review_id IS NULL
            SQL
            snapshot_id,
          ).as(Int64).to_i

          if count == 0
            db.exec("ROLLBACK")
            return nil
          end

          # Create the review with auto-assigned number
          db.exec(
            <<-SQL,
              INSERT INTO snapshot_reviews (
                snapshot_id, number
              )
              VALUES (
                ?,
                (SELECT COALESCE(MAX(number), 0) + 1
                 FROM snapshot_reviews
                 WHERE snapshot_id = ?)
              )
            SQL
            snapshot_id,
            snapshot_id,
          )

          review = db.query_one?(
            <<-SQL
              SELECT id, created_at, updated_at, snapshot_id,
                     number, reviewed_at
              FROM snapshot_reviews
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
              UPDATE snapshot_annotations
              SET snapshot_review_id = ?,
                  updated_at = datetime('now')
              WHERE snapshot_id = ?
                AND snapshot_review_id IS NULL
            SQL
            review.id,
            snapshot_id,
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
      snapshot_id : Int64,
      pending_only : Bool = false,
    ) : Array(SnapshotReview)
      reviews = [] of SnapshotReview
      return reviews if snapshot_id <= 0

      begin
        open do |db|
          where_clause = "WHERE snapshot_id = ?"
          if pending_only
            where_clause += " AND reviewed_at IS NULL"
          end

          db.query(
            <<-SQL,
              SELECT id, created_at, updated_at, snapshot_id,
                     number, reviewed_at
              FROM snapshot_reviews
              #{where_clause}
              ORDER BY number ASC
            SQL
            snapshot_id,
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
      snapshot_id : Int64,
      number : Int32,
    ) : SnapshotReview?
      return nil if snapshot_id <= 0

      begin
        open do |db|
          db.query_one?(
            <<-SQL,
              SELECT id, created_at, updated_at, snapshot_id,
                     number, reviewed_at
              FROM snapshot_reviews
              WHERE snapshot_id = ? AND number = ?
            SQL
            snapshot_id,
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
      snapshot_id : Int64,
      number : Int32,
    ) : SnapshotReview?
      return nil if snapshot_id <= 0

      begin
        open do |db|
          result = db.exec(
            <<-SQL,
              UPDATE snapshot_reviews
              SET reviewed_at = datetime('now'),
                  updated_at = datetime('now')
              WHERE snapshot_id = ? AND number = ?
            SQL
            snapshot_id,
            number,
          )
          return nil if result.rows_affected == 0

          db.query_one?(
            <<-SQL,
              SELECT id, created_at, updated_at, snapshot_id,
                     number, reviewed_at
              FROM snapshot_reviews
              WHERE snapshot_id = ? AND number = ?
            SQL
            snapshot_id,
            number,
          ) do |rs|
            SnapshotReview.from_row(rs)
          end
        end
      rescue
        nil
      end
    end

    # Count annotations not assigned to any review.
    def self.count_unreviewed_annotations(
      snapshot_id : Int64,
    ) : Int32
      return 0 if snapshot_id <= 0

      begin
        open do |db|
          db.scalar(
            <<-SQL,
              SELECT COUNT(*)
              FROM snapshot_annotations
              WHERE snapshot_id = ?
                AND snapshot_review_id IS NULL
            SQL
            snapshot_id,
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
              SELECT a.id, a.created_at, a.updated_at, a.snapshot_id,
                     a.number, a.start_line, a.end_line, a.content,
                     a.snapshot_review_id,
                     r.number AS review_number,
                     r.reviewed_at AS review_reviewed_at
              FROM snapshot_annotations a
              LEFT JOIN snapshot_reviews r
                ON a.snapshot_review_id = r.id
              WHERE a.snapshot_review_id = ?
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
    # Layout: backup_dir/YYYY-MM-DD/snapshots_SESSION_ID.db
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

      backup_file = date_dir / "snapshots_#{session_id}.db"

      # Remove any existing backup so VACUUM INTO can write a fresh file.
      File.delete(backup_file) if File.exists?(backup_file)

      open do |db|
        db.exec("VACUUM INTO '#{backup_file}'")
      end

      backup_file
    rescue ex
      STDERR.puts "[galaxy-snapshots] Backup failed: #{ex.message}"
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
      STDERR.puts "[galaxy-snapshots] Prune failed: #{ex.message}"
      0
    end

    # ============================================================
    # Data Structs
    # ============================================================

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
      getter snapshot_id : Int64
      getter number : Int32
      getter start_line : Int32
      getter end_line : Int32
      getter content : String
      getter snapshot_review_id : Int64?
      getter review_number : Int32?
      getter review_reviewed_at : String?

      def initialize(
        @id, @created_at, @updated_at, @snapshot_id,
        @number, @start_line, @end_line, @content,
        @snapshot_review_id, @review_number, @review_reviewed_at,
      )
      end

      def self.from_row(rs) : SnapshotAnnotation
        SnapshotAnnotation.new(
          id: rs.read(Int64),
          created_at: rs.read(String),
          updated_at: rs.read(String),
          snapshot_id: rs.read(Int64),
          number: rs.read(Int64).to_i,
          start_line: rs.read(Int64).to_i,
          end_line: rs.read(Int64).to_i,
          content: rs.read(String),
          snapshot_review_id: rs.read(Int64?),
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
      getter snapshot_id : Int64
      getter number : Int32
      getter reviewed_at : String?

      def initialize(
        @id, @created_at, @updated_at, @snapshot_id,
        @number, @reviewed_at,
      )
      end

      def self.from_row(rs) : SnapshotReview
        SnapshotReview.new(
          id: rs.read(Int64),
          created_at: rs.read(String),
          updated_at: rs.read(String),
          snapshot_id: rs.read(Int64),
          number: rs.read(Int64).to_i,
          reviewed_at: rs.read(String?),
        )
      end
    end
  end
end
