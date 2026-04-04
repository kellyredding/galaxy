require "../spec_helper"

# Integration tests for the `galaxy backups` command.
# Runs the actual binary against a sandboxed config
# directory with logging stubs for sub-tool binaries.

module BackupTestHelper
  BINARY_PATH = File.expand_path(
    File.join(__DIR__, "../../build/galaxy"),
  )

  # Build a logging stub for a sub-tool binary.
  # Logs full argument list to a file, exits 0.
  # Returns {stub_path, log_path}.
  def self.build_logging_stub(
    name : String,
  ) : {Path, Path}
    log_path = SPEC_GALAXY_DIR / "#{name}_backup.log"
    stub_path = SPEC_GALAXY_DIR / "bin" / name

    Dir.mkdir_p(SPEC_GALAXY_DIR / "bin")
    File.delete(log_path) if File.exists?(log_path)

    File.write(stub_path, <<-BASH)
    #!/bin/bash
    echo "$@" >> "#{log_path}"
    exit 0
    BASH
    File.chmod(stub_path, 0o755)

    {stub_path, log_path}
  end

  # Build a stub that always fails with non-zero exit.
  # Returns {stub_path, log_path}.
  def self.build_failing_stub(
    name : String,
  ) : {Path, Path}
    log_path = SPEC_GALAXY_DIR / "#{name}_backup.log"
    stub_path = SPEC_GALAXY_DIR / "bin" / name

    Dir.mkdir_p(SPEC_GALAXY_DIR / "bin")
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
  def self.read_log(
    log_path : Path,
  ) : Array(String)
    return [] of String unless File.exists?(log_path)
    File.read_lines(log_path).reject(&.empty?)
  end

  def self.run_backups(
    args : Array(String) = [] of String,
    extra_env : Hash(String, String) = {} of String => String,
  ) : {Int32, String, String}
    full_args = ["backups"] + args
    run_binary(full_args, extra_env: extra_env)
  end

  private def self.run_binary(
    args : Array(String),
    extra_env : Hash(String, String) = {} of String => String,
  ) : {Int32, String, String}
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    env = {
      "GALAXY_DIR"         => SPEC_GALAXY_DIR.to_s,
      "CLAUDE_PERSONA_DIR" => SPEC_FIXTURES.to_s,
      "HOME"               => "/tmp/galaxy-spec-no-cp",
      "PATH"               => "",
    }.merge(extra_env)

    status = Process.run(
      BINARY_PATH,
      args: args,
      output: stdout,
      error: stderr,
      env: env,
      clear_env: true,
    )

    {status.exit_code, stdout.to_s, stderr.to_s}
  end

  def self.binary_exists? : Bool
    File.exists?(BINARY_PATH)
  end

  # Write shared config with backups enabled and
  # specified backup directory.
  def self.write_config(
    backup_dir : Path,
    enabled : Bool = true,
    retention_days : Int32 = 3,
  )
    config = Galaxy::SharedConfig.default
    config.backups.enabled = enabled
    config.backups.path = backup_dir.to_s
    config.backups.retention_days = retention_days
    config.save
  end

  # Build all 5 logging stubs. Returns a hash of
  # tool name → {stub_path, log_path}.
  def self.build_all_stubs : Hash(String, {Path, Path})
    result = {} of String => {Path, Path}
    %w[
      galaxy-ledger galaxy-snapshots
      galaxy-artifacts galaxy-timeline
      galaxy-agents
    ].each do |name|
      result[name] = build_logging_stub(name)
    end
    result
  end

  # Env vars pointing to stub paths for all 5 tools.
  def self.stub_env(
    stubs : Hash(String, {Path, Path}),
  ) : Hash(String, String)
    {
      "GALAXY_LEDGER_BIN"    => stubs["galaxy-ledger"][0].to_s,
      "GALAXY_SNAPSHOTS_BIN" => stubs["galaxy-snapshots"][0].to_s,
      "GALAXY_ARTIFACTS_BIN" => stubs["galaxy-artifacts"][0].to_s,
      "GALAXY_TIMELINE_BIN"  => stubs["galaxy-timeline"][0].to_s,
      "GALAXY_AGENTS_BIN"    => stubs["galaxy-agents"][0].to_s,
    }
  end

  # Clean up all log files from stubs.
  def self.cleanup_logs(
    stubs : Hash(String, {Path, Path}),
  )
    stubs.each_value do |_, log_path|
      File.delete(log_path) if File.exists?(log_path)
    end
  end

  # Create fake app data files in the test
  # APP_SUPPORT_DIR.
  def self.create_app_data(
    app_dir : Path,
  )
    Dir.mkdir_p(app_dir)
    File.write(
      app_dir / "sessions.json",
      %({"sessions": []}),
    )
    File.write(
      app_dir / "settings.json",
      %({"theme": "dark"}),
    )
    File.write(
      app_dir / "window-state.json",
      %({"x": 0, "y": 0}),
    )
  end
