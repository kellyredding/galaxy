require "spec"
require "file_utils"

# Set up test fixtures directory via environment variable
# This must be set BEFORE requiring galaxy_statusline so CONFIG_DIR picks it up
SPEC_FIXTURES = Path[__DIR__] / "fixtures"

# Use a temporary directory for all Galaxy data during tests
# This isolates sessions, config, and all other data from live Claude sessions
SPEC_GALAXY_DIR = Path.new(Dir.tempdir) / "galaxy-statusline-test-#{Random.rand(100000)}"
ENV["GALAXY_DIR"] = SPEC_GALAXY_DIR.to_s

# Config dir is derived from GALAXY_DIR, but we can also set it explicitly
SPEC_CONFIG_DIR = SPEC_GALAXY_DIR / "statusline"
ENV["GALAXY_STATUSLINE_CONFIG_DIR"] = SPEC_CONFIG_DIR.to_s

# Skip CLI auto-run when loading module for specs
ENV["GALAXY_STATUSLINE_SKIP_CLI"] = "1"

require "../src/galaxy_statusline"

# Helper to read fixture files
def fixture_path(relative_path : String) : Path
  SPEC_FIXTURES / relative_path
end

def read_fixture(relative_path : String) : String
  File.read(fixture_path(relative_path))
end

# Helper for running the binary in integration tests
# __DIR__ is the spec/ directory, so we go up one level to find build/
BINARY_PATH = Path[__DIR__].parent / "build" / "galaxy-statusline"

def run_binary(
  args : Array(String) = [] of String,
  stdin : String? = nil,
) : NamedTuple(output: String, error: String, status: Int32)
  unless File.exists?(BINARY_PATH)
    raise "Binary not found at #{BINARY_PATH}. Run 'make dev' first."
  end

  # Set env vars for isolated testing - they'll be inherited by subprocess
  ENV["GALAXY_DIR"] = SPEC_GALAXY_DIR.to_s
  ENV["GALAXY_STATUSLINE_CONFIG_DIR"] = SPEC_CONFIG_DIR.to_s
  # Unset skip cli so the binary runs normally
  ENV.delete("GALAXY_STATUSLINE_SKIP_CLI")

  input_io : Process::Stdio = Process::Redirect::Close
  if stdin
    input_io = IO::Memory.new(stdin)
  end

  process = Process.new(
    BINARY_PATH.to_s,
    args: args,
    input: input_io,
    output: Process::Redirect::Pipe,
    error: Process::Redirect::Pipe
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

# Clean up test Galaxy directory after all specs (includes sessions, config, etc.)
Spec.after_suite do
  FileUtils.rm_rf(SPEC_GALAXY_DIR.to_s) if Dir.exists?(SPEC_GALAXY_DIR)
end
