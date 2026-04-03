require "./galaxy_snapshots/*"

module GalaxySnapshots
  VERSION = {{ read_file("#{__DIR__}/../version.txt").strip }}

  CLAUDE_CONFIG_DIR = Path.new(ENV.fetch("GALAXY_CLAUDE_CONFIG_DIR", (Path.home / ".claude").to_s))
  GALAXY_DIR        = Path.new(ENV.fetch("GALAXY_DIR", (CLAUDE_CONFIG_DIR / "galaxy").to_s))
  DATA_DIR          = GALAXY_DIR / "data"
  CONFIG_DIR        = Path.new(ENV.fetch("GALAXY_SNAPSHOTS_CONFIG_DIR", (GALAXY_DIR / "snapshots").to_s))
  CONFIG_FILE       = CONFIG_DIR / "config.json"
  SKILLS_DIR        = GALAXY_DIR / "snapshots" / "skills"
  CLAUDE_SKILLS_DIR = CLAUDE_CONFIG_DIR / "skills"
  LEDGER_BIN        = Path.new(ENV.fetch("GALAXY_LEDGER_BIN", (GALAXY_DIR / "bin" / "galaxy-ledger").to_s))
  TIMELINE_BIN      = ENV.fetch("GALAXY_TIMELINE_BIN", "galaxy-timeline")
end

unless ENV.has_key?("GALAXY_SNAPSHOTS_SKIP_CLI")
  GalaxySnapshots::CLI.run(ARGV)
end