end

describe "galaxy backups" do
  Spec.before_each do
    config_file = SPEC_GALAXY_DIR / "config.json"
    File.delete(config_file) if File.exists?(config_file)
  end

  describe "help (no subcommand)" do
    it "shows help when called with no args" do
      pending!("Binary not built") unless BackupTestHelper.binary_exists?

      exit_code, stdout, stderr =
        BackupTestHelper.run_backups
      exit_code.should eq(0)
      stderr.should be_empty
      stdout.should contain("galaxy backups")
      stdout.should contain("create")
      stdout.should contain("list")
      stdout.should contain("prune")
      stdout.should contain("--dry-run")
    end

    it "shows help with help subcommand" do
      pending!("Binary not built") unless BackupTestHelper.binary_exists?

      exit_code, stdout, _ =
        BackupTestHelper.run_backups(["help"])
      exit_code.should eq(0)
      stdout.should contain("galaxy backups")
      stdout.should contain("--session-id")
      stdout.should contain("CONFIGURATION")
      stdout.should contain("DESCRIPTION")
    end

    it "shows help with -h flag" do
      pending!("Binary not built") unless BackupTestHelper.binary_exists?

      exit_code, stdout, _ =
        BackupTestHelper.run_backups(["-h"])
      exit_code.should eq(0)
      stdout.should contain("galaxy backups")
    end

    it "shows help with --help flag" do
      pending!("Binary not built") unless BackupTestHelper.binary_exists?

      exit_code, stdout, _ =
        BackupTestHelper.run_backups(["--help"])
      exit_code.should eq(0)
      stdout.should contain("galaxy backups")
    end
  end

  describe "unknown subcommand" do
    it "exits with error for unknown subcommand" do
      pending!("Binary not built") unless BackupTestHelper.binary_exists?

      exit_code, _, stderr =
        BackupTestHelper.run_backups(["bogus"])
      exit_code.should eq(1)
      stderr.should contain(
        "Unknown backups command",
      )
      stderr.should contain("galaxy backups help")
    end
  end

  describe "create" do
    it "invokes all 5 sub-tool backup commands" do
      pending!("Binary not built") unless BackupTestHelper.binary_exists?

      backup_dir = SPEC_GALAXY_DIR / "backups"
      Dir.mkdir_p(backup_dir)
      BackupTestHelper.write_config(backup_dir)

      stubs = BackupTestHelper.build_all_stubs
      app_dir = SPEC_GALAXY_DIR / "app-support"
      BackupTestHelper.create_app_data(app_dir)

      exit_code, stdout, stderr =
        BackupTestHelper.run_backups(
          ["create"],
          extra_env: BackupTestHelper.stub_env(stubs)
            .merge({
              "GALAXY_APP_SUPPORT_DIR" => app_dir.to_s,
            }),
        )
      exit_code.should eq(0)

      # Each tool should have been called with
      # backup --session-id 0
      stubs.each do |name, paths|
        log_path = paths[1]
        lines = BackupTestHelper.read_log(log_path)
        backup_lines = lines.select(&.starts_with?("backup ")
        )
        backup_lines.size.should eq(1)
        backup_lines.first.should contain(
          "--session-id 0",
        )
      end

      # Stdout should show success for each tool
      stdout.should contain("✓ ledger")
      stdout.should contain("✓ snapshots")
      stdout.should contain("✓ artifacts")
      stdout.should contain("✓ timeline")
      stdout.should contain("✓ agents")
      stdout.should contain("5/5 tools")
    ensure
      if stubs
        BackupTestHelper.cleanup_logs(stubs)
      end
    end

    it "defaults to session-id 0 when not specified" do
      pending!("Binary not built") unless BackupTestHelper.binary_exists?

      backup_dir = SPEC_GALAXY_DIR / "backups-sid-default"
      Dir.mkdir_p(backup_dir)
      BackupTestHelper.write_config(backup_dir)

      stubs = BackupTestHelper.build_all_stubs
      app_dir = SPEC_GALAXY_DIR / "app-support-sid-default"
      BackupTestHelper.create_app_data(app_dir)

      exit_code, _, _ =
        BackupTestHelper.run_backups(
          ["create"],
          extra_env: BackupTestHelper.stub_env(stubs)
            .merge({
              "GALAXY_APP_SUPPORT_DIR" => app_dir.to_s,
            }),
        )
      exit_code.should eq(0)

      stubs.each do |name, paths|
        log_path = paths[1]
        lines = BackupTestHelper.read_log(log_path)
        backup_lines = lines.select(&.starts_with?("backup ")
        )
        backup_lines.size.should eq(1)
        backup_lines.first.should contain(
          "--session-id 0",
        )
      end
    ensure
      if stubs
        BackupTestHelper.cleanup_logs(stubs)
      end
    end

    it "passes --session-id value to sub-tools" do
      pending!("Binary not built") unless BackupTestHelper.binary_exists?

      backup_dir = SPEC_GALAXY_DIR / "backups-sid-custom"
      Dir.mkdir_p(backup_dir)
      BackupTestHelper.write_config(backup_dir)

      stubs = BackupTestHelper.build_all_stubs
      app_dir = SPEC_GALAXY_DIR / "app-support-sid-custom"
      BackupTestHelper.create_app_data(app_dir)

      exit_code, _, _ =
        BackupTestHelper.run_backups(
          ["create", "--session-id", "42"],
          extra_env: BackupTestHelper.stub_env(stubs)
            .merge({
              "GALAXY_APP_SUPPORT_DIR" => app_dir.to_s,
            }),
        )
      exit_code.should eq(0)

      stubs.each do |name, paths|
        log_path = paths[1]
        lines = BackupTestHelper.read_log(log_path)
        backup_lines = lines.select(&.starts_with?("backup ")
        )
        backup_lines.size.should eq(1)
        backup_lines.first.should contain(
          "--session-id 42",
        )
      end
    ensure
      if stubs
        BackupTestHelper.cleanup_logs(stubs)
      end
    end

    it "copies app data files into backup dir" do
      pending!("Binary not built") unless BackupTestHelper.binary_exists?

      backup_dir = SPEC_GALAXY_DIR / "backups"
      Dir.mkdir_p(backup_dir)
      BackupTestHelper.write_config(backup_dir)

      stubs = BackupTestHelper.build_all_stubs
      app_dir = SPEC_GALAXY_DIR / "app-support"
      BackupTestHelper.create_app_data(app_dir)

      today = Time.local.to_s("%Y-%m-%d")

      exit_code, stdout, _ =
        BackupTestHelper.run_backups(
          ["create"],
          extra_env: BackupTestHelper.stub_env(stubs)
            .merge({
              "GALAXY_APP_SUPPORT_DIR" => app_dir.to_s,
            }),
        )
      exit_code.should eq(0)

      date_dir = backup_dir / today
      Dir.exists?(date_dir).should be_true

      # Check each app data file was copied
      File.exists?(
        date_dir / "galaxy-app-sessions.json",
      ).should be_true
      File.exists?(
        date_dir / "galaxy-app-settings.json",
      ).should be_true
      File.exists?(
        date_dir / "galaxy-app-window-state.json",
      ).should be_true

      # Verify content matches
      File.read(
        date_dir / "galaxy-app-sessions.json",
      ).should eq(%({"sessions": []}))

      stdout.should contain("3 app files")
    ensure
      if stubs
        BackupTestHelper.cleanup_logs(stubs)
      end
    end

    it "skips missing app data files" do
      pending!("Binary not built") unless BackupTestHelper.binary_exists?

      backup_dir = SPEC_GALAXY_DIR / "backups"
      Dir.mkdir_p(backup_dir)
      BackupTestHelper.write_config(backup_dir)

      stubs = BackupTestHelper.build_all_stubs

      # Create app dir with only one file
      app_dir = SPEC_GALAXY_DIR / "app-support-partial"
      Dir.mkdir_p(app_dir)
      File.write(
        app_dir / "sessions.json",
        "{}",
      )

      exit_code, stdout, _ =
        BackupTestHelper.run_backups(
          ["create"],
          extra_env: BackupTestHelper.stub_env(stubs)
            .merge({
              "GALAXY_APP_SUPPORT_DIR" => app_dir.to_s,
            }),
        )
      exit_code.should eq(0)
      stdout.should contain("1 app files")
    ensure
      if stubs
        BackupTestHelper.cleanup_logs(stubs)
      end
    end

    it "continues when a tool fails" do
      pending!("Binary not built") unless BackupTestHelper.binary_exists?

      backup_dir = SPEC_GALAXY_DIR / "backups"
      Dir.mkdir_p(backup_dir)
      BackupTestHelper.write_config(backup_dir)

      # Make ledger fail, rest succeed
      stubs = BackupTestHelper.build_all_stubs
      ledger_fail_stub, ledger_fail_log =
        BackupTestHelper.build_failing_stub(
          "galaxy-ledger",
        )

      app_dir = SPEC_GALAXY_DIR / "app-support-fail"
      BackupTestHelper.create_app_data(app_dir)

      env = BackupTestHelper.stub_env(stubs).merge({
        "GALAXY_LEDGER_BIN"      => ledger_fail_stub.to_s,
        "GALAXY_APP_SUPPORT_DIR" => app_dir.to_s,
      })

      exit_code, stdout, stderr =
        BackupTestHelper.run_backups(
          ["create"],
          extra_env: env,
        )

      # Should exit non-zero due to failure
      exit_code.should eq(1)

      # Ledger should show failure
      stderr.should contain("✗ ledger")

      # Other tools should still have run
      stdout.should contain("✓ snapshots")
      stdout.should contain("✓ artifacts")
      stdout.should contain("✓ timeline")
      stdout.should contain("✓ agents")

      # Summary should show partial success
      stdout.should contain("4/5 tools")
      stdout.should contain("Failures:")
    ensure
      if stubs
        BackupTestHelper.cleanup_logs(stubs)
      end
      if ledger_fail_log
        File.delete(ledger_fail_log) if File.exists?(ledger_fail_log)
      end
    end

    it "shows disabled message when backups disabled" do
      pending!("Binary not built") unless BackupTestHelper.binary_exists?

      backup_dir = SPEC_GALAXY_DIR / "backups"
      BackupTestHelper.write_config(
        backup_dir, enabled: false)

      exit_code, stdout, _ =
        BackupTestHelper.run_backups(["create"])
      exit_code.should eq(0)
      stdout.should contain("Backups are disabled")
      stdout.should contain("backups.enabled true")
    end

    describe "--dry-run" do
      it "shows what would be backed up" do
        pending!("Binary not built") unless BackupTestHelper.binary_exists?

        backup_dir = SPEC_GALAXY_DIR / "backups"
        Dir.mkdir_p(backup_dir)
        BackupTestHelper.write_config(backup_dir)

        stubs = BackupTestHelper.build_all_stubs
        app_dir = SPEC_GALAXY_DIR / "app-support-dry"
        BackupTestHelper.create_app_data(app_dir)

        exit_code, stdout, _ =
          BackupTestHelper.run_backups(
            ["create", "--dry-run"],
            extra_env: BackupTestHelper.stub_env(stubs)
              .merge({
                "GALAXY_APP_SUPPORT_DIR" => app_dir.to_s,
              }),
          )
        exit_code.should eq(0)
        stdout.should contain("Dry run")
        stdout.should contain("Backup directory:")
        stdout.should contain("Tool backups:")
        stdout.should contain(
          "backup --session-id 0",
        )
        stdout.should contain("App data copies:")
        stdout.should contain("galaxy-app-sessions.json")
        stdout.should contain("galaxy-app-settings.json")
        stdout.should contain(
          "galaxy-app-window-state.json",
        )
      ensure
        if stubs
          BackupTestHelper.cleanup_logs(stubs)
        end
      end

      it "shows session-id 0 by default in dry run" do
        pending!("Binary not built") unless BackupTestHelper.binary_exists?

        backup_dir = SPEC_GALAXY_DIR / "backups"
        Dir.mkdir_p(backup_dir)
        BackupTestHelper.write_config(backup_dir)

        stubs = BackupTestHelper.build_all_stubs
        app_dir = SPEC_GALAXY_DIR / "app-support-dry-sid0"
        BackupTestHelper.create_app_data(app_dir)

        exit_code, stdout, _ =
          BackupTestHelper.run_backups(
            ["create", "--dry-run"],
            extra_env: BackupTestHelper.stub_env(stubs)
              .merge({
                "GALAXY_APP_SUPPORT_DIR" => app_dir.to_s,
              }),
          )
        exit_code.should eq(0)
        stdout.should contain(
          "backup --session-id 0",
        )
      ensure
        if stubs
          BackupTestHelper.cleanup_logs(stubs)
        end
      end

      it "shows custom session-id in dry run" do
        pending!("Binary not built") unless BackupTestHelper.binary_exists?

        backup_dir = SPEC_GALAXY_DIR / "backups"
        Dir.mkdir_p(backup_dir)
        BackupTestHelper.write_config(backup_dir)

        stubs = BackupTestHelper.build_all_stubs
        app_dir = SPEC_GALAXY_DIR / "app-support-dry-sid42"
        BackupTestHelper.create_app_data(app_dir)

        exit_code, stdout, _ =
          BackupTestHelper.run_backups(
            ["create", "--session-id", "42",
             "--dry-run"],
            extra_env: BackupTestHelper.stub_env(stubs)
              .merge({
                "GALAXY_APP_SUPPORT_DIR" => app_dir.to_s,
              }),
          )
        exit_code.should eq(0)
        stdout.should contain(
          "backup --session-id 42",
        )
        stdout.should_not contain(
          "backup --session-id 0",
        )
      ensure
        if stubs
          BackupTestHelper.cleanup_logs(stubs)
        end
      end

      it "does not invoke any sub-tool binaries" do
        pending!("Binary not built") unless BackupTestHelper.binary_exists?

        backup_dir = SPEC_GALAXY_DIR / "backups"
        Dir.mkdir_p(backup_dir)
        BackupTestHelper.write_config(backup_dir)

        stubs = BackupTestHelper.build_all_stubs
        app_dir = SPEC_GALAXY_DIR / "app-support-dry2"
        Dir.mkdir_p(app_dir)

        exit_code, _, _ =
          BackupTestHelper.run_backups(
            ["create", "--dry-run"],
            extra_env: BackupTestHelper.stub_env(stubs)
              .merge({
                "GALAXY_APP_SUPPORT_DIR" => app_dir.to_s,
              }),
          )
        exit_code.should eq(0)

        # No stubs should have been invoked
        stubs.each do |name, paths|
          log_path = paths[1]
          lines = BackupTestHelper.read_log(log_path)
          lines.should be_empty
        end
      ensure
        if stubs
          BackupTestHelper.cleanup_logs(stubs)
        end
      end

      it "shows skip for missing app data files" do
        pending!("Binary not built") unless BackupTestHelper.binary_exists?

        backup_dir = SPEC_GALAXY_DIR / "backups"
        Dir.mkdir_p(backup_dir)
        BackupTestHelper.write_config(backup_dir)

        stubs = BackupTestHelper.build_all_stubs

        # Empty app dir — no files
        app_dir = SPEC_GALAXY_DIR / "app-support-empty"
        Dir.mkdir_p(app_dir)

        exit_code, stdout, _ =
          BackupTestHelper.run_backups(
            ["create", "--dry-run"],
            extra_env: BackupTestHelper.stub_env(stubs)
              .merge({
                "GALAXY_APP_SUPPORT_DIR" => app_dir.to_s,
              }),
          )
        exit_code.should eq(0)
        stdout.should contain("skip: not found")
      ensure
        if stubs
          BackupTestHelper.cleanup_logs(stubs)
        end
      end

      it "still shows disabled message" do
        pending!("Binary not built") unless BackupTestHelper.binary_exists?

        backup_dir = SPEC_GALAXY_DIR / "backups"
        BackupTestHelper.write_config(
          backup_dir, enabled: false)

        exit_code, stdout, _ =
          BackupTestHelper.run_backups(
            ["create", "--dry-run"],
          )
        exit_code.should eq(0)
        stdout.should contain("Backups are disabled")
      end
    end
  end

  describe "list" do
    it "shows no backups message when dir empty" do
      pending!("Binary not built") unless BackupTestHelper.binary_exists?

      backup_dir = SPEC_GALAXY_DIR / "backups-list"
      Dir.mkdir_p(backup_dir)
      BackupTestHelper.write_config(backup_dir)

      exit_code, stdout, _ =
        BackupTestHelper.run_backups(["list"])
      exit_code.should eq(0)
      stdout.should contain("No backups found")
    end

    it "shows no backups when dir does not exist" do
      pending!("Binary not built") unless BackupTestHelper.binary_exists?

      backup_dir = SPEC_GALAXY_DIR / "nonexistent-dir"
      BackupTestHelper.write_config(backup_dir)

      exit_code, stdout, _ =
        BackupTestHelper.run_backups(["list"])
      exit_code.should eq(0)
      stdout.should contain("No backups found")
    end

    it "lists backups grouped by date" do
      pending!("Binary not built") unless BackupTestHelper.binary_exists?

      backup_dir = SPEC_GALAXY_DIR / "backups-list2"
      date_dir = backup_dir / "2026-04-04"
      Dir.mkdir_p(date_dir)

      # Create some fake backup files
      File.write(
        date_dir / "ledger-1.db", "x" * 1024,
      )
      File.write(
        date_dir / "galaxy-app-sessions.json", "{}",
      )

      BackupTestHelper.write_config(backup_dir)

      exit_code, stdout, _ =
        BackupTestHelper.run_backups(["list"])
      exit_code.should eq(0)
      stdout.should contain("2026-04-04")
      stdout.should contain("ledger-1.db")
      stdout.should contain(
        "galaxy-app-sessions.json",
      )
      stdout.should contain("2 files")
      stdout.should contain("retention:")
    end

    it "shows multiple date directories" do
      pending!("Binary not built") unless BackupTestHelper.binary_exists?

      backup_dir = SPEC_GALAXY_DIR / "backups-list3"
      Dir.mkdir_p(backup_dir / "2026-04-03")
      Dir.mkdir_p(backup_dir / "2026-04-04")

      File.write(
        backup_dir / "2026-04-03" / "old.db",
        "old",
      )
      File.write(
        backup_dir / "2026-04-04" / "new.db",
        "new",
      )

      BackupTestHelper.write_config(backup_dir)

      exit_code, stdout, _ =
        BackupTestHelper.run_backups(["list"])
      exit_code.should eq(0)

      # Chronological order (oldest first)
      stdout.index("2026-04-03").not_nil!.should be < (
        stdout.index("2026-04-04").not_nil!
      )
    end
  end

  describe "prune" do
    it "invokes prune on all 5 sub-tools" do
      pending!("Binary not built") unless BackupTestHelper.binary_exists?

      backup_dir = SPEC_GALAXY_DIR / "backups-prune"
      Dir.mkdir_p(backup_dir)
      BackupTestHelper.write_config(backup_dir)

      stubs = BackupTestHelper.build_all_stubs

      exit_code, stdout, _ =
        BackupTestHelper.run_backups(
          ["prune"],
          extra_env: BackupTestHelper.stub_env(stubs),
        )
      exit_code.should eq(0)

      stubs.each do |name, paths|
        log_path = paths[1]
        lines = BackupTestHelper.read_log(log_path)
        prune_lines = lines.select(&.starts_with?("backup ")
        )
        prune_lines.size.should eq(1)
        prune_lines.first.should contain(
          "--prune-only",
        )
      end

      stdout.should contain("✓ ledger: pruned")
      stdout.should contain("✓ snapshots: pruned")
      stdout.should contain("Prune complete")
    ensure
      if stubs
        BackupTestHelper.cleanup_logs(stubs)
      end
    end

    it "removes stale date dirs with only json files" do
      pending!("Binary not built") unless BackupTestHelper.binary_exists?

      backup_dir = SPEC_GALAXY_DIR / "backups-prune2"
      old_date = (Time.local - 10.days).to_s(
        "%Y-%m-%d",
      )
      old_dir = backup_dir / old_date
      Dir.mkdir_p(old_dir)

      # Only app data json — no .db files
      File.write(
        old_dir / "galaxy-app-sessions.json", "{}",
      )

      BackupTestHelper.write_config(
        backup_dir, retention_days: 3)

      stubs = BackupTestHelper.build_all_stubs

      exit_code, _, _ =
        BackupTestHelper.run_backups(
          ["prune"],
          extra_env: BackupTestHelper.stub_env(stubs),
        )
      exit_code.should eq(0)

      # Old directory should be gone
      Dir.exists?(old_dir).should be_false
    ensure
      if stubs
        BackupTestHelper.cleanup_logs(stubs)
      end
    end

    it "preserves recent date dirs" do
      pending!("Binary not built") unless BackupTestHelper.binary_exists?

      backup_dir = SPEC_GALAXY_DIR / "backups-prune3"
      today = Time.local.to_s("%Y-%m-%d")
      today_dir = backup_dir / today
      Dir.mkdir_p(today_dir)
      File.write(
        today_dir / "galaxy-app-sessions.json", "{}",
      )

      BackupTestHelper.write_config(
        backup_dir, retention_days: 3)

      stubs = BackupTestHelper.build_all_stubs

      exit_code, _, _ =
        BackupTestHelper.run_backups(
          ["prune"],
          extra_env: BackupTestHelper.stub_env(stubs),
        )
      exit_code.should eq(0)

      # Today's directory should still exist
      Dir.exists?(today_dir).should be_true
    ensure
      if stubs
        BackupTestHelper.cleanup_logs(stubs)
      end
    end

    it "shows disabled message when backups disabled" do
      pending!("Binary not built") unless BackupTestHelper.binary_exists?

      backup_dir = SPEC_GALAXY_DIR / "backups"
      BackupTestHelper.write_config(
        backup_dir, enabled: false)

      exit_code, stdout, _ =
        BackupTestHelper.run_backups(["prune"])
      exit_code.should eq(0)
      stdout.should contain("Backups are disabled")
    end
  end
end
