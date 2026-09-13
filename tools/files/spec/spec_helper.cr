require "spec"
require "file_utils"
require "socket"

# A sandboxed ~/.claude, so installing the skill never touches the real one. The
# path must contain ".claude/galaxy" for SkillsManager to recognise its own
# symlinks.
SPEC_ROOT              = Path.new(Dir.tempdir) / "galaxy-files-test-#{Random.rand(100000)}"
SPEC_CLAUDE_CONFIG_DIR = SPEC_ROOT / ".claude"
SPEC_GALAXY_DIR        = SPEC_CLAUDE_CONFIG_DIR / "galaxy"
SPEC_LEDGER_BIN        = SPEC_GALAXY_DIR / "bin" / "galaxy-ledger"
SPEC_PID               = "4242"
SPEC_LEDGER_SESSION_ID = 42_i64

ENV["GALAXY_CLAUDE_CONFIG_DIR"] = SPEC_CLAUDE_CONFIG_DIR.to_s
ENV["GALAXY_DIR"] = SPEC_GALAXY_DIR.to_s
ENV["GALAXY_LEDGER_BIN"] = SPEC_LEDGER_BIN.to_s
ENV["GALAXY_FILES_SKIP_CLI"] = "1"

Dir.mkdir_p(SPEC_LEDGER_BIN.parent)

# Stands in for galaxy-ledger: one known agent process, and the ledger's own
# refusal for any other.
File.write(SPEC_LEDGER_BIN, <<-SH)
  #!/bin/sh
  case "$1" in
    resolve-session)
      if [ "$3" = "#{SPEC_PID}" ]; then echo #{SPEC_LEDGER_SESSION_ID}; exit 0; fi
      echo "Error: no ledger session for PID $3" >&2
      exit 1 ;;
    session-identifiers)
      echo '{"session_identifiers":["claude-one","claude-two"]}' ;;
    *)
      exit 1 ;;
  esac
  SH
File.chmod(SPEC_LEDGER_BIN, 0o755)

require "../src/galaxy_files"

BINARY_PATH = Path[__DIR__].parent / "build" / "galaxy-files"

# Run the built binary against the sandbox, with no socket unless a test names
# one.
def run_binary(
  args : Array(String),
  env : Hash(String, String) = {} of String => String,
  chdir : String? = nil,
) : NamedTuple(output: String, error: String, status: Int32)
  raise "Binary not found at #{BINARY_PATH}. Run 'make dev' first." unless File.exists?(BINARY_PATH)

  child_env = Hash(String, String?).new
  child_env["GALAXY_CLAUDE_CONFIG_DIR"] = SPEC_CLAUDE_CONFIG_DIR.to_s
  child_env["GALAXY_DIR"] = SPEC_GALAXY_DIR.to_s
  child_env["GALAXY_LEDGER_BIN"] = SPEC_LEDGER_BIN.to_s
  child_env["GALAXY_SOCKET_PATH"] = (SPEC_ROOT / "absent.sock").to_s
  child_env["GALAXY_FILES_SKIP_CLI"] = nil
  env.each { |key, value| child_env[key] = value }

  process = Process.new(
    BINARY_PATH.to_s,
    args: args,
    output: Process::Redirect::Pipe,
    error: Process::Redirect::Pipe,
    env: child_env,
    chdir: chdir,
  )
  output = process.output.gets_to_end
  error = process.error.gets_to_end
  status = process.wait
  {output: output, error: error, status: status.exit_code}
end

# A one-shot replying socket: accept one connection, hand its request line to
# the channel, write `reply` back, close.
def with_reply_server(reply : String, &)
  path = File.join(Dir.tempdir, "gf-#{Random.rand(1_000_000)}.sock")
  File.delete(path) if File.exists?(path)
  server = UNIXServer.new(path)
  channel = Channel(String).new(1)
  spawn do
    conn = server.accept
    channel.send(conn.gets || "")
    conn.puts(reply)
    conn.close
  rescue ex
    channel.send("ERROR: #{ex.message}")
  end
  begin
    yield path, channel
  ensure
    server.close
    File.delete(path) if File.exists?(path)
  end
end

Spec.after_suite do
  FileUtils.rm_rf(SPEC_ROOT.to_s) if Dir.exists?(SPEC_ROOT)
end
