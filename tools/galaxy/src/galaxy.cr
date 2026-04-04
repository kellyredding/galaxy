require "./galaxy/*"

module Galaxy
  VERSION = "0.0.1"

  # Galaxy-level directory (shared between tools)
  GALAXY_DIR = Path.new(
    ENV.fetch(
      "GALAXY_DIR",
      (Path.home / ".claude" / "galaxy").to_s
    )
  )

  # Shared Galaxy config file
  CONFIG_FILE = GALAXY_DIR / "config.json"

  # URL scheme for communicating with Galaxy.app
  URL_SCHEME = "galaxy"

  # Default Galaxy.app bundle identifier
  APP_BUNDLE_ID = "com.kellyredding.galaxy"

  # Claude Persona integration
  # Allow override via environment variable for testing (mirrors claude-persona's pattern)
  CLAUDE_PERSONA_DIR = Path.new(
    ENV.fetch("CLAUDE_PERSONA_DIR", (Path.home / ".claude-persona").to_s)
  )
  PERSONAS_DIR = CLAUDE_PERSONA_DIR / "personas"
end

# Only run CLI when executed directly, not when required by specs
unless ENV.has_key?("GALAXY_SKIP_CLI")
  Galaxy::CLI.run(ARGV)
end
