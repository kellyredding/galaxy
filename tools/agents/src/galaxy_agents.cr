require "./galaxy_agents/*"

module GalaxyAgents
  VERSION = {{
              read_file("#{__DIR__}/../version.txt").strip
            }}

  CLAUDE_CONFIG_DIR = Path.new(
    ENV.fetch(
      "GALAXY_CLAUDE_CONFIG_DIR",
      (Path.home / ".claude").to_s,
    ),
  )
  GALAXY_DIR = Path.new(
    ENV.fetch(
      "GALAXY_DIR",
      (CLAUDE_CONFIG_DIR / "galaxy").to_s,
    ),
  )
  DATA_DIR   = GALAXY_DIR / "data"
  CONFIG_DIR = Path.new(
    ENV.fetch(
      "GALAXY_AGENTS_CONFIG_DIR",
      (GALAXY_DIR / "agents").to_s,
    ),
  )
  CONFIG_FILE = CONFIG_DIR / "config.json"
  LEDGER_BIN  = Path.new(
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
end

unless ENV.has_key?("GALAXY_AGENTS_SKIP_CLI")
  GalaxyAgents::CLI.run(ARGV)
end
