require "spec"
require "file_utils"

# Use a temporary directory for config during tests
# SPEC_CLAUDE_CONFIG_DIR simulates ~/.claude for testing skills install/uninstall
# Path must contain ".claude/galaxy" for SkillsManager.galaxy_symlink? to
# recognise our symlinks as Galaxy-managed (GALAXY_MARKER = ".claude/galaxy").
SPEC_CLAUDE_CONFIG_DIR = Path.new(Dir.tempdir) / "galaxy-artifacts-test-#{Random.rand(100000)}" / ".claude"
SPEC_GALAXY_DIR        = SPEC_CLAUDE_CONFIG_DIR / "galaxy"
SPEC_CONFIG_DIR        = SPEC_GALAXY_DIR / "artifacts"
SPEC_DATA_DIR          = SPEC_GALAXY_DIR / "data"
SPEC_DATABASE_PATH     = SPEC_DATA_DIR / "artifacts.db"

# Set all environment variables BEFORE requiring the module
ENV["GALAXY_CLAUDE_CONFIG_DIR"] = SPEC_CLAUDE_CONFIG_DIR.to_s
ENV["GALAXY_ARTIFACTS_CONFIG_DIR"] = SPEC_CONFIG_DIR.to_s
ENV["GALAXY_DIR"] = SPEC_GALAXY_DIR.to_s
ENV["GALAXY_ARTIFACTS_DATABASE_PATH"] = SPEC_DATABASE_PATH.to_s

# Ensure test directories exist
Dir.mkdir_p(SPEC_CLAUDE_CONFIG_DIR)
Dir.mkdir_p(SPEC_GALAXY_DIR)
Dir.mkdir_p(SPEC_CONFIG_DIR)
Dir.mkdir_p(SPEC_DATA_DIR)

# Disable backups in test config to prevent real backup operations.
# This is also used by Spec.before_each to reset config between tests.
# Must include all Config fields so Config.from_json succeeds (otherwise
# it falls back to Config.new which has backups.enabled = true).
SPEC_DEFAULT_CONFIG = {
  "_schema_version" => "0.0.0",
  "enabled"         => true,
  "auto_detect"     => true,
  "max_file_size"   => 52_428_800,
  "backups"         => {
    "enabled"        => false,
    "retention_days" => 3,
    "path"           => "",
  },
}.to_json
File.write(SPEC_CONFIG_DIR / "config.json", SPEC_DEFAULT_CONFIG)

# Skip CLI auto-run when loading module for specs
ENV["GALAXY_ARTIFACTS_SKIP_CLI"] = "1"

require "../src/galaxy_artifacts"

# Helper for running the binary in integration tests
# __DIR__ is the spec/ directory, so we go up one level to find build/
BINARY_PATH = Path[__DIR__].parent / "build" / "galaxy-artifacts"

def run_binary(
  args : Array(String) = [] of String,
  stdin : String? = nil,
  extra_env : Hash(String, String) = {} of String => String,
) : NamedTuple(output: String, error: String, status: Int32)
  unless File.exists?(BINARY_PATH)
    raise "Binary not found at #{BINARY_PATH}. Run 'make dev' first."
  end

  # Unset skip cli if it was set
  ENV.delete("GALAXY_ARTIFACTS_SKIP_CLI")

  input_io : Process::Stdio = Process::Redirect::Close
  if stdin
    input_io = IO::Memory.new(stdin)
  end

  base_env = {
    "GALAXY_CLAUDE_CONFIG_DIR"       => SPEC_CLAUDE_CONFIG_DIR.to_s,
    "GALAXY_ARTIFACTS_CONFIG_DIR"    => SPEC_CONFIG_DIR.to_s,
    "GALAXY_DIR"                     => SPEC_GALAXY_DIR.to_s,
    "GALAXY_ARTIFACTS_DATABASE_PATH" => SPEC_DATABASE_PATH.to_s,
    "HOME"                           => ENV["HOME"],
    "PATH"                           => ENV["PATH"],
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
    db.exec("DELETE FROM artifacts")
    # Flush WAL back to main DB to prevent unbounded WAL growth from
    # run_binary subprocess writes.
    db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
    db.close
  rescue
    # DB may not exist yet or table may not exist for early specs
  end

  # Reset config file to defaults.
  File.write(SPEC_CONFIG_DIR / "config.json", SPEC_DEFAULT_CONFIG)

  # Clean up artifact storage directory
  artifacts_dir = SPEC_DATA_DIR / "artifacts"
  FileUtils.rm_rf(artifacts_dir.to_s) if Dir.exists?(artifacts_dir)
end

# Flush WAL to main DB so subprocess connections see recently committed data.
# Use after Database writes that precede run_binary() subprocess calls.
def flush_wal
  GalaxyArtifacts::Database.open do |db|
    db.exec("PRAGMA wal_checkpoint(PASSIVE)")
  end
end

# Create a temporary test file and return its path.
def create_test_file(
  filename : String = "test-artifact.csv",
  content : String = "name,value\nfoo,42\nbar,99",
) : String
  dir = Path.new(Dir.tempdir) / "galaxy-artifacts-test-files"
  Dir.mkdir_p(dir) unless Dir.exists?(dir)
  path = (dir / filename).to_s
  File.write(path, content)
  path
end

# Clean up entire test directory after all specs
Spec.after_suite do
  FileUtils.rm_rf(SPEC_CLAUDE_CONFIG_DIR.to_s) if Dir.exists?(SPEC_CLAUDE_CONFIG_DIR)
  test_files_dir = Path.new(Dir.tempdir) / "galaxy-artifacts-test-files"
  FileUtils.rm_rf(test_files_dir.to_s) if Dir.exists?(test_files_dir)
end
