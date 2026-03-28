require "./galaxy_timeline/*"

module GalaxyTimeline
  VERSION = {{ read_file("#{__DIR__}/../version.txt").strip }}

  CLAUDE_CONFIG_DIR = Path.new(ENV.fetch("GALAXY_CLAUDE_CONFIG_DIR", (Path.home / ".claude").to_s))
  GALAXY_DIR        = Path.new(ENV.fetch("GALAXY_DIR", (CLAUDE_CONFIG_DIR / "galaxy").to_s))
  DATA_DIR          = GALAXY_DIR / "data"
  CONFIG_DIR        = Path.new(ENV.fetch("GALAXY_TIMELINE_CONFIG_DIR", (GALAXY_DIR / "timeline").to_s))
  CONFIG_FILE       = CONFIG_DIR / "config.json"
  LEDGER_BIN        = Path.new(ENV.fetch("GALAXY_LEDGER_BIN", (GALAXY_DIR / "bin" / "galaxy-ledger").to_s))
end

unless ENV.has_key?("GALAXY_TIMELINE_SKIP_CLI")
  GalaxyTimeline::CLI.run(ARGV)
end
