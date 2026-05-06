require "db"
require "sqlite3"
require "file_utils"

module GalaxyArtifacts
  # SQLite database for artifact storage
  # Location: ~/.claude/galaxy/data/artifacts.db
  #
  # Provides:
  # - Schema creation and migration
  # - Artifact records with session reference (ledger_session_id)
  # - Backup and prune operations
  module Database
    # Database file path
    DATABASE_PATH = GalaxyArtifacts::DATA_DIR / "artifacts.db"

    # Get database path (allows override via env for testing)
    def self.database_path : Path
      Path.new(
        ENV.fetch(
          "GALAXY_ARTIFACTS_DATABASE_PATH",
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

        # Artifacts table (no FK on ledger_session_id — it's stored as a plain integer reference)
        db.exec(<<-SQL)
          CREATE TABLE IF NOT EXISTS artifacts (
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
            UNIQUE(ledger_session_id, number)
          )
        SQL

        db.exec(<<-SQL)
          CREATE INDEX IF NOT EXISTS idx_artifacts_session
          ON artifacts(ledger_session_id)
        SQL

        db.exec(<<-SQL)
          CREATE UNIQUE INDEX IF NOT EXISTS idx_artifacts_source_path
          ON artifacts(ledger_session_id, source_path)
          WHERE source_path IS NOT NULL
        SQL

        # Artifact annotations table
        db.exec(<<-SQL)
          CREATE TABLE IF NOT EXISTS artifact_annotations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now')),
            artifact_id INTEGER NOT NULL,
            number INTEGER NOT NULL,
            content TEXT NOT NULL,
            anchor_data TEXT NOT NULL,
            content_hash TEXT NOT NULL,
            stale INTEGER NOT NULL DEFAULT 0,
            artifact_review_id INTEGER
              REFERENCES artifact_reviews(id) ON DELETE SET NULL,
            UNIQUE(artifact_id, number),
            FOREIGN KEY (artifact_id)
              REFERENCES artifacts(id) ON DELETE CASCADE
          )
        SQL

        db.exec(<<-SQL)
          CREATE INDEX IF NOT EXISTS idx_artifact_annotations_artifact
          ON artifact_annotations(artifact_id)
        SQL

        # Artifact reviews table
        db.exec(<<-SQL)
          CREATE TABLE IF NOT EXISTS artifact_reviews (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now')),
            artifact_id INTEGER NOT NULL,
            number INTEGER NOT NULL,
            reviewed_at TEXT,
            UNIQUE(artifact_id, number),
            FOREIGN KEY (artifact_id)
              REFERENCES artifacts(id) ON DELETE CASCADE
          )
        SQL

        db.exec(<<-SQL)
          CREATE INDEX IF NOT EXISTS idx_artifact_reviews_artifact
          ON artifact_reviews(artifact_id)
        SQL

        # Stamp with current version
        Migrations.set_database_version(db, GalaxyArtifacts::VERSION)
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
    # Artifact Operations
    # ============================================================

    # Save an artifact for a session with three-action dedup logic:
    # - Insert: new artifact, auto-assign number
    # - Enrichment: same source_path + same content_hash — update metadata only
    # - VersionUpdate: same source_path + different content_hash — update all fields
    # Returns SaveArtifactResult with action and number.
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
                SELECT number, content_hash, file_size
                FROM artifacts
                WHERE ledger_session_id = ? AND source_path = ?
              SQL
              ledger_session_id,
              source_path,
              as: {Int64, String, Int64},
            )

            if existing
              existing_number, existing_hash, existing_size = existing

              if existing_hash == content_hash
                # Enrichment: same file, same content — update metadata only.
                # Title updates only if the new title is longer (richer).
                db.exec(
                  <<-SQL,
                    UPDATE artifacts
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
                    UPDATE artifacts
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
                return SaveArtifactResult.new(
                  SaveArtifactAction::VersionUpdate,
                  existing_number.to_i,
                  previous_content_hash: existing_hash,
                  previous_file_size: existing_size,
                )
              end
            end
          end

          # No existing artifact — insert new.
          db.exec(
            <<-SQL,
              INSERT INTO artifacts (
                ledger_session_id, number, title, artifact_type,
                mime_type, original_filename, stored_path, source_path,
                file_size, content_hash, description, metadata
              )
              VALUES (
                ?,
                (SELECT COALESCE(MAX(number), 0) + 1
                 FROM artifacts
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
            "SELECT number FROM artifacts WHERE id = last_insert_rowid()",
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
    # `limit` is opt-in — nil returns every artifact for the
    # session. Matches the pattern in galaxy-agents'
    # list_agents and avoids the silent-truncation bug that the
    # previous default limit of 50 caused for sessions with
    # many artifacts.
    def self.list_artifacts(
      ledger_session_id : Int64,
      limit : Int32? = nil,
    ) : Array(Artifact)
      artifacts = [] of Artifact
      return artifacts if ledger_session_id <= 0

      begin
        open do |db|
          sql = <<-SQL
            SELECT id, ledger_session_id, number, created_at,
                   updated_at, title, artifact_type, mime_type,
                   original_filename, stored_path, source_path,
                   file_size, content_hash, description, metadata
            FROM artifacts
            WHERE ledger_session_id = ?
            ORDER BY number ASC
          SQL
          sql += " LIMIT #{limit}" if limit
          db.query(
            sql,
            ledger_session_id,
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
              FROM artifacts
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
            "DELETE FROM artifacts WHERE ledger_session_id = ? AND number = ?",
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

    # Get artifact count for a session.
    def self.session_artifact_count(
      ledger_session_id : Int64,
    ) : Int32
      return 0 if ledger_session_id <= 0

      begin
        open do |db|
          db.query_one?(
            "SELECT COUNT(*) FROM artifacts WHERE ledger_session_id = ?",
            ledger_session_id,
            as: Int64,
          ).try(&.to_i) || 0
        end
      rescue
        0
      end
    end

    # Reserve the next sequential artifact number for a session.
    # Used by the stdin streaming flow where we need the number
    # before content is written (to construct stored_path).
    #
    # Note: this is a read-only peek — no row is inserted. The
    # subsequent save_artifact INSERT uses the same SELECT
    # MAX(number)+1 expression, so in a single-process flow the
    # reserved number matches the number assigned at INSERT.
    # Returns the reserved number, or nil on failure.
    def self.reserve_next_number(
      ledger_session_id : Int64,
    ) : Int32?
      return nil if ledger_session_id <= 0

      begin
        open do |db|
          db.query_one?(
            <<-SQL,
              SELECT COALESCE(MAX(number), 0) + 1
              FROM artifacts
              WHERE ledger_session_id = ?
            SQL
            ledger_session_id,
            as: Int64,
          ).try(&.to_i)
        end
      rescue
        nil
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
          "UPDATE artifacts SET stored_path = ? WHERE ledger_session_id = ? AND number = ?",
          stored_path,
          ledger_session_id,
          number,
        )
      end
    rescue
      # Best-effort
    end

    # ============================================================
    # Annotation Operations
    # ============================================================

    # Save an artifact annotation. Number is auto-assigned as
    # artifact-scoped sequential (1, 2, 3, ...). Stores the
    # artifact's current content_hash for stale tracking.
    # Returns the created annotation or nil on failure.
    def self.save_annotation(
      artifact_id : Int64,
      content : String,
      anchor_data : String,
      content_hash : String,
    ) : ArtifactAnnotation?
      return nil if artifact_id <= 0

      begin
        open do |db|
          db.exec(
            <<-SQL,
              INSERT INTO artifact_annotations (
                artifact_id, number, content,
                anchor_data, content_hash
              )
              VALUES (
                ?,
                (SELECT COALESCE(MAX(number), 0) + 1
                 FROM artifact_annotations
                 WHERE artifact_id = ?),
                ?, ?, ?
              )
            SQL
            artifact_id,
            artifact_id,
            content,
            anchor_data,
            content_hash,
          )
          # Retrieve the full annotation just created
          db.query_one?(
            <<-SQL
              SELECT a.id, a.created_at, a.updated_at,
                     a.artifact_id, a.number, a.content,
                     a.anchor_data, a.content_hash, a.stale,
                     a.artifact_review_id,
                     r.number AS review_number,
                     r.reviewed_at AS review_reviewed_at
              FROM artifact_annotations a
              LEFT JOIN artifact_reviews r
                ON a.artifact_review_id = r.id
              WHERE a.id = last_insert_rowid()
            SQL
          ) do |rs|
            ArtifactAnnotation.from_row(rs)
          end
        end
      rescue
        nil
      end
    end

    # List all annotations for an artifact, ordered by number.
    def self.list_annotations(
      artifact_id : Int64,
    ) : Array(ArtifactAnnotation)
      annotations = [] of ArtifactAnnotation
      return annotations if artifact_id <= 0

      begin
        open do |db|
          db.query(
            <<-SQL,
              SELECT a.id, a.created_at, a.updated_at,
                     a.artifact_id, a.number, a.content,
                     a.anchor_data, a.content_hash, a.stale,
                     a.artifact_review_id,
                     r.number AS review_number,
                     r.reviewed_at AS review_reviewed_at
              FROM artifact_annotations a
              LEFT JOIN artifact_reviews r
                ON a.artifact_review_id = r.id
              WHERE a.artifact_id = ?
              ORDER BY a.number ASC
            SQL
            artifact_id,
          ) do |rs|
            rs.each do
              annotations << ArtifactAnnotation.from_row(rs)
            end
          end
        end
      rescue
        # Return empty on error
      end
      annotations
    end

    # Get an annotation by artifact ID + number.
    def self.get_annotation(
      artifact_id : Int64,
      number : Int32,
    ) : ArtifactAnnotation?
      return nil if artifact_id <= 0

      begin
        open do |db|
          db.query_one?(
            <<-SQL,
              SELECT a.id, a.created_at, a.updated_at,
                     a.artifact_id, a.number, a.content,
                     a.anchor_data, a.content_hash, a.stale,
                     a.artifact_review_id,
                     r.number AS review_number,
                     r.reviewed_at AS review_reviewed_at
              FROM artifact_annotations a
              LEFT JOIN artifact_reviews r
                ON a.artifact_review_id = r.id
              WHERE a.artifact_id = ? AND a.number = ?
            SQL
            artifact_id,
            number,
          ) do |rs|
            ArtifactAnnotation.from_row(rs)
          end
        end
      rescue
        nil
      end
    end

    # Update annotation content. Anchor data is immutable.
    # Returns the updated annotation or nil if not found.
    def self.update_annotation(
      artifact_id : Int64,
      number : Int32,
      content : String,
    ) : ArtifactAnnotation?
      return nil if artifact_id <= 0

      begin
        open do |db|
          result = db.exec(
            <<-SQL,
              UPDATE artifact_annotations
              SET content = ?,
                  updated_at = datetime('now')
              WHERE artifact_id = ? AND number = ?
            SQL
            content,
            artifact_id,
            number,
          )
          return nil if result.rows_affected == 0

          # Return the updated annotation
          db.query_one?(
            <<-SQL,
              SELECT a.id, a.created_at, a.updated_at,
                     a.artifact_id, a.number, a.content,
                     a.anchor_data, a.content_hash, a.stale,
                     a.artifact_review_id,
                     r.number AS review_number,
                     r.reviewed_at AS review_reviewed_at
              FROM artifact_annotations a
              LEFT JOIN artifact_reviews r
                ON a.artifact_review_id = r.id
              WHERE a.artifact_id = ? AND a.number = ?
            SQL
            artifact_id,
            number,
          ) do |rs|
            ArtifactAnnotation.from_row(rs)
          end
        end
      rescue
        nil
      end
    end

    # Delete an annotation by artifact ID + number.
    # Returns true if deleted.
    def self.delete_annotation(
      artifact_id : Int64,
      number : Int32,
    ) : Bool
      return false if artifact_id <= 0

      begin
        open do |db|
          result = db.exec(
            "DELETE FROM artifact_annotations " \
            "WHERE artifact_id = ? AND number = ?",
            artifact_id,
            number,
          )
          result.rows_affected > 0
        end
      rescue
        false
      end
    end

    # Mark all non-stale annotations as stale for an artifact.
    # Called when artifact content changes (VersionUpdate).
    # Returns the number of annotations marked stale.
    def self.mark_annotations_stale(
      artifact_id : Int64,
    ) : Int64
      return 0_i64 if artifact_id <= 0

      begin
        open do |db|
          result = db.exec(
            <<-SQL,
              UPDATE artifact_annotations
              SET stale = 1,
                  updated_at = datetime('now')
              WHERE artifact_id = ? AND stale = 0
            SQL
            artifact_id,
          )
          result.rows_affected
        end
      rescue
        0_i64
      end
    end

    # Count annotations not assigned to any review.
    def self.count_unreviewed_annotations(
      artifact_id : Int64,
    ) : Int32
      return 0 if artifact_id <= 0

      begin
        open do |db|
          db.scalar(
            <<-SQL,
              SELECT COUNT(*)
              FROM artifact_annotations
              WHERE artifact_id = ?
                AND artifact_review_id IS NULL
            SQL
            artifact_id,
          ).as(Int64).to_i
        end
      rescue
        0
      end
    end

    # ============================================================
    # Review Operations
    # ============================================================

    # Create a review and assign all unreviewed annotations
    # atomically. Returns {review, annotation_count} or nil
    # if no unreviewed annotations exist.
    def self.save_review(
      artifact_id : Int64,
    ) : {ArtifactReview, Int32}?
      return nil if artifact_id <= 0

      begin
        open do |db|
          db.exec("BEGIN IMMEDIATE")

          count = db.scalar(
            <<-SQL,
              SELECT COUNT(*)
              FROM artifact_annotations
              WHERE artifact_id = ?
                AND artifact_review_id IS NULL
            SQL
            artifact_id,
          ).as(Int64).to_i

          if count == 0
            db.exec("ROLLBACK")
            return nil
          end

          # Create the review with auto-assigned number
          db.exec(
            <<-SQL,
              INSERT INTO artifact_reviews (
                artifact_id, number
              )
              VALUES (
                ?,
                (SELECT COALESCE(MAX(number), 0) + 1
                 FROM artifact_reviews
                 WHERE artifact_id = ?)
              )
            SQL
            artifact_id,
            artifact_id,
          )

          review = db.query_one?(
            <<-SQL
              SELECT id, created_at, updated_at,
                     artifact_id, number, reviewed_at
              FROM artifact_reviews
              WHERE id = last_insert_rowid()
            SQL
          ) do |rs|
            ArtifactReview.from_row(rs)
          end

          unless review
            db.exec("ROLLBACK")
            return nil
          end

          # Assign all unreviewed annotations to this review
          db.exec(
            <<-SQL,
              UPDATE artifact_annotations
              SET artifact_review_id = ?,
                  updated_at = datetime('now')
              WHERE artifact_id = ?
                AND artifact_review_id IS NULL
            SQL
            review.id,
            artifact_id,
          )

          db.exec("COMMIT")
          {review, count.to_i}
        end
      rescue
        nil
      end
    end

    # List reviews for an artifact. If pending_only is true,
    # only returns reviews where reviewed_at IS NULL.
    def self.list_reviews(
      artifact_id : Int64,
      pending_only : Bool = false,
    ) : Array(ArtifactReview)
      reviews = [] of ArtifactReview
      return reviews if artifact_id <= 0

      begin
        open do |db|
          where_clause = "WHERE artifact_id = ?"
          if pending_only
            where_clause += " AND reviewed_at IS NULL"
          end

          db.query(
            <<-SQL,
              SELECT id, created_at, updated_at,
                     artifact_id, number, reviewed_at
              FROM artifact_reviews
              #{where_clause}
              ORDER BY number ASC
            SQL
            artifact_id,
          ) do |rs|
            rs.each do
              reviews << ArtifactReview.from_row(rs)
            end
          end
        end
      rescue
        # Return empty on error
      end
      reviews
    end

    # Get a review by artifact ID + number.
    def self.get_review(
      artifact_id : Int64,
      number : Int32,
    ) : ArtifactReview?
      return nil if artifact_id <= 0

      begin
        open do |db|
          db.query_one?(
            <<-SQL,
              SELECT id, created_at, updated_at,
                     artifact_id, number, reviewed_at
              FROM artifact_reviews
              WHERE artifact_id = ? AND number = ?
            SQL
            artifact_id,
            number,
          ) do |rs|
            ArtifactReview.from_row(rs)
          end
        end
      rescue
        nil
      end
    end

    # Mark a review as reviewed. Idempotent — calling again
    # updates the timestamp. Returns updated review or nil.
    def self.mark_review_reviewed(
      artifact_id : Int64,
      number : Int32,
    ) : ArtifactReview?
      return nil if artifact_id <= 0

      begin
        open do |db|
          result = db.exec(
            <<-SQL,
              UPDATE artifact_reviews
              SET reviewed_at = datetime('now'),
                  updated_at = datetime('now')
              WHERE artifact_id = ? AND number = ?
            SQL
            artifact_id,
            number,
          )
          return nil if result.rows_affected == 0

          db.query_one?(
            <<-SQL,
              SELECT id, created_at, updated_at,
                     artifact_id, number, reviewed_at
              FROM artifact_reviews
              WHERE artifact_id = ? AND number = ?
            SQL
            artifact_id,
            number,
          ) do |rs|
            ArtifactReview.from_row(rs)
          end
        end
      rescue
        nil
      end
    end

    # List annotations assigned to a specific review.
    def self.list_annotations_for_review(
      review_id : Int64,
    ) : Array(ArtifactAnnotation)
      annotations = [] of ArtifactAnnotation
      return annotations if review_id <= 0

      begin
        open do |db|
          db.query(
            <<-SQL,
              SELECT a.id, a.created_at, a.updated_at,
                     a.artifact_id, a.number, a.content,
                     a.anchor_data, a.content_hash, a.stale,
                     a.artifact_review_id,
                     r.number AS review_number,
                     r.reviewed_at AS review_reviewed_at
              FROM artifact_annotations a
              LEFT JOIN artifact_reviews r
                ON a.artifact_review_id = r.id
              WHERE a.artifact_review_id = ?
              ORDER BY a.number ASC
            SQL
            review_id,
          ) do |rs|
            rs.each do
              annotations << ArtifactAnnotation.from_row(rs)
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
    # Layout: backup_dir/YYYY-MM-DD/artifacts_SESSION_ID.db
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

      backup_file = date_dir / "artifacts_#{session_id}.db"

      # Remove stale backup file if it exists so VACUUM INTO can overwrite.
      File.delete(backup_file) if File.exists?(backup_file)

      open do |db|
        db.exec("VACUUM INTO '#{backup_file}'")
      end

      backup_file
    rescue ex
      STDERR.puts "[galaxy-artifacts] Backup failed: #{ex.message}"
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
      STDERR.puts "[galaxy-artifacts] Prune failed: #{ex.message}"
      0
    end

    # ============================================================
    # Data Structs
    # ============================================================

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
        @id, @ledger_session_id, @number, @created_at,
        @updated_at, @title, @artifact_type, @mime_type,
        @original_filename, @stored_path, @source_path,
        @file_size, @content_hash, @description, @metadata,
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

    enum SaveArtifactAction
      Insert
      Enrichment
      VersionUpdate
      Failed
    end

    struct SaveArtifactResult
      getter action : SaveArtifactAction
      getter number : Int32
      getter previous_content_hash : String?
      getter previous_file_size : Int64?

      def initialize(
        @action,
        @number,
        @previous_content_hash = nil,
        @previous_file_size = nil,
      )
      end
    end

    # An artifact annotation record from the database
    struct ArtifactAnnotation
      getter id : Int64
      getter created_at : String
      getter updated_at : String
      getter artifact_id : Int64
      getter number : Int32
      getter content : String
      getter anchor_data : String
      getter content_hash : String
      getter stale : Bool
      getter artifact_review_id : Int64?
      getter review_number : Int32?
      getter review_reviewed_at : String?

      def initialize(
        @id, @created_at, @updated_at,
        @artifact_id, @number, @content,
        @anchor_data, @content_hash, @stale,
        @artifact_review_id, @review_number,
        @review_reviewed_at,
      )
      end

      def self.from_row(rs) : ArtifactAnnotation
        ArtifactAnnotation.new(
          id: rs.read(Int64),
          created_at: rs.read(String),
          updated_at: rs.read(String),
          artifact_id: rs.read(Int64),
          number: rs.read(Int64).to_i,
          content: rs.read(String),
          anchor_data: rs.read(String),
          content_hash: rs.read(String),
          stale: rs.read(Int64) != 0,
          artifact_review_id: rs.read(Int64?),
          review_number: rs.read(Int64?).try(&.to_i),
          review_reviewed_at: rs.read(String?),
        )
      end
    end

    # An artifact review record from the database
    struct ArtifactReview
      getter id : Int64
      getter created_at : String
      getter updated_at : String
      getter artifact_id : Int64
      getter number : Int32
      getter reviewed_at : String?

      def initialize(
        @id, @created_at, @updated_at,
        @artifact_id, @number, @reviewed_at,
      )
      end

      def self.from_row(rs) : ArtifactReview
        ArtifactReview.new(
          id: rs.read(Int64),
          created_at: rs.read(String),
          updated_at: rs.read(String),
          artifact_id: rs.read(Int64),
          number: rs.read(Int64).to_i,
          reviewed_at: rs.read(String?),
        )
      end
    end
  end
end
