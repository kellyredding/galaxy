# Galaxy Ledger Migration System
#
# This module handles schema versioning and migrations for both the SQLite database
# and the config.json file. All schema versions are tied to the CLI version from version.txt.
#
# ## How Versioning Works
#
# - The CLI version (e.g., "0.1.0") from version.txt is the schema version
# - The database stores its version in a `schema_info` table
# - The config stores its version in a `_schema_version` field
# - On access, if stored version < CLI version, migrations run
# - Fresh installs create the latest schema directly and stamp with current version
#
# ## How to Add a Migration
#
# When you need to change the database or config schema:
#
# 1. Update version.txt with the new version number (e.g., "0.2.0")
#
# 2. For DATABASE changes, add an entry to DATABASE_MIGRATIONS:
#
#    ```
# DATABASE_MIGRATIONS = {
#   "0.2.0" => ->(db : DB::Database) {
#     # Add your migration SQL here
#     # This runs when upgrading TO version 0.2.0
#     db.exec("ALTER TABLE ledger_entries ADD COLUMN new_field TEXT")
#   },
# }
#    ```
#
# 3. For CONFIG changes, add an entry to CONFIG_MIGRATIONS:
#
#    ```
#    CONFIG_MIGRATIONS = {
#      "0.2.0" => ->(config_json : JSON::Any) -> JSON::Any {
#        # Transform the config JSON and return the new version
#        # This runs when upgrading TO version 0.2.0
#        obj = config_json.as_h.dup
#        obj["new_section"] = JSON::Any.new({"enabled" => JSON::Any.new(true)})
#        JSON::Any.new(obj)
#      },
#    }
#    ```
#
# 4. Also update the default schema creation code (in database.cr's create_schema
#    or config.cr's default method) so fresh installs get the new schema directly.
#
# ## Migration Order
#
# Migrations are run in semver order. If upgrading from 0.0.1 to 0.2.0:
# - First runs 0.1.0 migration (if exists)
# - Then runs 0.2.0 migration (if exists)
#
# ## Important Notes
#
# - Migrations must be idempotent where possible (use IF NOT EXISTS, etc.)
# - Database migrations receive a DB::Database connection
# - Config migrations receive JSON::Any and must return transformed JSON::Any
# - Never remove old migrations - they may be needed for users upgrading from old versions
#

require "db"
require "json"

