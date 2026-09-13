require "json"
require "socket"
require "file_utils"
require "./galaxy_files/*"

module GalaxyFiles
  VERSION = {{ read_file("#{__DIR__}/../version.txt").strip }}

  CLAUDE_CONFIG_DIR = Path.new(ENV.fetch("GALAXY_CLAUDE_CONFIG_DIR", (Path.home / ".claude").to_s))
  GALAXY_DIR        = Path.new(ENV.fetch("GALAXY_DIR", (CLAUDE_CONFIG_DIR / "galaxy").to_s))
  SKILLS_DIR        = GALAXY_DIR / "files" / "skills"
  CLAUDE_SKILLS_DIR = CLAUDE_CONFIG_DIR / "skills"
  LEDGER_BIN        = Path.new(ENV.fetch("GALAXY_LEDGER_BIN", (GALAXY_DIR / "bin" / "galaxy-ledger").to_s))
  SOCKET_PATH       = Path.new(ENV.fetch("GALAXY_SOCKET_PATH", (GALAXY_DIR / "galaxy.sock").to_s))
end

unless ENV.has_key?("GALAXY_FILES_SKIP_CLI")
  GalaxyFiles::CLI.run(ARGV)
end
