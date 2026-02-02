require "../spec_helper"

# Integration tests that run the actual CLI binary
# These test the full CLI behavior end-to-end

# Helper module for CLI integration tests
module CLITestHelper
  # Path to the dev binary (built by `make dev`)
  # Use expand_path to resolve relative path correctly
  BINARY_PATH = File.expand_path(File.join(__DIR__, "../../build/galaxy"))

  def self.run_cli(args : Array(String) = [] of String) : {Int32, String, String}
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    # Clear GALAXY_SKIP_CLI so the binary actually runs
    # (spec_helper sets it to skip CLI when requiring the module)
    env = ENV.to_h
    env.delete("GALAXY_SKIP_CLI")

    status = Process.run(
      BINARY_PATH,
      args: args,
      output: stdout,
      error: stderr,
      env: env,
      clear_env: true
    )

    {status.exit_code, stdout.to_s, stderr.to_s}
  end

  def self.binary_exists? : Bool
    File.exists?(BINARY_PATH)
  end
end

describe "galaxy CLI" do
  describe "help" do
    it "shows help with --help flag" do
      pending!("Binary not built. Run `make dev` first.") unless CLITestHelper.binary_exists?

      exit_code, stdout, stderr = CLITestHelper.run_cli(["--help"])

      exit_code.should eq(0)
      stderr.should be_empty
      stdout.should contain("galaxy - Launch Galaxy sessions from the terminal")
      stdout.should contain("Usage:")
      stdout.should contain("Commands:")
      stdout.should contain("Options:")
    end

    it "shows help with -h flag" do
      pending!("Binary not built. Run `make dev` first.") unless CLITestHelper.binary_exists?

      exit_code, stdout, stderr = CLITestHelper.run_cli(["-h"])

      exit_code.should eq(0)
      stderr.should be_empty
      stdout.should contain("galaxy - Launch Galaxy sessions from the terminal")
    end

    it "shows help with help command" do
      pending!("Binary not built. Run `make dev` first.") unless CLITestHelper.binary_exists?

      exit_code, stdout, stderr = CLITestHelper.run_cli(["help"])

      exit_code.should eq(0)
      stderr.should be_empty
      stdout.should contain("galaxy - Launch Galaxy sessions from the terminal")
    end
  end

  describe "version" do
    it "shows version with --version flag" do
      pending!("Binary not built. Run `make dev` first.") unless CLITestHelper.binary_exists?

      exit_code, stdout, stderr = CLITestHelper.run_cli(["--version"])

      exit_code.should eq(0)
      stderr.should be_empty
      stdout.strip.should match(/^\d+\.\d+\.\d+$/)
    end

    it "shows version with -v flag" do
      pending!("Binary not built. Run `make dev` first.") unless CLITestHelper.binary_exists?

      exit_code, stdout, stderr = CLITestHelper.run_cli(["-v"])

      exit_code.should eq(0)
      stderr.should be_empty
      stdout.strip.should match(/^\d+\.\d+\.\d+$/)
    end

    it "shows version with version command" do
      pending!("Binary not built. Run `make dev` first.") unless CLITestHelper.binary_exists?

      exit_code, stdout, stderr = CLITestHelper.run_cli(["version"])

      exit_code.should eq(0)
      stderr.should be_empty
      stdout.strip.should match(/^\d+\.\d+\.\d+$/)
    end

    it "version matches Galaxy::VERSION constant" do
      pending!("Binary not built. Run `make dev` first.") unless CLITestHelper.binary_exists?

      exit_code, stdout, _ = CLITestHelper.run_cli(["version"])

      exit_code.should eq(0)
      stdout.strip.should eq(Galaxy::VERSION)
    end
  end

  describe "unknown command" do
    it "shows error for unknown command" do
      pending!("Binary not built. Run `make dev` first.") unless CLITestHelper.binary_exists?

      exit_code, stdout, stderr = CLITestHelper.run_cli(["foobar"])

      exit_code.should eq(1)
      stdout.should be_empty
      stderr.should contain("Error: Unknown command 'foobar'")
      stderr.should contain("Run 'galaxy --help' for usage")
    end
  end

  describe "unknown flag" do
    it "shows error for unknown flag" do
      pending!("Binary not built. Run `make dev` first.") unless CLITestHelper.binary_exists?

      exit_code, stdout, stderr = CLITestHelper.run_cli(["--unknown"])

      exit_code.should eq(1)
      stdout.should be_empty
      stderr.should contain("Error: Unknown flag '--unknown'")
      stderr.should contain("Run 'galaxy --help' for usage")
    end
  end

  describe "update help" do
    it "shows update help with update help command" do
      pending!("Binary not built. Run `make dev` first.") unless CLITestHelper.binary_exists?

      exit_code, stdout, stderr = CLITestHelper.run_cli(["update", "help"])

      exit_code.should eq(0)
      stderr.should be_empty
      stdout.should contain("galaxy update - Update to the latest version")
      stdout.should contain("preview")
      stdout.should contain("force")
    end
  end
end
