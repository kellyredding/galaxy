require "../spec_helper"

# Integration tests for on-startup backup behavior.
# Verifies that a fresh session triggers both ledger's own
# backup and sibling tool backups via their CLI binaries.
#
# Uses logging stub scripts that record invocation args to
# temp files, allowing assertions on what was called and
# with what arguments.

# Build a logging stub for a sibling tool binary. The stub
# logs its full argument list to a file, then exits 0.
# Returns {stub_path, log_path}.
private def build_backup_logging_stub(
  name : String,
) : {Path, Path}
  log_path = SPEC_GALAXY_DIR / "#{name}_backup.log"
  stub_path = SPEC_GALAXY_DIR / "bin" / name

  # Clear any stale log from a previous test — logging
  # stubs persist on disk and append, so leftover entries
  # from earlier tests would corrupt assertions.
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
private def build_failing_backup_stub(
  name : String,
) : {Path, Path}
  log_path = SPEC_GALAXY_DIR / "#{name}_backup.log"
  stub_path = SPEC_GALAXY_DIR / "bin" / name

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

# Restore all sibling tool stubs to no-ops so logging
# stubs don't leak into other test files that rely on
# the default no-op behavior from spec_helper.
private def restore_noop_stubs
  {SPEC_TIMELINE_NOOP, SPEC_AGENTS_NOOP,
   SPEC_SNAPSHOTS_NOOP, SPEC_ARTIFACTS_NOOP}.each do |path|
    File.write(path, "#!/bin/sh\nexit 0\n")
    File.chmod(path, 0o755)
  end
end

# Write a config with backups enabled. The backup_path
# must be a real writable directory so the ledger's own
# VACUUM INTO succeeds.
private def write_backup_config(backup_dir : Path)
  config = GalaxyLedger::Config.default
  config.backups.enabled = true
  config.backups.path = backup_dir.to_s
  config.extraction.on_stop = false
  config.extraction.on_guideline_read = false
  File.write(
    SPEC_CONFIG_DIR / "config.json",
    config.to_pretty_json,
  )
end

