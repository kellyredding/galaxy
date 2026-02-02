require "./galaxy/*"

module Galaxy
  VERSION = "0.0.1"

  # Galaxy-level directory (shared between tools)
  GALAXY_DIR = Path.new(
    ENV.fetch(
      "GALAXY_DIR",
      (Path.home / ".claude" / "galaxy").to_s
    )
  )

  # URL scheme for communicating with Galaxy.app
  URL_SCHEME = "galaxy"

  # Default Galaxy.app bundle identifier
  APP_BUNDLE_ID = "com.kellyredding.galaxy"
end

# Only run CLI when executed directly, not when required by specs
unless ENV.has_key?("GALAXY_SKIP_CLI")
  Galaxy::CLI.run(ARGV)
end
