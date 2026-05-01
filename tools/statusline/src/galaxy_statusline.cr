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

  # Canonical command path written by `hook install`. Anchored to
  # GALAXY_DIR so test sandboxes get a sandbox-relative command.
  HOOK_COMMAND = (GALAXY_DIR / "bin" / "galaxy-statusline").to_s
end

# Only run CLI when executed directly, not when required by specs
unless ENV.has_key?("GALAXY_STATUSLINE_SKIP_CLI")
  GalaxyStatusline::CLI.run(ARGV)
end