describe "Backup integration: on-startup" do
  describe "fresh session with backups enabled" do
    it "invokes backup on all sibling tools" do
      # Build logging stubs for each sibling tool
      snap_stub, snap_log = build_backup_logging_stub(
        "galaxy-snapshots",
      )
      art_stub, art_log = build_backup_logging_stub(
        "galaxy-artifacts",
      )
      tl_stub, tl_log = build_backup_logging_stub(
        "galaxy-timeline",
      )
      agent_stub, agent_log = build_backup_logging_stub(
        "galaxy-agents",
      )

      # Set up backup directory and enable backups
      backup_dir = SPEC_GALAXY_DIR / "backups" / "ledger"
      Dir.mkdir_p(backup_dir)
      write_backup_config(backup_dir)

      session_id = "backup-int-#{Random.rand(100000)}"
      hook_input = {"session_id" => session_id}.to_json

      result = run_binary(
        ["on-startup"],
        stdin: hook_input,
        extra_env: {
          "GALAXY_SNAPSHOTS_BIN" => snap_stub.to_s,
          "GALAXY_ARTIFACTS_BIN" => art_stub.to_s,
          "GALAXY_TIMELINE_BIN"  => tl_stub.to_s,
          "GALAXY_AGENTS_BIN"    => agent_stub.to_s,
        },
      )
      result[:status].should eq(0)

      # Each sibling should have been called with
      # "backup --session-id <N>". Match on the leading
      # "backup" subcommand, not just the word appearing
      # anywhere (session IDs and detail_data can contain
      # "backup" as a substring).
      {snap_log, art_log, tl_log, agent_log}.each do |log|
        lines = read_backup_log(log)
        backup_lines = lines.select(&.starts_with?("backup ")
        )
        backup_lines.size.should eq(1)
        backup_lines.first.should contain("--session-id")
      end
    ensure
      {snap_log, art_log, tl_log, agent_log}.each do |log|
        if log
          File.delete(log) if File.exists?(log)
        end
      end
      restore_noop_stubs
    end

    it "passes the ledger session ID to sibling tools" do
      snap_stub, snap_log = build_backup_logging_stub(
        "galaxy-snapshots",
      )

      backup_dir = SPEC_GALAXY_DIR / "backups" / "ledger"
      Dir.mkdir_p(backup_dir)
      write_backup_config(backup_dir)

      session_id = "backup-sid-#{Random.rand(100000)}"
      hook_input = {"session_id" => session_id}.to_json

      result = run_binary(
        ["on-startup"],
        stdin: hook_input,
        extra_env: {
          "GALAXY_SNAPSHOTS_BIN" => snap_stub.to_s,
        },
      )
      result[:status].should eq(0)

      # Resolve the ledger session ID that was created
      ledger_id = GalaxyLedger::Database
        .resolve_session_identifier(session_id)
      ledger_id.should_not be_nil

      lines = read_backup_log(snap_log)
      backup_line = lines.find(&.includes?("backup"))
      backup_line.should_not be_nil
      backup_line.not_nil!.should contain(
        "--session-id #{ledger_id}",
      )
    ensure
      File.delete(snap_log) if snap_log && File.exists?(snap_log)
      restore_noop_stubs
    end
  end

  describe "sibling backup failure" do
    it "does not crash the hook when a sibling fails" do
      # One stub succeeds, one fails
      snap_stub, snap_log = build_failing_backup_stub(
        "galaxy-snapshots",
      )
      art_stub, art_log = build_backup_logging_stub(
        "galaxy-artifacts",
      )
      tl_stub, tl_log = build_backup_logging_stub(
        "galaxy-timeline",
      )
      agent_stub, agent_log = build_backup_logging_stub(
        "galaxy-agents",
      )

      backup_dir = SPEC_GALAXY_DIR / "backups" / "ledger"
      Dir.mkdir_p(backup_dir)
      write_backup_config(backup_dir)

      session_id = "backup-fail-#{Random.rand(100000)}"
      hook_input = {"session_id" => session_id}.to_json

      result = run_binary(
        ["on-startup"],
        stdin: hook_input,
        extra_env: {
          "GALAXY_SNAPSHOTS_BIN" => snap_stub.to_s,
          "GALAXY_ARTIFACTS_BIN" => art_stub.to_s,
          "GALAXY_TIMELINE_BIN"  => tl_stub.to_s,
          "GALAXY_AGENTS_BIN"    => agent_stub.to_s,
        },
      )

      # Hook should still succeed
      result[:status].should eq(0)

      # Session should have been created despite failure
      ledger_id = GalaxyLedger::Database
        .resolve_session_identifier(session_id)
      ledger_id.should_not be_nil

      # The failing tool was still invoked
      snap_lines = read_backup_log(snap_log).select(&.starts_with?("backup ")
      )
      snap_lines.size.should eq(1)

      # The other tools were still invoked after the
      # failure (not short-circuited)
      {art_log, tl_log, agent_log}.each do |log|
        lines = read_backup_log(log).select(&.starts_with?("backup ")
        )
        lines.size.should eq(1)
      end

      # Stderr should contain the failure message
      result[:error].should contain("backup failed")
    ensure
      {snap_log, art_log, tl_log, agent_log}.each do |log|
        if log
          File.delete(log) if File.exists?(log)
        end
      end
      restore_noop_stubs
    end
  end

  describe "resume scenario (no backups)" do
    it "does not invoke sibling backups on resume" do
      snap_stub, snap_log = build_backup_logging_stub(
        "galaxy-snapshots",
      )

      backup_dir = SPEC_GALAXY_DIR / "backups" / "ledger"
      Dir.mkdir_p(backup_dir)
      write_backup_config(backup_dir)

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

      # Run on-startup with the env var matching — this is
      # a resume, so no backups should fire.
      new_session_id = "backup-resume-new-#{Random.rand(100000)}"
      hook_input = {"session_id" => new_session_id}.to_json

      result = run_binary(
        ["on-startup"],
        stdin: hook_input,
        extra_env: {
          "CLAUDE_CLI_SESSION_ID" => env_id,
          "GALAXY_SNAPSHOTS_BIN"  => snap_stub.to_s,
        },
      )
      result[:status].should eq(0)

      # No backup invocations should have happened
      lines = read_backup_log(snap_log)
      backup_lines = lines.select(&.starts_with?("backup ")
      )
      backup_lines.should be_empty
    ensure
      File.delete(snap_log) if snap_log && File.exists?(snap_log)
      restore_noop_stubs
    end
  end

  describe "ledger's own backup" do
    it "creates a backup file on fresh session" do
      backup_dir = SPEC_GALAXY_DIR / "backups" / "ledger"
      Dir.mkdir_p(backup_dir)
      write_backup_config(backup_dir)

      session_id = "backup-own-#{Random.rand(100000)}"
      hook_input = {"session_id" => session_id}.to_json

      result = run_binary(["on-startup"], stdin: hook_input)
      result[:status].should eq(0)

      # Should have created a date-based backup directory
      # with a .db file inside
      entries = Dir.children(backup_dir)
      entries.should_not be_empty

      # Find the backup file (YYYY-MM-DD/ledger-<id>.db)
      found_backup = false
      entries.each do |date_dir|
        full_dir = backup_dir / date_dir
        next unless Dir.exists?(full_dir)
        Dir.children(full_dir).each do |f|
          if f.ends_with?(".db")
            found_backup = true
          end
        end
      end
      found_backup.should be_true
    end
  end
end
