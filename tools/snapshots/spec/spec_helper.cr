require "spec"
require "file_utils"

# Use a temporary directory for config during tests
# SPEC_CLAUDE_CONFIG_DIR simulates ~/.claude for testing skills install/uninstall
# Path must contain ".claude/galaxy" for SkillsManager.galaxy_symlink? to
# recognise our symlinks as Galaxy-managed (GALAXY_MARKER = ".claude/galaxy").
SPEC_CLAUDE_CONFIG_DIR = Path.new(Dir.tempdir) / "galaxy-snapshots-test-#{Random.rand(100000)}" / ".claude"
SPEC_GALAXY_DIR        = SPEC_CLAUDE_CONFIG_DIR / "galaxy"
SPEC_CONFIG_DIR        = SPEC_GALAXY_DIR / "snapshots"
SPEC_DATA_DIR          = SPEC_GALAXY_DIR / "data"
SPEC_DATABASE_PATH     = SPEC_DATA_DIR / "snapshots.db"

# Set all environment variables BEFORE requiring the module
ENV["GALAXY_CLAUDE_CONFIG_DIR"] = SPEC_CLAUDE_CONFIG_DIR.to_s
ENV["GALAXY_SNAPSHOTS_CONFIG_DIR"] = SPEC_CONFIG_DIR.to_s
ENV["GALAXY_DIR"] = SPEC_GALAXY_DIR.to_s
ENV["GALAXY_SNAPSHOTS_DATABASE_PATH"] = SPEC_DATABASE_PATH.to_s

# Point timeline binary to a no-op so fire-and-forget
# calls don't hit the real timeline during tests.
SPEC_TIMELINE_NOOP = SPEC_GALAXY_DIR / "bin" /
                     "galaxy-timeline"
ENV["GALAXY_TIMELINE_BIN"] = SPEC_TIMELINE_NOOP.to_s

# Ensure test directories exist
Dir.mkdir_p(SPEC_CLAUDE_CONFIG_DIR)
Dir.mkdir_p(SPEC_GALAXY_DIR)
Dir.mkdir_p(SPEC_CONFIG_DIR)
Dir.mkdir_p(SPEC_DATA_DIR)
Dir.mkdir_p(SPEC_GALAXY_DIR / "bin")
File.write(
  SPEC_TIMELINE_NOOP, "#!/bin/sh\nexit 0\n",
)
File.chmod(SPEC_TIMELINE_NOOP, 0o755)

# Must include all Config fields so Config.from_json succeeds.
SPEC_DEFAULT_CONFIG = {
  "_schema_version" => "0.0.0",
  "inline_char_cap" => 15000,
  "max_per_session" => 10,
  "editor"          => "",
}.to_json
File.write(SPEC_CONFIG_DIR / "config.json", SPEC_DEFAULT_CONFIG)

# Disable backups in the shared Galaxy config to prevent real backup
# operations during tests. The shared config lives at GALAXY_DIR/config.json.
SPEC_DEFAULT_SHARED_CONFIG = {
  "_schema_version" => "0.0.1",
  "backups"         => {
    "enabled"        => false,
    "retention_days" => 3,
    "path"           => "",
  },
}.to_json
File.write(SPEC_GALAXY_DIR / "config.json", SPEC_DEFAULT_SHARED_CONFIG)

# Skip CLI auto-run when loading module for specs
ENV["GALAXY_SNAPSHOTS_SKIP_CLI"] = "1"

require "../src/galaxy_snapshots"

# Helper for running the binary in integration tests
# __DIR__ is the spec/ directory, so we go up one level to find build/
BINARY_PATH = Path[__DIR__].parent / "build" / "galaxy-snapshots"

def run_binary(
  args : Array(String) = [] of String,
  stdin : String? = nil,
  extra_env : Hash(String, String) = {} of String => String,
) : NamedTuple(output: String, error: String, status: Int32)
  unless File.exists?(BINARY_PATH)
    raise "Binary not found at #{BINARY_PATH}. Run 'make dev' first."
  end

  # Unset skip cli if it was set
  ENV.delete("GALAXY_SNAPSHOTS_SKIP_CLI")

  input_io : Process::Stdio = Process::Redirect::Close
  if stdin
    input_io = IO::Memory.new(stdin)
  end

  base_env = {
    "GALAXY_CLAUDE_CONFIG_DIR"       => SPEC_CLAUDE_CONFIG_DIR.to_s,
    "GALAXY_SNAPSHOTS_CONFIG_DIR"    => SPEC_CONFIG_DIR.to_s,
    "GALAXY_DIR"                     => SPEC_GALAXY_DIR.to_s,
    "GALAXY_SNAPSHOTS_DATABASE_PATH" => SPEC_DATABASE_PATH.to_s,
    "GALAXY_TIMELINE_BIN"            => SPEC_TIMELINE_NOOP.to_s,
    "HOME"                           => ENV["HOME"],
    "PATH"                           => ENV["PATH"],
    # Clear editor env vars so they don't leak into snapshot open tests.
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

# Clear all data before each test. Integration tests that call
# run_binary can leave behind data. Rather than relying on per-test
# cleanup (which is skipped on assertion failure), wipe everything
# between tests for full isolation.
Spec.before_each do
  db_path = SPEC_DATABASE_PATH.to_s
  next unless File.exists?(db_path)

  begin
    db = DB.open("sqlite3://#{db_path}")
    db.exec("PRAGMA busy_timeout=5000")
    db.exec("DELETE FROM snapshot_annotations")
    db.exec("DELETE FROM snapshot_reviews")
    db.exec("DELETE FROM snapshots")
    # Flush WAL back to main DB to prevent unbounded WAL growth from
    # run_binary subprocess writes.
    db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
    db.close
  rescue
    # DB may not exist yet or table may not exist for early specs
  end

  # Reset config files to defaults.
  File.write(SPEC_CONFIG_DIR / "config.json", SPEC_DEFAULT_CONFIG)
  File.write(SPEC_GALAXY_DIR / "config.json", SPEC_DEFAULT_SHARED_CONFIG)
end

# Flush WAL to main DB so subprocess connections see recently committed data.
# Use after Database writes that precede run_binary() subprocess calls.
def flush_wal
  GalaxySnapshots::Database.open do |db|
    db.exec("PRAGMA wal_checkpoint(PASSIVE)")
  end
end

# Clean up entire test directory after all specs
Spec.after_suite do
  FileUtils.rm_rf(SPEC_CLAUDE_CONFIG_DIR.to_s) if Dir.exists?(SPEC_CLAUDE_CONFIG_DIR)
end
