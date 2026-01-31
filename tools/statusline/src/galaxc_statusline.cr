require "./galaxc_statusline/*"

module GalaxcStatusline
  VERSION = "0.0.1"

  # Allow override via environment variable for testing
  CONFIG_DIR = Path.new(
    ENV.fetch(
      "GALAXC_STATUSLINE_CONFIG_DIR",
      (Path.home / ".claude" / "galaxc" / "statusline").to_s
    )
  )
  CONFIG_FILE = CONFIG_DIR / "config.json"
end

# Only run CLI when executed directly, not when required by specs
unless ENV.has_key?("GALAXC_STATUSLINE_SKIP_CLI")
  GalaxcStatusline::CLI.run(ARGV)
end
