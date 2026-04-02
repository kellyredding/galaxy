require "spec"
require "file_utils"

# Set up test fixtures directory via environment variable
# This must be set BEFORE requiring galaxy_ledger so paths pick it up
SPEC_FIXTURES = Path[__DIR__] / "fixtures"

# Use a temporary directory for config during tests
# SPEC_CLAUDE_CONFIG_DIR simulates ~/.claude for testing hooks install/uninstall
SPEC_CLAUDE_CONFIG_DIR = Path.new(Dir.tempdir) / "galaxy-ledger-test-#{Random.rand(100000)}"
SPEC_GALAXY_DIR        = SPEC_CLAUDE_CONFIG_DIR / "galaxy"
SPEC_CONFIG_DIR        = SPEC_GALAXY_DIR / "ledger"
SPEC_DATA_DIR          = SPEC_GALAXY_DIR / "data"
SPEC_DATABASE_PATH     = SPEC_DATA_DIR / "ledger.db"

# Set all environment variables BEFORE requiring the module
ENV["GALAXY_CLAUDE_CONFIG_DIR"] = SPEC_CLAUDE_CONFIG_DIR.to_s
ENV["GALAXY_LEDGER_CONFIG_DIR"] = SPEC_CONFIG_DIR.to_s
ENV["GALAXY_DIR"] = SPEC_GALAXY_DIR.to_s
ENV["GALAXY_LEDGER_DATABASE_PATH"] = SPEC_DATABASE_PATH.to_s

# Point timeline binary to a no-op so fire-and-forget calls
# don't hit the real timeline database during tests.
SPEC_TIMELINE_NOOP = SPEC_GALAXY_DIR / "bin" /
                     "galaxy-timeline"
ENV["GALAXY_TIMELINE_BIN"] = SPEC_TIMELINE_NOOP.to_s

# Point agents binary to a no-op so fire-and-forget calls
# don't hit the real agents database during tests.
SPEC_AGENTS_NOOP = SPEC_GALAXY_DIR / "bin" /
                   "galaxy-agents"
ENV["GALAXY_AGENTS_BIN"] = SPEC_AGENTS_NOOP.to_s

# Ensure test directories exist
Dir.mkdir_p(SPEC_CLAUDE_CONFIG_DIR)
Dir.mkdir_p(SPEC_GALAXY_DIR)
Dir.mkdir_p(SPEC_CONFIG_DIR)
Dir.mkdir_p(SPEC_DATA_DIR)
Dir.mkdir_p(SPEC_GALAXY_DIR / "bin")
File.write(SPEC_TIMELINE_NOOP, "#!/bin/sh\nexit 0\n")
File.chmod(SPEC_TIMELINE_NOOP, 0o755)
File.write(SPEC_AGENTS_NOOP, "#!/bin/sh\nexit 0\n")
File.chmod(SPEC_AGENTS_NOOP, 0o755)

# Disable extraction and backups in test config to prevent real Claude
# CLI calls and unnecessary VACUUM INTO operations.
# Generated from Config.default to include all required fields so
# subprocess Config.from_json never falls back to defaults.
# This is also used by Spec.before_each to reset config between tests,
# preventing config file leakage from tests that write custom configs.
SPEC_DEFAULT_CONFIG = begin
  config = GalaxyLedger::Config.default
  config.extraction.on_stop = false
  config.extraction.on_guideline_read = false
  config.backups.enabled = false
  config.to_pretty_json
end
File.write(SPEC_CONFIG_DIR / "config.json", SPEC_DEFAULT_CONFIG)

# Skip CLI auto-run when loading module for specs
ENV["GALAXY_LEDGER_SKIP_CLI"] = "1"

require "../src/galaxy_ledger"

# Helper to read fixture files
def fixture_path(relative_path : String) : Path
  SPEC_FIXTURES / relative_path
end

def read_fixture(relative_path : String) : String
  File.read(fixture_path(relative_path))
end

# Helper for running the binary in integration tests
# __DIR__ is the spec/ directory, so we go up one level to find build/
BINARY_PATH = Path[__DIR__].parent / "build" / "galaxy-ledger"

