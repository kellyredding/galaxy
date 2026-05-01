require "./galaxy_statusline/*"

module GalaxyStatusline
  # Version is read from version.txt at compile time.
  # Source of truth is version.txt; bin/release also syncs shard.yml.
  VERSION = {{ read_file("#{__DIR__}/../version.txt").strip }}

  # Galaxy-level directory (shared between tools)
  GALAXY_DIR = Path.new(
    ENV.fetch(
      "GALAXY_DIR",
      (Path.home / ".claude" / "galaxy").to_s
    )
  )

  # Allow override via environment variable for testing
  CONFIG_DIR = Path.new(
    ENV.fetch(
      "GALAXY_STATUSLINE_CONFIG_DIR",
      (GALAXY_DIR / "statusline").to_s
    )
  )
  CONFIG_FILE = CONFIG_DIR / "config.json"
end

# Only run CLI when executed directly, not when required by specs
unless ENV.has_key?("GALAXY_STATUSLINE_SKIP_CLI")
  GalaxyStatusline::CLI.run(ARGV)
end
