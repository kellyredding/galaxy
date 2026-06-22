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

  # Claude Code settings directory and file. The statusline hook
  # is registered as a top-level "statusLine" key in settings.json.
  # CLAUDE_CONFIG_DIR may be overridden via environment variable
  # (used by specs and for sandboxed CLI validation).
  CLAUDE_CONFIG_DIR = Path.new(
    ENV.fetch(
      "CLAUDE_CONFIG_DIR",
      (Path.home / ".claude").to_s
    )
  )
  SETTINGS_FILE = CLAUDE_CONFIG_DIR / "settings.json"

  # Canonical command string written into Claude Code's settings.json
  # by `hook install`. A literal "~" rather than an absolute
  # /Users/<name> path so a symlink-synced settings.json stays
  # byte-identical across machines with different home paths — Claude
  # Code expands ~ in statusLine.command at runtime. Mirrors
  # GalaxyLedger::HooksManager, whose hook commands are likewise
  # hardcoded with ~. GALAXY_DIR stays absolute for locating the
  # config and binary at runtime; only the written command is ~-based.
  HOOK_COMMAND = "~/.claude/galaxy/bin/galaxy-statusline"
end

# Only run CLI when executed directly, not when required by specs
unless ENV.has_key?("GALAXY_STATUSLINE_SKIP_CLI")
  GalaxyStatusline::CLI.run(ARGV)
end
