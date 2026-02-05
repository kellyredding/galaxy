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
#    ```crystal
#    DATABASE_MIGRATIONS = {
#      "0.2.0" => ->(db : DB::Database) {
#        # Add your migration SQL here
#        # This runs when upgrading TO version 0.2.0
#        db.exec("ALTER TABLE ledger_entries ADD COLUMN new_field TEXT")
#      },
#    }
#    ```
#
# 3. For CONFIG changes, add an entry to CONFIG_MIGRATIONS:
#
#    ```crystal
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
    DATABASE_MIGRATIONS = {} of String => Proc(DB::Database, Nil)

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
    CONFIG_MIGRATIONS = {} of String => Proc(JSON::Any, JSON::Any)

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
      to_version : String
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
