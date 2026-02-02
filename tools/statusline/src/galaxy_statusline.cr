require "./galaxy_statusline/*"

module GalaxyStatusline
  VERSION = "0.1.0"

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

  # Sessions directory for per-session state (shared between tools)
  SESSIONS_DIR = GALAXY_DIR / "sessions"

  # Context status filename (written to each session's folder)
  CONTEXT_STATUS_FILENAME = "context-status.json"
end

# Only run CLI when executed directly, not when required by specs
unless ENV.has_key?("GALAXY_STATUSLINE_SKIP_CLI")
  GalaxyStatusline::CLI.run(ARGV)
end
