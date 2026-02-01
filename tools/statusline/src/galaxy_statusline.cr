require "./galaxy_statusline/*"

module GalaxyStatusline
  VERSION = "0.1.0"

  # Allow override via environment variable for testing
  CONFIG_DIR = Path.new(
    ENV.fetch(
      "GALAXY_STATUSLINE_CONFIG_DIR",
      (Path.home / ".claude" / "galaxy" / "statusline").to_s
    )
  )
  CONFIG_FILE = CONFIG_DIR / "config.json"
end

# Only run CLI when executed directly, not when required by specs
unless ENV.has_key?("GALAXY_STATUSLINE_SKIP_CLI")
  GalaxyStatusline::CLI.run(ARGV)
end
