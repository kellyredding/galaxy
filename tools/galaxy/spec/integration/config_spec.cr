require "../spec_helper"

# Integration tests for the `galaxy config` command.
# Runs the actual binary against a sandboxed config
# directory to verify end-to-end CLI behavior.

module ConfigTestHelper
  BINARY_PATH = File.expand_path(
    File.join(__DIR__, "../../build/galaxy"),
  )

  def self.run_config(
    args : Array(String) = [] of String,
  ) : {Int32, String, String}
    full_args = ["config"] + args
    run_binary(full_args)
  end

  private def self.run_binary(
    args : Array(String),
  ) : {Int32, String, String}
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    env = {
      "GALAXY_DIR"         => SPEC_GALAXY_DIR.to_s,
      "CLAUDE_PERSONA_DIR" => SPEC_FIXTURES.to_s,
      "HOME"               => "/tmp/galaxy-spec-no-cp",
      "PATH"               => "",
    }

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

  # Reset config to defaults between tests
  def self.reset_config
    config_file = SPEC_GALAXY_DIR / "config.json"
    File.delete(config_file) if File.exists?(config_file)
  end
end

describe "galaxy config" do
  Spec.before_each do
    ConfigTestHelper.reset_config
  end

  describe "show (no subcommand)" do
    it "displays config as JSON" do
      pending!("Binary not built") unless ConfigTestHelper.binary_exists?

      exit_code, stdout, stderr = ConfigTestHelper.run_config
      exit_code.should eq(0)
      stderr.should be_empty

      parsed = JSON.parse(stdout)
      parsed["_schema_version"].as_s.should_not be_empty
      parsed["backups"]["enabled"].as_bool.should be_true
      parsed["backups"]["retention_days"].as_i.should eq(3)
      parsed["backups"]["path"].as_s.should eq("")
    end

    it "creates config file if missing" do
      pending!("Binary not built") unless ConfigTestHelper.binary_exists?

      config_file = SPEC_GALAXY_DIR / "config.json"
      File.exists?(config_file).should be_false

      exit_code, _, _ = ConfigTestHelper.run_config
      exit_code.should eq(0)

      File.exists?(config_file).should be_true
    end
  end

  describe "help" do
    it "shows config documentation" do
      pending!("Binary not built") unless ConfigTestHelper.binary_exists?

      exit_code, stdout, stderr = ConfigTestHelper.run_config(
        ["help"],
      )
      exit_code.should eq(0)
      stderr.should be_empty
      stdout.should contain("galaxy config")
      stdout.should contain("AVAILABLE SETTINGS")
      stdout.should contain("backups.enabled")
      stdout.should contain("backups.retention_days")
      stdout.should contain("backups.path")
    end

    it "shows help with -h flag" do
      pending!("Binary not built") unless ConfigTestHelper.binary_exists?

      exit_code, stdout, _ = ConfigTestHelper.run_config(["-h"])
      exit_code.should eq(0)
      stdout.should contain("galaxy config")
    end

    it "shows help with --help flag" do
      pending!("Binary not built") unless ConfigTestHelper.binary_exists?

      exit_code, stdout, _ = ConfigTestHelper.run_config(
        ["--help"],
      )
      exit_code.should eq(0)
      stdout.should contain("galaxy config")
    end
  end

  describe "set" do
    it "sets backups.enabled to false" do
      pending!("Binary not built") unless ConfigTestHelper.binary_exists?

      exit_code, stdout, stderr = ConfigTestHelper.run_config(
        ["set", "backups.enabled", "false"],
      )
      exit_code.should eq(0)
      stderr.should be_empty
      stdout.should contain("Set backups.enabled = false")

      # Verify it persisted
      exit_code, stdout, _ = ConfigTestHelper.run_config(
        ["get", "backups.enabled"],
      )
      exit_code.should eq(0)
      stdout.strip.should eq("false")
    end

    it "sets backups.retention_days" do
      pending!("Binary not built") unless ConfigTestHelper.binary_exists?

      exit_code, stdout, _ = ConfigTestHelper.run_config(
        ["set", "backups.retention_days", "14"],
      )
      exit_code.should eq(0)
      stdout.should contain("Set backups.retention_days = 14")

      exit_code, stdout, _ = ConfigTestHelper.run_config(
        ["get", "backups.retention_days"],
      )
      stdout.strip.should eq("14")
    end

    it "sets backups.path" do
      pending!("Binary not built") unless ConfigTestHelper.binary_exists?

      exit_code, stdout, _ = ConfigTestHelper.run_config(
        ["set", "backups.path", "/custom/path"],
      )
      exit_code.should eq(0)
      stdout.should contain("Set backups.path = /custom/path")

      exit_code, stdout, _ = ConfigTestHelper.run_config(
        ["get", "backups.path"],
      )
      stdout.strip.should eq("/custom/path")
    end

    it "fails for unknown key" do
      pending!("Binary not built") unless ConfigTestHelper.binary_exists?

      exit_code, _, stderr = ConfigTestHelper.run_config(
        ["set", "nonexistent.key", "value"],
      )
      exit_code.should eq(1)
      stderr.should contain("Error:")
    end

    it "fails for invalid boolean" do
      pending!("Binary not built") unless ConfigTestHelper.binary_exists?

      exit_code, _, stderr = ConfigTestHelper.run_config(
        ["set", "backups.enabled", "maybe"],
      )
      exit_code.should eq(1)
      stderr.should contain("Error:")
    end

    it "fails for non-integer retention_days" do
      pending!("Binary not built") unless ConfigTestHelper.binary_exists?

      exit_code, _, stderr = ConfigTestHelper.run_config(
        ["set", "backups.retention_days", "abc"],
      )
      exit_code.should eq(1)
      stderr.should contain("Error:")
    end

    it "fails for retention_days < 1" do
      pending!("Binary not built") unless ConfigTestHelper.binary_exists?

      exit_code, _, stderr = ConfigTestHelper.run_config(
        ["set", "backups.retention_days", "0"],
      )
      exit_code.should eq(1)
      stderr.should contain("Error:")
    end

    it "fails with missing arguments" do
      pending!("Binary not built") unless ConfigTestHelper.binary_exists?

      exit_code, _, stderr = ConfigTestHelper.run_config(
        ["set", "backups.enabled"],
      )
      exit_code.should eq(1)
      stderr.should contain("Usage:")
    end
  end

  describe "get" do
    it "gets backups.enabled" do
      pending!("Binary not built") unless ConfigTestHelper.binary_exists?

      exit_code, stdout, stderr = ConfigTestHelper.run_config(
        ["get", "backups.enabled"],
      )
      exit_code.should eq(0)
      stderr.should be_empty
      stdout.strip.should eq("true")
    end

    it "gets backups.retention_days" do
      pending!("Binary not built") unless ConfigTestHelper.binary_exists?

      exit_code, stdout, _ = ConfigTestHelper.run_config(
        ["get", "backups.retention_days"],
      )
      exit_code.should eq(0)
      stdout.strip.should eq("3")
    end

    it "gets backups.path (empty default)" do
      pending!("Binary not built") unless ConfigTestHelper.binary_exists?

      exit_code, stdout, _ = ConfigTestHelper.run_config(
        ["get", "backups.path"],
      )
      exit_code.should eq(0)
      stdout.strip.should eq("")
    end

    it "fails for unknown key" do
      pending!("Binary not built") unless ConfigTestHelper.binary_exists?

      exit_code, _, stderr = ConfigTestHelper.run_config(
        ["get", "nonexistent.key"],
      )
      exit_code.should eq(1)
      stderr.should contain("Error:")
    end

    it "fails with missing arguments" do
      pending!("Binary not built") unless ConfigTestHelper.binary_exists?

      exit_code, _, stderr = ConfigTestHelper.run_config(
        ["get"],
      )
      exit_code.should eq(1)
      stderr.should contain("Usage:")
    end
  end

  describe "reset" do
    it "resets config to defaults" do
      pending!("Binary not built") unless ConfigTestHelper.binary_exists?

      # First change something
      ConfigTestHelper.run_config(
        ["set", "backups.retention_days", "30"],
      )

      # Then reset
      exit_code, stdout, stderr = ConfigTestHelper.run_config(
        ["reset"],
      )
      exit_code.should eq(0)
      stderr.should be_empty
      stdout.should contain("Configuration reset to defaults")

      # Verify defaults restored
      exit_code, stdout, _ = ConfigTestHelper.run_config(
        ["get", "backups.retention_days"],
      )
      stdout.strip.should eq("3")
    end
  end

  describe "path" do
    it "shows config file location" do
      pending!("Binary not built") unless ConfigTestHelper.binary_exists?

      exit_code, stdout, stderr = ConfigTestHelper.run_config(
        ["path"],
      )
      exit_code.should eq(0)
      stderr.should be_empty
      stdout.strip.should contain("config.json")
    end
  end

  describe "unknown subcommand" do
    it "shows error for unknown config subcommand" do
      pending!("Binary not built") unless ConfigTestHelper.binary_exists?

      exit_code, _, stderr = ConfigTestHelper.run_config(
        ["nonexistent"],
      )
      exit_code.should eq(1)
      stderr.should contain("Unknown config command")
    end
  end

  describe "set then show round-trip" do
    it "reflects changes in config output" do
      pending!("Binary not built") unless ConfigTestHelper.binary_exists?

      # Set multiple values
      ConfigTestHelper.run_config(
        ["set", "backups.enabled", "false"],
      )
      ConfigTestHelper.run_config(
        ["set", "backups.retention_days", "7"],
      )
      ConfigTestHelper.run_config(
        ["set", "backups.path", "/my/backups"],
      )

      # Show should reflect all changes
      exit_code, stdout, _ = ConfigTestHelper.run_config
      exit_code.should eq(0)

      parsed = JSON.parse(stdout)
      parsed["backups"]["enabled"].as_bool.should be_false
      parsed["backups"]["retention_days"].as_i.should eq(7)
      parsed["backups"]["path"].as_s.should eq("/my/backups")
    end
  end
end