module GalaxyLedger
  module Migrations
    # ==========================================================================
    # DATABASE MIGRATIONS
    # ==========================================================================
    #
    # Add database schema migrations here, keyed by the version they upgrade TO.
    # Each migration receives a DB::Database connection.
    #
    # Example:
    #   "0.2.0" => ->(db : DB::Database) {
    #     db.exec("ALTER TABLE ledger_entries ADD COLUMN new_field TEXT")
    #   },
    #
    DATABASE_MIGRATIONS = {
      "0.2.0" => ->(db : DB::Database) {
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
        db.exec("CREATE INDEX IF NOT EXISTS idx_snapshots_session ON ledger_snapshots(ledger_session_id)")
      },
      "0.3.2" => ->(db : DB::Database) {
        db.exec("ALTER TABLE ledger_session_daily_usages ADD COLUMN oneshot_cost_usd REAL NOT NULL DEFAULT 0.0")
        db.exec("ALTER TABLE ledger_session_daily_usages ADD COLUMN oneshot_tokens INTEGER NOT NULL DEFAULT 0")
      },
      "0.3.3" => ->(db : DB::Database) {
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
        db.exec("CREATE INDEX IF NOT EXISTS idx_artifacts_session ON ledger_artifacts(ledger_session_id)")
      },
      "0.3.4" => ->(db : DB::Database) {
        # Clean up pre-existing duplicate (session_id, source_path) pairs before
        # creating the unique index. Keep the row with the highest number (latest).
        db.exec(<<-SQL)
          DELETE FROM ledger_artifacts
          WHERE id NOT IN (
            SELECT MAX(id)
            FROM ledger_artifacts
            WHERE source_path IS NOT NULL
            GROUP BY ledger_session_id, source_path
          )
          AND source_path IS NOT NULL
        SQL
        db.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_artifacts_source_path ON ledger_artifacts(ledger_session_id, source_path) WHERE source_path IS NOT NULL")
      },
      "0.3.5" => ->(db : DB::Database) {
        db.exec("ALTER TABLE ledger_sessions RENAME COLUMN title TO suggested_name")
        db.exec("ALTER TABLE ledger_sessions ADD COLUMN suggested_name_data TEXT NOT NULL DEFAULT '{}'")
      },
      "0.3.6" => ->(db : DB::Database) {
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
        db.exec("CREATE INDEX IF NOT EXISTS idx_snapshot_annotations_snapshot ON ledger_snapshot_annotations(ledger_snapshot_id)")
      },
      "0.3.7" => ->(db : DB::Database) {
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
        db.exec("CREATE INDEX IF NOT EXISTS idx_snapshot_reviews_snapshot ON ledger_snapshot_reviews(ledger_snapshot_id)")
        begin
          db.exec(<<-SQL)
            ALTER TABLE ledger_snapshot_annotations
              ADD COLUMN ledger_snapshot_review_id INTEGER
              REFERENCES ledger_snapshot_reviews(id) ON DELETE SET NULL
          SQL
        rescue
          # Column already exists — ignore
        end
      },
      "0.3.9" => ->(db : DB::Database) {
        begin
          db.exec(
            "ALTER TABLE ledger_session_files " \
            "ADD COLUMN file_type TEXT NOT NULL DEFAULT 'other'"
          )
        rescue
          # Column already exists or table doesn't exist — ignore
        end

        # Backfill: classify existing files with path-based detection
        begin
          rows = [] of {Int64, String}
          db.query(
            "SELECT id, file_path FROM ledger_session_files"
          ) do |rs|
            rs.each do
              rows << {rs.read(Int64), rs.read(String)}
            end
          end

          rows.each do |id, file_path|
            detected_type = FileTypeDetector.detect(file_path)
            next if detected_type == "other" # Already the default

            db.exec(
              "UPDATE ledger_session_files SET file_type = ? WHERE id = ?",
              detected_type,
              id,
            )
          end
        rescue
          # Table doesn't exist yet (partial DB in migration tests) — skip
        end
      },
      "0.4.1" => ->(db : DB::Database) {
        # Migrate snapshots to standalone galaxy-snapshots tool.
        #
        # Belt-and-suspenders: if tables are already gone, short-circuit.
        table_exists = false
        table_check_sql = "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'ledger_snapshots'"
        db.query_one?(table_check_sql) do |rs|
          table_exists = rs.read(Int64) > 0
        end

        if table_exists
          snapshots_bin = (
            GalaxyLedger::GALAXY_DIR / "bin" / "galaxy-snapshots"
          ).to_s

          skip_migration = false

          # Check that the snapshots binary exists
          unless File.exists?(snapshots_bin)
            STDERR.puts(
              "[galaxy-ledger] Warning: galaxy-snapshots binary not " \
              "found at #{snapshots_bin}. Skipping snapshot migration. " \
              "Install galaxy-snapshots and re-run ledger to retry.",
            )
            skip_migration = true
          end

          unless skip_migration
            # Collect sessions that have snapshots
            session_ids = [] of Int64
            db.query(
              "SELECT DISTINCT ledger_session_id FROM ledger_snapshots",
            ) do |rs|
              rs.each { session_ids << rs.read(Int64) }
            end

            if session_ids.empty?
              # No snapshots to migrate — drop tables and move on
              db.exec("DROP TABLE IF EXISTS ledger_snapshot_annotations")
              db.exec("DROP TABLE IF EXISTS ledger_snapshot_reviews")
              db.exec("DROP TABLE IF EXISTS ledger_snapshots")
              db.exec("DROP INDEX IF EXISTS idx_snapshots_session")
              db.exec(
                "DROP INDEX IF EXISTS idx_snapshot_annotations_snapshot",
              )
              db.exec("DROP INDEX IF EXISTS idx_snapshot_reviews_snapshot")
            else
              migration_ok = true

              session_ids.each do |sid|
                # Export snapshots in number order (trust sequential insertion)
                db.query(
                  <<-SQL,
                    SELECT number, title, content, exchange_count
                    FROM ledger_snapshots
                    WHERE ledger_session_id = ?
                    ORDER BY number ASC
                  SQL
                  sid,
                ) do |rs|
                  rs.each do
                    number = rs.read(Int64).to_i
                    title = rs.read(String)
                    content = rs.read(String)
                    exchange_count = rs.read(Int64).to_i

                    # Create snapshot via CLI
                    output = IO::Memory.new
                    error = IO::Memory.new
                    status = Process.run(
                      snapshots_bin,
                      args: [
                        "create",
                        "--ledger-session-id", sid.to_s,
                        "--title", title,
                        "--exchanges", exchange_count.to_s,
                      ],
                      input: IO::Memory.new(content),
                      output: output,
                      error: error,
                    )

                    unless status.success?
                      STDERR.puts(
                        "[galaxy-ledger] Failed to migrate snapshot " \
                        "##{number} for session #{sid}: " \
                        "#{error.to_s.strip}",
                      )
                      migration_ok = false
                      break
                    end
                  end
                end

                break unless migration_ok

                # Export annotations for each snapshot in this session
                db.query(
                  <<-SQL,
                    SELECT ls.number AS snap_number,
                           la.start_line, la.end_line, la.content,
                           ls.id AS ledger_snapshot_id
                    FROM ledger_snapshot_annotations la
                    JOIN ledger_snapshots ls ON la.ledger_snapshot_id = ls.id
                    WHERE ls.ledger_session_id = ?
                    ORDER BY ls.number ASC, la.number ASC
                  SQL
                  sid,
                ) do |rs|
                  rs.each do
                    snap_number = rs.read(Int64).to_i
                    start_line = rs.read(Int64).to_i
                    end_line = rs.read(Int64).to_i
                    ann_content = rs.read(String)
                    _ledger_snapshot_id = rs.read(Int64)

                    # Resolve the snapshot ID in the new snapshots.db
                    # by querying for it via the snapshots CLI
                    snap_id_output = IO::Memory.new
                    snap_id_status = Process.run(
                      snapshots_bin,
                      args: [
                        "view",
                        "--ledger-session-id", sid.to_s,
                        "--json",
                        snap_number.to_s,
                      ],
                      output: snap_id_output,
                      error: Process::Redirect::Close,
                    )

                    unless snap_id_status.success?
                      STDERR.puts(
                        "[galaxy-ledger] Failed to resolve snapshot " \
                        "##{snap_number} for annotation migration " \
                        "(session #{sid})",
                      )
                      migration_ok = false
                      break
                    end

                    snap_json = JSON.parse(snap_id_output.to_s)
                    new_snapshot_id = snap_json["snapshot"]["id"].as_i64

                    # Create annotation via CLI
                    ann_output = IO::Memory.new
                    ann_error = IO::Memory.new
                    ann_status = Process.run(
                      snapshots_bin,
                      args: [
                        "annotation", "create",
                        "--snapshot-id", new_snapshot_id.to_s,
                        "--start-line", start_line.to_s,
                        "--end-line", end_line.to_s,
                      ],
                      input: IO::Memory.new(ann_content),
                      output: ann_output,
                      error: ann_error,
                    )

                    unless ann_status.success?
                      STDERR.puts(
                        "[galaxy-ledger] Failed to migrate annotation " \
                        "for snapshot ##{snap_number} (session #{sid}): " \
                        "#{ann_error.to_s.strip}",
                      )
                      migration_ok = false
                      break
                    end
                  end
                end

                break unless migration_ok

                # Export reviews for each snapshot in this session
                db.query(
                  <<-SQL,
                    SELECT ls.number AS snap_number, ls.id AS ledger_snapshot_id
                    FROM ledger_snapshot_reviews sr
                    JOIN ledger_snapshots ls ON sr.ledger_snapshot_id = ls.id
                    WHERE ls.ledger_session_id = ?
                    ORDER BY ls.number ASC, sr.number ASC
                  SQL
                  sid,
                ) do |rs|
                  rs.each do
                    snap_number = rs.read(Int64).to_i
                    _ledger_snapshot_id = rs.read(Int64)

                    # Resolve snapshot ID in new DB
                    snap_id_output = IO::Memory.new
                    Process.run(
                      snapshots_bin,
                      args: [
                        "view",
                        "--ledger-session-id", sid.to_s,
                        "--json",
                        snap_number.to_s,
                      ],
                      output: snap_id_output,
                      error: Process::Redirect::Close,
                    )

                    snap_json = JSON.parse(snap_id_output.to_s)
                    new_snapshot_id = snap_json["snapshot"]["id"].as_i64

                    # Create review via CLI
                    rev_error = IO::Memory.new
                    rev_status = Process.run(
                      snapshots_bin,
                      args: [
                        "review", "create",
                        "--snapshot-id", new_snapshot_id.to_s,
                      ],
                      output: Process::Redirect::Close,
                      error: rev_error,
                    )

                    unless rev_status.success?
                      STDERR.puts(
                        "[galaxy-ledger] Failed to migrate review " \
                        "for snapshot ##{snap_number} (session #{sid}): " \
                        "#{rev_error.to_s.strip}",
                      )
                      # Reviews are non-critical — log but continue
                    end
                  end
                end
              end

              # Verify migration
              if migration_ok
                session_ids.each do |sid|
                  # Count snapshots in ledger
                  ledger_count = 0
                  count_sql = "SELECT COUNT(*) FROM ledger_snapshots WHERE ledger_session_id = ?"
                  db.query_one?(count_sql, sid) do |rs|
                    ledger_count = rs.read(Int64).to_i
                  end

                  # Count snapshots in new tool
                  stats_output = IO::Memory.new
                  stats_status = Process.run(
                    snapshots_bin,
                    args: [
                      "stats",
                      "--ledger-session-id", sid.to_s,
                      "--json",
                    ],
                    output: stats_output,
                    error: Process::Redirect::Close,
                  )

                  if stats_status.success?
                    stats_json = JSON.parse(stats_output.to_s)
                    new_count = stats_json["count"].as_i

                    if new_count != ledger_count
                      STDERR.puts(
                        "[galaxy-ledger] Snapshot count mismatch for " \
                        "session #{sid}: ledger=#{ledger_count} " \
                        "snapshots=#{new_count}. Keeping ledger tables.",
                      )
                      migration_ok = false
                      break
                    end
                  else
                    STDERR.puts(
                      "[galaxy-ledger] Failed to verify migration for " \
                      "session #{sid}. Keeping ledger tables.",
                    )
                    migration_ok = false
                    break
                  end
                end
              end

              if migration_ok
                # Drop tables (order matters for FK constraints)
                db.exec("DROP TABLE IF EXISTS ledger_snapshot_annotations")
                db.exec("DROP TABLE IF EXISTS ledger_snapshot_reviews")
                db.exec("DROP TABLE IF EXISTS ledger_snapshots")
                db.exec("DROP INDEX IF EXISTS idx_snapshots_session")
                db.exec(
                  "DROP INDEX IF EXISTS idx_snapshot_annotations_snapshot",
                )
                db.exec("DROP INDEX IF EXISTS idx_snapshot_reviews_snapshot")
              else
                STDERR.puts(
                  "[galaxy-ledger] Snapshot migration incomplete. " \
                  "Tables preserved. Will retry on next startup.",
                )
                # Don't drop tables — migration will retry next time
                # because version is set but tables still exist
              end
            end
          end
        end
      },
      "0.5.0" => ->(db : DB::Database) {
        # Migrate artifacts to standalone galaxy-artifacts tool.
        #
        # Belt-and-suspenders: if table is already gone, short-circuit.
        table_exists = false
        table_check_sql = "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'ledger_artifacts'"
        db.query_one?(table_check_sql) do |rs|
          table_exists = rs.read(Int64) > 0
        end

        if table_exists
          artifacts_bin = (
            GalaxyLedger::GALAXY_DIR / "bin" / "galaxy-artifacts"
          ).to_s

          skip_migration = false

          # Check that the artifacts binary exists
          unless File.exists?(artifacts_bin)
            STDERR.puts(
              "[galaxy-ledger] Warning: galaxy-artifacts binary not " \
              "found at #{artifacts_bin}. Skipping artifact migration. " \
              "Install galaxy-artifacts and re-run ledger to retry.",
            )
            skip_migration = true
          end

          unless skip_migration
            # Collect sessions that have artifacts
            session_ids = [] of Int64
            db.query(
              "SELECT DISTINCT ledger_session_id FROM ledger_artifacts",
            ) do |rs|
              rs.each { session_ids << rs.read(Int64) }
            end

            if session_ids.empty?
              # No artifacts to migrate — drop table and move on
              db.exec("DROP TABLE IF EXISTS ledger_artifacts")
              db.exec("DROP INDEX IF EXISTS idx_artifacts_session")
              db.exec("DROP INDEX IF EXISTS idx_artifacts_source_path")
            else
              migration_ok = true

              session_ids.each do |sid|
                # Export artifacts in number order
                artifact_query = "SELECT number, title, artifact_type, mime_type, original_filename, stored_path, source_path, file_size, content_hash, description FROM ledger_artifacts WHERE ledger_session_id = ? ORDER BY number ASC"
                db.query(artifact_query, sid) do |rs|
                  rs.each do
                    number = rs.read(Int64).to_i
                    title = rs.read(String)
                    artifact_type = rs.read(String)
                    mime_type = rs.read(String)
                    original_filename = rs.read(String)
                    stored_path = rs.read(String)
                    source_path = rs.read(String?)
                    file_size = rs.read(Int64)
                    content_hash = rs.read(String)
                    description = rs.read(String?)

                    cli_args = [
                      "save",
                      "--ledger-session-id", sid.to_s,
                      "--source-path", stored_path,
                      "--title", title,
                      "--artifact-type", artifact_type,
                      "--mime-type", mime_type,
                      "--content-hash", content_hash,
                      "--file-size", file_size.to_s,
                    ]

                    if desc = description
                      cli_args << "--description"
                      cli_args << desc
                    end

                    output = IO::Memory.new
                    error = IO::Memory.new
                    status = Process.run(
                      artifacts_bin,
                      args: cli_args,
                      output: output,
                      error: error,
                    )

                    unless status.success?
                      STDERR.puts(
                        "[galaxy-ledger] Failed to migrate artifact " \
                        "##{number} for session #{sid}: " \
                        "#{error.to_s.strip}",
                      )
                      migration_ok = false
                      break
                    end
                  end
                end

                break unless migration_ok
              end

              # Verify migration
              if migration_ok
                session_ids.each do |sid|
                  ledger_count = 0
                  count_sql = "SELECT COUNT(*) FROM ledger_artifacts WHERE ledger_session_id = ?"
                  db.query_one?(count_sql, sid) do |rs|
                    ledger_count = rs.read(Int64).to_i
                  end

                  stats_output = IO::Memory.new
                  stats_status = Process.run(
                    artifacts_bin,
                    args: [
                      "stats",
                      "--ledger-session-id", sid.to_s,
                      "--json",
                    ],
                    output: stats_output,
                    error: Process::Redirect::Close,
                  )

                  if stats_status.success?
                    stats_json = JSON.parse(stats_output.to_s)
                    new_count = stats_json["count"].as_i

                    if new_count != ledger_count
                      STDERR.puts(
                        "[galaxy-ledger] Artifact count mismatch for " \
                        "session #{sid}: ledger=#{ledger_count} " \
                        "artifacts=#{new_count}. Keeping ledger table.",
                      )
                      migration_ok = false
                      break
                    end
                  else
                    STDERR.puts(
                      "[galaxy-ledger] Failed to verify migration for " \
                      "session #{sid}. Keeping ledger table.",
                    )
                    migration_ok = false
                    break
                  end
                end
              end

              if migration_ok
                db.exec("DROP TABLE IF EXISTS ledger_artifacts")
                db.exec("DROP INDEX IF EXISTS idx_artifacts_session")
                db.exec("DROP INDEX IF EXISTS idx_artifacts_source_path")
              else
                STDERR.puts(
                  "[galaxy-ledger] Artifact migration incomplete. " \
                  "Table preserved. Will retry on next startup.",
                )
              end
            end
          end
        end
      },
      "0.5.1" => ->(db : DB::Database) {
        # Drop the vestigial last_interaction column.
        # No code reads or writes it since 0.5.0 removed the
        # exchange/summary pipeline.
        begin
          db.exec(
            "ALTER TABLE ledger_sessions " \
            "DROP COLUMN last_interaction"
          )
        rescue
          # Column already gone — ignore
        end
      },
    }

    # ==========================================================================
    # CONFIG MIGRATIONS
    # ==========================================================================
    #
    # Add config.json schema migrations here, keyed by the version they upgrade TO.
    # Each migration receives JSON::Any and must return the transformed JSON::Any.
    #
    # Example:
    #   "0.2.0" => ->(config_json : JSON::Any) -> JSON::Any {
    #     obj = config_json.as_h.dup
    #     obj["new_setting"] = JSON::Any.new("default_value")
    #     JSON::Any.new(obj)
    #   },
    #
    CONFIG_MIGRATIONS = {
      "0.3.1" => Proc(JSON::Any, JSON::Any).new { |config_json|
        obj = config_json.as_h.dup
        unless obj.has_key?("backups")
          obj["backups"] = JSON::Any.new({
            "enabled"        => JSON::Any.new(true),
            "retention_days" => JSON::Any.new(3_i64),
            "path"           => JSON::Any.new(""),
          })
        end
        JSON::Any.new(obj)
      },
      "0.3.3" => Proc(JSON::Any, JSON::Any).new { |config_json|
        obj = config_json.as_h.dup
        unless obj.has_key?("artifacts")
          obj["artifacts"] = JSON::Any.new({
            "enabled"       => JSON::Any.new(true),
            "auto_detect"   => JSON::Any.new(true),
            "max_file_size" => JSON::Any.new(52_428_800_i64),
          })
        end
        JSON::Any.new(obj)
      },
      "0.3.5" => Proc(JSON::Any, JSON::Any).new { |config_json|
        obj = config_json.as_h.dup
        unless obj.has_key?("suggested_name")
          obj["suggested_name"] = JSON::Any.new({
            "enabled" => JSON::Any.new(true),
          })
        end
        JSON::Any.new(obj)
      },
      "0.4.1" => Proc(JSON::Any, JSON::Any).new { |config_json|
        obj = config_json.as_h.dup

        # Copy snapshot config to snapshots tool's config file
        if snapshots_config = obj["snapshots"]?.try(&.as_h?)
          snapshots_config_dir = GalaxyLedger::GALAXY_DIR / "snapshots"
          snapshots_config_file = snapshots_config_dir / "config.json"

          unless File.exists?(snapshots_config_file)
            Dir.mkdir_p(snapshots_config_dir)
            new_config = Hash(String, JSON::Any).new
            new_config["_schema_version"] = JSON::Any.new("0.1.0")
            new_config["inline_char_cap"] = snapshots_config["inline_char_cap"]? ||
                                            JSON::Any.new(15000_i64)
            new_config["max_per_session"] = snapshots_config["max_per_session"]? ||
                                            JSON::Any.new(10_i64)
            new_config["editor"] = snapshots_config["editor"]? ||
                                   JSON::Any.new("")
            new_config["backups"] = JSON::Any.new({
              "enabled"        => JSON::Any.new(true),
              "retention_days" => JSON::Any.new(3_i64),
              "path"           => JSON::Any.new(""),
            })
            File.write(
              snapshots_config_file,
              JSON::Any.new(new_config).to_pretty_json,
            )
          end
        end

        # Remove snapshots section from ledger config
        obj.delete("snapshots")
        JSON::Any.new(obj)
      },
      "0.5.0" => Proc(JSON::Any, JSON::Any).new { |config_json|
        obj = config_json.as_h.dup

        # Copy artifact config to artifacts tool's config file
        if artifacts_config = obj["artifacts"]?.try(&.as_h?)
          artifacts_config_dir = GalaxyLedger::GALAXY_DIR / "artifacts"
          artifacts_config_file = artifacts_config_dir / "config.json"

          unless File.exists?(artifacts_config_file)
            Dir.mkdir_p(artifacts_config_dir)
            new_config = Hash(String, JSON::Any).new
            new_config["_schema_version"] = JSON::Any.new("0.1.0")
            new_config["enabled"] = artifacts_config["enabled"]? ||
                                    JSON::Any.new(true)
            new_config["auto_detect"] = artifacts_config["auto_detect"]? ||
                                        JSON::Any.new(true)
            new_config["max_file_size"] = artifacts_config["max_file_size"]? ||
                                          JSON::Any.new(52_428_800_i64)
            new_config["backups"] = JSON::Any.new({
              "enabled"        => JSON::Any.new(true),
              "retention_days" => JSON::Any.new(3_i64),
              "path"           => JSON::Any.new(""),
            })
            File.write(
              artifacts_config_file,
              JSON::Any.new(new_config).to_pretty_json,
            )
          end
        end

        # Remove artifacts section from ledger config
        obj.delete("artifacts")
        JSON::Any.new(obj)
      },
    }

    # ==========================================================================
    # VERSION UTILITIES
    # ==========================================================================

    # Parse a semver string into comparable tuple
    # "1.2.3" => {1, 2, 3}
    def self.parse_version(version : String) : Tuple(Int32, Int32, Int32)
      parts = version.split(".")
      major = parts[0]?.try(&.to_i?) || 0
      minor = parts[1]?.try(&.to_i?) || 0
      patch = parts[2]?.try(&.to_i?) || 0
      {major, minor, patch}
    end

    # Compare two version strings
    # Returns -1 if a < b, 0 if a == b, 1 if a > b
    def self.compare_versions(a : String, b : String) : Int32
      va = parse_version(a)
      vb = parse_version(b)
      va <=> vb
    end

    # Check if version a is less than version b
    def self.version_less_than?(a : String, b : String) : Bool
      compare_versions(a, b) < 0
    end

    # Check if version a is greater than version b
    def self.version_greater_than?(a : String, b : String) : Bool
      compare_versions(a, b) > 0
    end

    # Get migration versions between from_version and to_version (exclusive of from, inclusive of to)
    # Returns versions sorted in ascending order
    def self.migrations_between(
      migrations : Hash(String, T),
      from_version : String,
      to_version : String,
    ) : Array(String) forall T
      migrations.keys.select do |v|
        version_greater_than?(v, from_version) && !version_greater_than?(v, to_version)
      end.sort { |a, b| compare_versions(a, b) }
    end

    # ==========================================================================
    # DATABASE MIGRATION
    # ==========================================================================

    # Migrate database schema if needed
    # Called from Database.open after connection is established
    def self.migrate_database(db : DB::Database)
      ensure_schema_info_table(db)

      stored_version = get_database_version(db)
      current_version = GalaxyLedger::VERSION

      # If no version stored, this is either:
      # - A fresh install (version will be set after schema creation)
      # - An existing database from before versioning (treat as 0.0.1)
      if stored_version.nil?
        # Existing database without version tracking - stamp as 0.0.1
        # (the version when we introduced this system)
        set_database_version(db, "0.0.1")
        stored_version = "0.0.1"
      end

      # Check for downgrade
      if version_greater_than?(stored_version, current_version)
        STDERR.puts "[galaxy-ledger] Warning: Database schema version (#{stored_version}) is newer than CLI version (#{current_version})"
        return
      end

      # Run any needed migrations
      if version_less_than?(stored_version, current_version)
        versions_to_run = migrations_between(DATABASE_MIGRATIONS, stored_version, current_version)

        versions_to_run.each do |version|
          if migration = DATABASE_MIGRATIONS[version]?
            migration.call(db)
          end
        end

        # Update to current version
        set_database_version(db, current_version)
      end
    end

    # Ensure schema_info table exists
    private def self.ensure_schema_info_table(db : DB::Database)
      db.exec(<<-SQL)
        CREATE TABLE IF NOT EXISTS schema_info (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        )
      SQL
    end

    # Get the current database schema version
    def self.get_database_version(db : DB::Database) : String?
      result = db.query_one?(
        "SELECT value FROM schema_info WHERE key = 'version'",
        as: String
      )
      result
    end

    # Set the database schema version
    def self.set_database_version(db : DB::Database, version : String)
      db.exec(
        "INSERT OR REPLACE INTO schema_info (key, value) VALUES ('version', ?)",
        version
      )
    end

    # ==========================================================================
    # CONFIG MIGRATION
    # ==========================================================================

    # Migrate config JSON if needed
    # Returns the migrated JSON (may be unchanged)
    def self.migrate_config(config_json : JSON::Any) : {JSON::Any, Bool}
      stored_version = config_json["_schema_version"]?.try(&.as_s?) || "0.0.1"
      current_version = GalaxyLedger::VERSION
      changed = false

      # Check for downgrade
      if version_greater_than?(stored_version, current_version)
        STDERR.puts "[galaxy-ledger] Warning: Config schema version (#{stored_version}) is newer than CLI version (#{current_version})"
        return {config_json, false}
      end

      result = config_json

      # Run any needed migrations
      if version_less_than?(stored_version, current_version)
        versions_to_run = migrations_between(CONFIG_MIGRATIONS, stored_version, current_version)

        versions_to_run.each do |version|
          if migration = CONFIG_MIGRATIONS[version]?
            result = migration.call(result)
            changed = true
          end
        end

        # Update version in config
        obj = result.as_h.dup
        obj["_schema_version"] = JSON::Any.new(current_version)
        result = JSON::Any.new(obj)
        changed = true
      end

      {result, changed}
    end

    # Add schema version to config JSON if not present
    def self.ensure_config_version(config_json : JSON::Any) : JSON::Any
      if config_json["_schema_version"]?
        config_json
      else
        obj = config_json.as_h.dup
        obj["_schema_version"] = JSON::Any.new(GalaxyLedger::VERSION)
        JSON::Any.new(obj)
      end
    end
  end
end