def run_binary(
  args : Array(String) = [] of String,
  stdin : String? = nil,
  extra_env : Hash(String, String) = {} of String => String,
) : NamedTuple(output: String, error: String, status: Int32)
  unless File.exists?(BINARY_PATH)
    raise "Binary not found at #{BINARY_PATH}. Run 'make dev' first."
  end

  # Unset skip cli if it was set
  ENV.delete("GALAXY_LEDGER_SKIP_CLI")

  input_io : Process::Stdio = Process::Redirect::Close
  if stdin
    input_io = IO::Memory.new(stdin)
  end

  base_env = {
    "GALAXY_CLAUDE_CONFIG_DIR"    => SPEC_CLAUDE_CONFIG_DIR.to_s,
    "GALAXY_LEDGER_CONFIG_DIR"    => SPEC_CONFIG_DIR.to_s,
    "GALAXY_DIR"                  => SPEC_GALAXY_DIR.to_s,
    "GALAXY_LEDGER_DATABASE_PATH" => SPEC_DATABASE_PATH.to_s,
    "GALAXY_TIMELINE_BIN"         => SPEC_TIMELINE_NOOP.to_s,
    "GALAXY_AGENTS_BIN"           => SPEC_AGENTS_NOOP.to_s,
    "HOME"                        => ENV["HOME"],
    "PATH"                        => ENV["PATH"],
    # Clear CLAUDE_CLI_SESSION_ID so subprocesses don't inherit it from
    # the parent environment (e.g., when specs run inside a Claude Persona
    # session). Tests that need it set should pass it via extra_env.
    "CLAUDE_CLI_SESSION_ID" => "",
    # Clear CLAUDECODE so subprocesses (e.g., extraction evals that spawn
    # Claude CLI) don't hit the "nested session" detection and refuse to
    # start. Galaxy.app does the same when launching child processes.
    "CLAUDECODE" => "",
    # Clear editor env vars so they don't leak into tests.
    # Tests that need these set should pass them via extra_env.
    "VISUAL" => "",
    "EDITOR" => "",
  }
  merged_env = base_env.merge(extra_env)

  process = Process.new(
    BINARY_PATH.to_s,
    args: args,
    input: input_io,
    output: Process::Redirect::Pipe,
    error: Process::Redirect::Pipe,
    env: merged_env,
  )

  # Read output streams
  output_content = process.output.gets_to_end
  error_content = process.error.gets_to_end

  status = process.wait

  {
    output: output_content,
    error:  error_content,
    status: status.exit_code,
  }
end

# Clear all session data before each test. Integration tests that call
# run_binary can leave behind sessions, PID mappings, and identifier
# mappings. Rather than relying on per-test cleanup (which is skipped on
# assertion failure), wipe everything between tests for full isolation.
#
# Uses a direct DB.open (bypassing Database.open's migration machinery)
# to avoid "database is locked" flakes caused by pool connections not
# fully releasing before the next Database.open call.
Spec.before_each do
  db_path = SPEC_DATABASE_PATH.to_s
  next unless File.exists?(db_path)

  begin
    db = DB.open("sqlite3://#{db_path}")
    db.exec("PRAGMA busy_timeout=5000")
    db.exec("DELETE FROM ledger_artifacts")
    db.exec("DELETE FROM ledger_session_pids")
    db.exec("DELETE FROM ledger_session_identifiers")
    db.exec("DELETE FROM ledger_session_files")
    db.exec("DELETE FROM ledger_session_daily_usages")
    db.exec("DELETE FROM ledger_entries")
    db.exec("DELETE FROM ledger_sessions")
    # Flush WAL back to main DB to prevent unbounded WAL growth from
    # run_binary subprocess writes. Without this, the WAL grows across
    # integration tests until a subprocess checkpoint corrupts it.
    db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
    db.close
  rescue
    # DB may not exist yet or table may not exist for early specs
  end

  # Reset config file to defaults. Tests that write custom configs
  # (e.g., backup integration, config migration) can leak state to
  # later tests that depend on Config.load behavior.
  File.write(SPEC_CONFIG_DIR / "config.json", SPEC_DEFAULT_CONFIG)
end

# Flush WAL to main DB so subprocess connections see
# recently committed data. Use after Database writes
# that precede run_binary() subprocess calls.
# Uses TRUNCATE mode to guarantee a full checkpoint —
# PASSIVE can skip pages if concurrent readers/writers
# hold locks.
def flush_wal
  GalaxyLedger::Database.open do |db|
    db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
  end
end

# Flush WAL and verify a session is resolvable before
# returning. Under concurrent eval fibers, a single
# TRUNCATE checkpoint can race with other fibers'
# writes, leaving the session invisible to subprocess
# connections. Retries the checkpoint up to 3 times
# with a brief sleep between attempts.
def flush_wal_for(session_id : String, retries = 3)
  retries.times do |i|
    GalaxyLedger::Database.open do |db|
      db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
    end
    resolved = GalaxyLedger::Database
      .resolve_session_identifier(session_id)
    return if resolved
    sleep 50.milliseconds if i < retries - 1
  end
end

# Clean up entire test directory after all specs (includes sessions, config, data, etc.)
Spec.after_suite do
  FileUtils.rm_rf(SPEC_CLAUDE_CONFIG_DIR.to_s) if Dir.exists?(SPEC_CLAUDE_CONFIG_DIR)
end
