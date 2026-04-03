require "./galaxy_ledger/*"

module GalaxyLedger
  # Version is read from version.txt at compile time
  # This version is used for:
  # - CLI --version output
  # - Database and config schema versioning (see migrations.cr)
  VERSION = {{ read_file("#{__DIR__}/../version.txt").strip }}

  # Claude config directory (can be overridden for testing)
  # This is the base directory where Claude Code stores its configuration
  # Default: ~/.claude
  CLAUDE_CONFIG_DIR = Path.new(
    ENV.fetch(
      "GALAXY_CLAUDE_CONFIG_DIR",
      (Path.home / ".claude").to_s
    )
  )

  # Claude Code settings file (hooks are installed here)
  SETTINGS_FILE = CLAUDE_CONFIG_DIR / "settings.json"

  # Galaxy-level directories (shared between tools)
  # Can also be overridden directly for testing
  GALAXY_DIR = Path.new(
    ENV.fetch(
      "GALAXY_DIR",
      (CLAUDE_CONFIG_DIR / "galaxy").to_s
    )
  )

  # Data directory for databases (shared between tools)
  DATA_DIR = GALAXY_DIR / "data"

  # Ledger-specific directories
  CONFIG_DIR = Path.new(
    ENV.fetch(
      "GALAXY_LEDGER_CONFIG_DIR",
      (GALAXY_DIR / "ledger").to_s
    )
  )
  CONFIG_FILE = CONFIG_DIR / "config.json"

  # Skills directories
  SKILLS_DIR        = GALAXY_DIR / "ledger" / "skills"
  CLAUDE_SKILLS_DIR = CLAUDE_CONFIG_DIR / "skills"
  TIMELINE_BIN      = Path.new(
    ENV.fetch(
      "GALAXY_TIMELINE_BIN",
      (GALAXY_DIR / "bin" / "galaxy-timeline").to_s
    )
  )
  AGENTS_BIN = Path.new(
    ENV.fetch(
      "GALAXY_AGENTS_BIN",
      (GALAXY_DIR / "bin" / "galaxy-agents").to_s
    )
  )
  SNAPSHOTS_BIN = Path.new(
    ENV.fetch(
      "GALAXY_SNAPSHOTS_BIN",
      (GALAXY_DIR / "bin" / "galaxy-snapshots").to_s
    )
  )
  ARTIFACTS_BIN = Path.new(
    ENV.fetch(
      "GALAXY_ARTIFACTS_BIN",
      (GALAXY_DIR / "bin" / "galaxy-artifacts").to_s
    )
  )
end

# Only run CLI when executed directly, not when required by specs
unless ENV.has_key?("GALAXY_LEDGER_SKIP_CLI")
  GalaxyLedger::CLI.run(ARGV)
end
