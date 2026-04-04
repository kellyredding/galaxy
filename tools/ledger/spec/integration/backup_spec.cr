require "../spec_helper"

# Integration tests for on-startup backup behavior.
# Verifies that a fresh session delegates backup orchestration
# to the Galaxy CLI via `galaxy backups create --session-id <id>`.
#
# Uses a logging stub script that records invocation args to a
# temp file, allowing assertions on what was called and with
# what arguments.

# Build a logging stub for the galaxy binary. The stub logs its
# full argument list to a file, then exits 0.
# Returns {stub_path, log_path}.
private def build_galaxy_logging_stub : {Path, Path}
  log_path = SPEC_GALAXY_DIR / "galaxy_backup.log"
  stub_path = SPEC_GALAXY_DIR / "bin" / "galaxy"

  # Clear any stale log from a previous test.
  File.delete(log_path) if File.exists?(log_path)

  File.write(stub_path, <<-BASH)
  #!/bin/bash
  echo "$@" >> "#{log_path}"
  exit 0
  BASH
  File.chmod(stub_path, 0o755)

  {stub_path, log_path}
end

# Build a stub that always fails with a non-zero exit and
# writes to stderr. Returns {stub_path, log_path}.
private def build_failing_galaxy_stub : {Path, Path}
  log_path = SPEC_GALAXY_DIR / "galaxy_backup.log"
  stub_path = SPEC_GALAXY_DIR / "bin" / "galaxy"

  File.delete(log_path) if File.exists?(log_path)

  File.write(stub_path, <<-BASH)
  #!/bin/bash
  echo "$@" >> "#{log_path}"
  echo "simulated failure" >&2
  exit 1
  BASH
  File.chmod(stub_path, 0o755)

  {stub_path, log_path}
end

# Read log lines from a stub's log file.
private def read_backup_log(
  log_path : Path,
) : Array(String)
  return [] of String unless File.exists?(log_path)
  File.read_lines(log_path).reject(&.empty?)
end

# Restore the galaxy stub to a no-op so logging stubs don't
# leak into other test files.
private def restore_galaxy_noop
  File.write(SPEC_GALAXY_NOOP, "#!/bin/sh\nexit 0\n")
  File.chmod(SPEC_GALAXY_NOOP, 0o755)
end

describe "Backup integration: on-startup" do
  describe "fresh session backup delegation" do
    it "invokes galaxy backups create with session ID" do
      stub_path, log_path = build_galaxy_logging_stub

      session_id = "backup-int-#{Random.rand(100000)}"
      hook_input = {"session_id" => session_id}.to_json

      result = run_binary(
        ["on-startup"],
        stdin: hook_input,
        extra_env: {
          "GALAXY_BIN" => stub_path.to_s,
        },
      )
      result[:status].should eq(0)

      # Resolve the ledger session ID that was created
      ledger_id = GalaxyLedger::Database
        .resolve_session_identifier(session_id)
      ledger_id.should_not be_nil

      lines = read_backup_log(log_path)
      backup_lines = lines.select(&.starts_with?("backups "))
      backup_lines.size.should eq(1)
      backup_lines.first.should eq(
        "backups create --session-id #{ledger_id}",
      )
    ensure
      File.delete(log_path) if log_path && File.exists?(log_path)
      restore_galaxy_noop
    end
  end

  describe "backup failure" do
    it "does not crash the hook when galaxy backups create fails" do
      stub_path, log_path = build_failing_galaxy_stub

      session_id = "backup-fail-#{Random.rand(100000)}"
      hook_input = {"session_id" => session_id}.to_json

      result = run_binary(
        ["on-startup"],
        stdin: hook_input,
        extra_env: {
          "GALAXY_BIN" => stub_path.to_s,
        },
      )

      # Hook should still succeed
      result[:status].should eq(0)

      # Session should have been created despite failure
      ledger_id = GalaxyLedger::Database
        .resolve_session_identifier(session_id)
      ledger_id.should_not be_nil

      # The galaxy binary was still invoked
      lines = read_backup_log(log_path).select(&.starts_with?("backups "))
      lines.size.should eq(1)

      # Stderr should contain the failure message
      result[:error].should contain("Backup failed")
    ensure
      File.delete(log_path) if log_path && File.exists?(log_path)
      restore_galaxy_noop
    end
  end

  describe "resume scenario (no backups)" do
    it "does not invoke galaxy backups create on resume" do
      stub_path, log_path = build_galaxy_logging_stub

      # Create an existing session with a registered env ID
      env_id = "backup-resume-env-#{Random.rand(100000)}"
      old_session_id = "backup-resume-old-#{Random.rand(100000)}"
      old_ledger_id = GalaxyLedger::Database.create_session(
        old_session_id,
      )
      GalaxyLedger::Database.register_session_identifier(
        old_ledger_id, env_id,
      )
      flush_wal

      # Run on-startup with the env var matching -- this is
      # a resume, so no backups should fire.
      new_session_id = "backup-resume-new-#{Random.rand(100000)}"
      hook_input = {"session_id" => new_session_id}.to_json

      result = run_binary(
        ["on-startup"],
        stdin: hook_input,
        extra_env: {
          "CLAUDE_CLI_SESSION_ID" => env_id,
          "GALAXY_BIN"            => stub_path.to_s,
        },
      )
      result[:status].should eq(0)

      # No backup invocations should have happened
      lines = read_backup_log(log_path)
      backup_lines = lines.select(&.starts_with?("backups "))
      backup_lines.should be_empty
    ensure
      File.delete(log_path) if log_path && File.exists?(log_path)
      restore_galaxy_noop
    end
  end
end
