require "db"

module GalaxyAgents
  module Migrations
    # ========================================================
    # DATABASE MIGRATIONS
    # ========================================================
    #
    # Add database schema migrations here, keyed by the
    # version they upgrade TO. Each migration receives a
    # DB::Database connection.
    #
    # The initial schema is created in
    # Database.create_schema (called for fresh installs).
    # Migrations run for upgrades from older versions.
    #
    DATABASE_MIGRATIONS = {} of String => Proc(DB::Database, Nil)

    # ========================================================
    # VERSION UTILITIES
    # ========================================================

    # Parse a semver string into comparable tuple
    # "1.2.3" => {1, 2, 3}
    def self.parse_version(
      version : String,
    ) : Tuple(Int32, Int32, Int32)
      parts = version.split(".")
      major = parts[0]?.try(&.to_i?) || 0
      minor = parts[1]?.try(&.to_i?) || 0
      patch = parts[2]?.try(&.to_i?) || 0
      {major, minor, patch}
    end

    # Compare two version strings
    # Returns -1 if a < b, 0 if a == b, 1 if a > b
    def self.compare_versions(
      a : String, b : String,
    ) : Int32
      va = parse_version(a)
      vb = parse_version(b)
      va <=> vb
    end

    def self.version_less_than?(
      a : String, b : String,
    ) : Bool
      compare_versions(a, b) < 0
    end

    def self.version_greater_than?(
      a : String, b : String,
    ) : Bool
      compare_versions(a, b) > 0
    end

    def self.migrations_between(
      migrations : Hash(String, T),
      from_version : String,
      to_version : String,
    ) : Array(String) forall T
      migrations.keys.select do |v|
        version_greater_than?(v, from_version) &&
          !version_greater_than?(v, to_version)
      end.sort { |a, b| compare_versions(a, b) }
    end

    # ========================================================
    # DATABASE MIGRATION
    # ========================================================

    def self.migrate_database(db : DB::Database)
      ensure_schema_info_table(db)

      stored_version = get_database_version(db)
      current_version = GalaxyAgents::VERSION

      if stored_version.nil?
        set_database_version(db, "0.0.1")
        stored_version = "0.0.1"
      end

      if version_greater_than?(
           stored_version, current_version,
         )
        STDERR.puts(
          "[galaxy-agents] Warning: Database " \
          "schema version (#{stored_version}) is " \
          "newer than CLI version " \
          "(#{current_version})",
        )
        return
      end

      if version_less_than?(
           stored_version, current_version,
         )
        versions_to_run = migrations_between(
          DATABASE_MIGRATIONS,
          stored_version,
          current_version,
        )

        versions_to_run.each do |version|
          if migration = DATABASE_MIGRATIONS[version]?
            migration.call(db)
          end
        end

        set_database_version(db, current_version)
      end
    end

    private def self.ensure_schema_info_table(
      db : DB::Database,
    )
      db.exec(<<-SQL)
        CREATE TABLE IF NOT EXISTS schema_info (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        )
      SQL
    end

    def self.get_database_version(
      db : DB::Database,
    ) : String?
      db.query_one?(
        "SELECT value FROM schema_info " \
        "WHERE key = 'version'",
        as: String,
      )
    end

    def self.set_database_version(
      db : DB::Database, version : String,
    )
      db.exec(
        "INSERT OR REPLACE INTO schema_info " \
        "(key, value) VALUES ('version', ?)",
        version,
      )
    end
  end
end
