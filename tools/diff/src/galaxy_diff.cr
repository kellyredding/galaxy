require "./galaxy_diff/*"

module GalaxyDiff
  VERSION = {{ read_file("#{__DIR__}/../version.txt").strip }}

  CLAUDE_CONFIG_DIR = Path.new(ENV.fetch("GALAXY_CLAUDE_CONFIG_DIR", (Path.home / ".claude").to_s))
  GALAXY_DIR        = Path.new(ENV.fetch("GALAXY_DIR", (CLAUDE_CONFIG_DIR / "galaxy").to_s))
  SKILLS_DIR        = GALAXY_DIR / "diff" / "skills"
  CLAUDE_SKILLS_DIR = CLAUDE_CONFIG_DIR / "skills"
end

unless ENV.has_key?("GALAXY_DIFF_SKIP_CLI")
  GalaxyDiff::CLI.run(ARGV)
end
