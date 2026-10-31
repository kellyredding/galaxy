require "./galaxy/*"

module Galaxy
  VERSION = "0.1.0"

  # Galaxy-level directory (shared between tools)
  GALAXY_DIR = Path.new(
    ENV.fetch(
      "GALAXY_DIR",
      (Path.home / ".claude" / "galaxy").to_s
    )
  )

  # Shared Galaxy config file
  CONFIG_FILE = GALAXY_DIR / "config.json"

  # Sub-tool binary paths (env var overrides for testing)
  LEDGER_BIN = Path.new(
    ENV.fetch(
      "GALAXY_LEDGER_BIN",
      (GALAXY_DIR / "bin" / "galaxy-ledger").to_s,
    ),
  )
  ARTIFACTS_BIN = Path.new(
    ENV.fetch(
      "GALAXY_ARTIFACTS_BIN",
      (GALAXY_DIR / "bin" / "galaxy-artifacts").to_s,
    ),
  )
  TIMELINE_BIN = Path.new(
    ENV.fetch(
      "GALAXY_TIMELINE_BIN",
      (GALAXY_DIR / "bin" / "galaxy-timeline").to_s,
    ),
  )
  AGENTS_BIN = Path.new(
    ENV.fetch(
      "GALAXY_AGENTS_BIN",
      (GALAXY_DIR / "bin" / "galaxy-agents").to_s,
    ),
  )

  # All sub-tool binaries that support backup commands
  BACKUP_TOOLS = {
    {"ledger", LEDGER_BIN},
    {"artifacts", ARTIFACTS_BIN},
    {"timeline", TIMELINE_BIN},
    {"agents", AGENTS_BIN},
  }

  # Galaxy.app data directory
  APP_SUPPORT_DIR = Path.new(
    ENV.fetch(
      "GALAXY_APP_SUPPORT_DIR",
      (Path.home / "Library" /
       "Application Support" / "Galaxy").to_s,
    ),
  )

  # App data files backed up by `galaxy backups create`
  APP_DATA_FILES = {
    "sessions.json",
    "settings.json",
    "window-state.json",
    "viewed-artifact-files.json",
  }

  # Where install.sh puts the suite, and the record it leaves of what it put
  # there. Env overrides let specs point these at a sandbox.
  BIN_DIR            = GALAXY_DIR / "bin"
  INSTALLED_MANIFEST = GALAXY_DIR / "installed-manifest.json"
  INSTALLED_APP      = Path.new(
    ENV.fetch(
      "GALAXY_INSTALLED_APP",
      (Path.home / "Applications" / "Galaxy.app").to_s,
    ),
  )
  INSTALL_SCRIPT_URL = "https://raw.githubusercontent.com/kellyredding/galaxy/main/install.sh"

  # URL scheme for communicating with Galaxy.app
  URL_SCHEME = "galaxy"

  # Default Galaxy.app bundle identifier
  APP_BUNDLE_ID = "com.kellyredding.galaxy"

  # Claude Persona integration
  # Allow override via environment variable for testing
  # (mirrors claude-persona's pattern)
  CLAUDE_PERSONA_DIR = Path.new(
    ENV.fetch(
      "CLAUDE_PERSONA_DIR",
      (Path.home / ".claude-persona").to_s,
    ),
  )
  PERSONAS_DIR = CLAUDE_PERSONA_DIR / "personas"
end

# Only run CLI when executed directly, not when required by specs
unless ENV.has_key?("GALAXY_SKIP_CLI")
  Galaxy::CLI.run(ARGV)
end
