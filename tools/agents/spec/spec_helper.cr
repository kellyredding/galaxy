require "spec"
require "file_utils"

# Use a temporary directory for config during tests.
SPEC_CLAUDE_CONFIG_DIR = Path.new(Dir.tempdir) /
                         "galaxy-agents-test-#{Random.rand(100000)}" /
                         ".claude"
SPEC_GALAXY_DIR    = SPEC_CLAUDE_CONFIG_DIR / "galaxy"
SPEC_CONFIG_DIR    = SPEC_GALAXY_DIR / "agents"
SPEC_DATA_DIR      = SPEC_GALAXY_DIR / "data"
SPEC_DATABASE_PATH = SPEC_DATA_DIR / "agents.db"

# Set all environment variables BEFORE requiring module
ENV["GALAXY_CLAUDE_CONFIG_DIR"] =
  SPEC_CLAUDE_CONFIG_DIR.to_s
ENV["GALAXY_AGENTS_CONFIG_DIR"] =
  SPEC_CONFIG_DIR.to_s
ENV["GALAXY_DIR"] = SPEC_GALAXY_DIR.to_s
ENV["GALAXY_AGENTS_DATABASE_PATH"] =
  SPEC_DATABASE_PATH.to_s

# Point timeline binary to a no-op so fire-and-forget
# calls don't hit the real timeline during tests.
SPEC_TIMELINE_NOOP = SPEC_GALAXY_DIR / "bin" /
                     "galaxy-timeline"
ENV["GALAXY_TIMELINE_BIN"] = SPEC_TIMELINE_NOOP.to_s

# Point artifacts binary to a no-op
SPEC_ARTIFACTS_NOOP = SPEC_GALAXY_DIR / "bin" /
                      "galaxy-artifacts"
ENV["GALAXY_ARTIFACTS_BIN"] = SPEC_ARTIFACTS_NOOP.to_s

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
File.write(
  SPEC_ARTIFACTS_NOOP, "#!/bin/sh\nexit 0\n",
)
File.chmod(SPEC_ARTIFACTS_NOOP, 0o755)

# Tool-level config (no backup settings).
SPEC_DEFAULT_CONFIG = {
  "_schema_version" => "0.0.0",
  "enabled"         => true,
}.to_json
File.write(
  SPEC_CONFIG_DIR / "config.json", SPEC_DEFAULT_CONFIG,
)

# Shared Galaxy config with backups disabled for tests.
SPEC_SHARED_CONFIG = {
  "_schema_version" => "0.0.1",
  "backups"         => {
    "enabled"        => false,
    "retention_days" => 3,
    "path"           => "",
  },
}.to_json
File.write(
  SPEC_GALAXY_DIR / "config.json", SPEC_SHARED_CONFIG,
)

# Skip CLI auto-run when loading module for specs
ENV["GALAXY_AGENTS_SKIP_CLI"] = "1"

require "../src/galaxy_agents"

# Helper for running the binary in integration tests
BINARY_PATH = Path[__DIR__].parent /
              "build" / "galaxy-agents"

def run_binary(
  args : Array(String) = [] of String,
  stdin : String? = nil,
  extra_env : Hash(String, String) = (
    {} of String => String
  ),
) : NamedTuple(
  output: String, error: String, status: Int32,
)
  unless File.exists?(BINARY_PATH)
    raise(
      "Binary not found at #{BINARY_PATH}. " \
      "Run 'make dev' first.",
    )
  end

  ENV.delete("GALAXY_AGENTS_SKIP_CLI")

  input_io : Process::Stdio = Process::Redirect::Close
  if stdin
    input_io = IO::Memory.new(stdin)
  end

  base_env = {
    "GALAXY_CLAUDE_CONFIG_DIR"    => SPEC_CLAUDE_CONFIG_DIR.to_s,
    "GALAXY_AGENTS_CONFIG_DIR"    => SPEC_CONFIG_DIR.to_s,
    "GALAXY_DIR"                  => SPEC_GALAXY_DIR.to_s,
    "GALAXY_AGENTS_DATABASE_PATH" => SPEC_DATABASE_PATH.to_s,
    "GALAXY_TIMELINE_BIN"         => SPEC_TIMELINE_NOOP.to_s,
    "GALAXY_ARTIFACTS_BIN"        => SPEC_ARTIFACTS_NOOP.to_s,
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

  output_content = process.output.gets_to_end
  error_content = process.error.gets_to_end

  status = process.wait

  {
    output: output_content,
    error:  error_content,
    status: status.exit_code,
  }
end

# Clear all data before each test.
Spec.before_each do
  db_path = SPEC_DATABASE_PATH.to_s
  next unless File.exists?(db_path)

  begin
    db = DB.open("sqlite3://#{db_path}")
    db.exec("PRAGMA busy_timeout=5000")
    db.exec("DELETE FROM agents")
    db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
    db.close
  rescue
    # DB may not exist yet
  end

  File.write(
    SPEC_CONFIG_DIR / "config.json",
    SPEC_DEFAULT_CONFIG,
  )
  File.write(
    SPEC_GALAXY_DIR / "config.json",
    SPEC_SHARED_CONFIG,
  )
end

# Flush WAL to main DB so subprocess connections
# see recently committed data.
def flush_wal
  GalaxyAgents::Database.open do |db|
    db.exec("PRAGMA wal_checkpoint(PASSIVE)")
  end
end

# Clean up entire test directory after all specs
Spec.after_suite do
  if Dir.exists?(SPEC_CLAUDE_CONFIG_DIR)
    FileUtils.rm_rf(SPEC_CLAUDE_CONFIG_DIR.to_s)
  end
end
