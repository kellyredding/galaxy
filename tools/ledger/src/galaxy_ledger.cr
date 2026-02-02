require "./galaxy_ledger/*"

module GalaxyLedger
  VERSION = "0.0.1"

  # Galaxy-level directories (shared between tools)
  GALAXY_DIR = Path.new(
    ENV.fetch(
      "GALAXY_DIR",
      (Path.home / ".claude" / "galaxy").to_s
    )
  )

  # Ledger-specific directories
  CONFIG_DIR = Path.new(
    ENV.fetch(
      "GALAXY_LEDGER_CONFIG_DIR",
      (GALAXY_DIR / "ledger").to_s
    )
  )
  CONFIG_FILE = CONFIG_DIR / "config.json"

  # Sessions directory for per-session state (shared between tools)
  SESSIONS_DIR = GALAXY_DIR / "sessions"

  # Context status filename (read from each session's folder, written by statusline)
  CONTEXT_STATUS_FILENAME = "context-status.json"

  # Ledger-specific filenames within session folders
  LEDGER_BUFFER_FILENAME          = "ledger_buffer.jsonl"
  LEDGER_BUFFER_FLUSHING_FILENAME = "ledger_buffer.flushing.jsonl"
  LEDGER_BUFFER_LOCK_FILENAME     = "ledger_buffer.lock"
  LEDGER_LAST_EXCHANGE_FILENAME   = "ledger_last-exchange.json"

  # Helper to get session-specific context status file path
  def self.context_status_path(session_id : String) : Path
    SESSIONS_DIR / session_id / CONTEXT_STATUS_FILENAME
  end

  # Helper to get session directory path
  def self.session_dir(session_id : String) : Path
    SESSIONS_DIR / session_id
  end
end

# Only run CLI when executed directly, not when required by specs
unless ENV.has_key?("GALAXY_LEDGER_SKIP_CLI")
  GalaxyLedger::CLI.run(ARGV)
end
