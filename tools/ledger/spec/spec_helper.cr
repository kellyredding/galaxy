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

# Ensure test directories exist
Dir.mkdir_p(SPEC_CLAUDE_CONFIG_DIR)
Dir.mkdir_p(SPEC_GALAXY_DIR)
Dir.mkdir_p(SPEC_CONFIG_DIR)
Dir.mkdir_p(SPEC_DATA_DIR)

# Disable extraction in test config to prevent real Claude CLI calls.
# Extraction logic is covered by stubbed pipeline specs and eval specs.
File.write(SPEC_CONFIG_DIR / "config.json", {
  "extraction" => {
    "on_stop"           => false,
    "on_guideline_read" => false,
  },
}.to_json)

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
    "HOME"                        => ENV["HOME"],
    "PATH"                        => ENV["PATH"],
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
    db.exec("DELETE FROM ledger_session_pids")
    db.exec("DELETE FROM ledger_session_identifiers")
    db.exec("DELETE FROM ledger_session_files")
    db.exec("DELETE FROM ledger_entries")
    db.exec("DELETE FROM ledger_sessions")
    db.close
  rescue
    # DB may not exist yet or table may not exist for early specs
  end
end

# Clean up entire test directory after all specs (includes sessions, config, data, etc.)
Spec.after_suite do
  FileUtils.rm_rf(SPEC_CLAUDE_CONFIG_DIR.to_s) if Dir.exists?(SPEC_CLAUDE_CONFIG_DIR)
end
