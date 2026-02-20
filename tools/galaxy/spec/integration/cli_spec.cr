require "../spec_helper"

# Integration tests that run the actual CLI binary
# These test the full CLI behavior end-to-end

# Helper module for CLI integration tests
module CLITestHelper
  # Path to the dev binary (built by `make dev`)
  BINARY_PATH = File.expand_path(File.join(__DIR__, "../../build/galaxy"))

  # Run CLI with minimal env — no claude-persona findable.
  # HOME points to a temp dir (so ~/.local/bin/claude-persona won't exist),
  # PATH is empty (so `which` fallback also fails).
  # Used for: graceful degradation tests, vanilla-only behavior.
  def self.run_cli(
    args : Array(String) = [] of String,
    env_overrides : Hash(String, String) = {} of String => String,
  ) : {Int32, String, String}
    env = {"HOME" => "/tmp/galaxy-spec-no-cp", "PATH" => ""}
    env_overrides.each { |k, v| env[k] = v }
    run_binary(args, env)
  end

  # Run CLI with full env — claude-persona findable on PATH.
  # Used for: delegation tests, persona-aware behavior.
  def self.run_cli_with_env(
    args : Array(String) = [] of String,
    env_overrides : Hash(String, String) = {} of String => String,
  ) : {Int32, String, String}
    env = ENV.to_h
    env.delete("GALAXY_SKIP_CLI")
    env_overrides.each { |k, v| env[k] = v }
    run_binary(args, env)
  end

  private def self.run_binary(
    args : Array(String),
    env : Hash(String, String),
  ) : {Int32, String, String}
    stdout = IO::Memory.new
    stderr = IO::Memory.new

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

  def self.claude_persona_available? : Bool
    Process.run("which", args: ["claude-persona"],
      output: Process::Redirect::Close,
      error: Process::Redirect::Close).success?
  end
end

describe "galaxy CLI" do
  describe "help" do
    it "shows help with --help flag" do
      pending!("Binary not built. Run `make dev` first.") unless CLITestHelper.binary_exists?

      exit_code, stdout, stderr = CLITestHelper.run_cli_with_env(["--help"])

      exit_code.should eq(0)
      stderr.should be_empty
      stdout.should contain("Galaxy v")
      stdout.should contain("Claude Code session manager")
      stdout.should contain("Usage:")
    end

    it "shows help with -h flag" do
      pending!("Binary not built. Run `make dev` first.") unless CLITestHelper.binary_exists?

      exit_code, stdout, stderr = CLITestHelper.run_cli_with_env(["-h"])

      exit_code.should eq(0)
      stderr.should be_empty
      stdout.should contain("Galaxy v")
    end

    it "shows help with help command" do
      pending!("Binary not built. Run `make dev` first.") unless CLITestHelper.binary_exists?

      exit_code, stdout, stderr = CLITestHelper.run_cli_with_env(["help"])

      exit_code.should eq(0)
      stderr.should be_empty
      stdout.should contain("Galaxy v")
    end
  end

  describe "dynamic help" do
    context "with claude-persona installed" do
      it "shows persona commands in help" do
        pending!("Binary not built. Run `make dev` first.") unless CLITestHelper.binary_exists?
        pending!("claude-persona not installed") unless CLITestHelper.claude_persona_available?

        exit_code, stdout, stderr = CLITestHelper.run_cli_with_env(["--help"])

        exit_code.should eq(0)
        stdout.should contain("galaxy <persona>")
        stdout.should contain("galaxy generate")
        stdout.should contain("claude-persona help")
      end
    end

    context "without claude-persona installed" do
      it "shows vanilla-only help with persona install hint" do
        pending!("Binary not built. Run `make dev` first.") unless CLITestHelper.binary_exists?

        # run_cli uses minimal env — claude-persona not findable
        exit_code, stdout, stderr = CLITestHelper.run_cli(["--help"])

        exit_code.should eq(0)
        stdout.should contain("Galaxy v")
        stdout.should_not contain("galaxy <persona>")
        stdout.should contain("Persona features require claude-persona")
        stdout.should contain("github.com/kellyredding/claude-persona")
      end
    end
  end

  describe "version" do
    it "shows version with --version flag" do
      pending!("Binary not built. Run `make dev` first.") unless CLITestHelper.binary_exists?

      exit_code, stdout, stderr = CLITestHelper.run_cli_with_env(["--version"])

      exit_code.should eq(0)
      stderr.should be_empty
      stdout.strip.should match(/^\d+\.\d+\.\d+$/)
    end

    it "shows version with -v flag" do
      pending!("Binary not built. Run `make dev` first.") unless CLITestHelper.binary_exists?

      exit_code, stdout, stderr = CLITestHelper.run_cli_with_env(["-v"])

      exit_code.should eq(0)
      stderr.should be_empty
      stdout.strip.should match(/^\d+\.\d+\.\d+$/)
    end

    it "shows version with version command" do
      pending!("Binary not built. Run `make dev` first.") unless CLITestHelper.binary_exists?

      exit_code, stdout, stderr = CLITestHelper.run_cli_with_env(["version"])

      exit_code.should eq(0)
      stderr.should be_empty
      stdout.strip.should match(/^\d+\.\d+\.\d+$/)
    end

    it "version matches Galaxy::VERSION constant" do
      pending!("Binary not built. Run `make dev` first.") unless CLITestHelper.binary_exists?

      exit_code, stdout, _ = CLITestHelper.run_cli_with_env(["version"])

      exit_code.should eq(0)
      stdout.strip.should eq(Galaxy::VERSION)
    end
  end

  describe "unknown flag" do
    it "shows error for unknown flag" do
      pending!("Binary not built. Run `make dev` first.") unless CLITestHelper.binary_exists?

      exit_code, stdout, stderr = CLITestHelper.run_cli_with_env(["--unknown"])

      exit_code.should eq(1)
      stdout.should be_empty
      stderr.should contain("Error: Unknown flag '--unknown'")
      stderr.should contain("Run 'galaxy --help' for usage")
    end
  end

  describe "update help" do
    it "shows update help with update help command" do
      pending!("Binary not built. Run `make dev` first.") unless CLITestHelper.binary_exists?

      exit_code, stdout, stderr = CLITestHelper.run_cli_with_env(["update", "help"])

      exit_code.should eq(0)
      stderr.should be_empty
      stdout.should contain("galaxy update - Update to the latest version")
      stdout.should contain("preview")
      stdout.should contain("force")
    end
  end

  describe "graceful degradation" do
    it "shows install hint when delegating without claude-persona" do
      pending!("Binary not built. Run `make dev` first.") unless CLITestHelper.binary_exists?

      # run_cli uses minimal env — no claude-persona findable
      # "list" is not a Galaxy command and not a persona TOML,
      # so it falls through to delegation which fails
      exit_code, stdout, stderr = CLITestHelper.run_cli(["list"])

      exit_code.should eq(1)
      stderr.should contain("Claude Persona is not installed")
      stderr.should contain("github.com/kellyredding/claude-persona")
    end

    it "shows install hint for persona launch without claude-persona" do
      pending!("Binary not built. Run `make dev` first.") unless CLITestHelper.binary_exists?

      # "test-basic" TOML exists in fixtures, so it's detected as a persona.
      # But claude-persona binary is not findable → install hint.
      exit_code, stdout, stderr = CLITestHelper.run_cli(
        ["test-basic"],
        {"CLAUDE_PERSONA_DIR" => SPEC_FIXTURES.to_s}
      )

      exit_code.should eq(1)
      stderr.should contain("Claude Persona is not installed")
    end
  end

  describe "delegation to claude-persona" do
    it "delegates list command" do
      pending!("Binary not built. Run `make dev` first.") unless CLITestHelper.binary_exists?
      pending!("claude-persona not installed") unless CLITestHelper.claude_persona_available?

      exit_code, stdout, stderr = CLITestHelper.run_cli_with_env(["list"])

      # claude-persona list should exit 0 (even if no personas found)
      exit_code.should eq(0)
    end

    it "delegates show command for unknown persona" do
      pending!("Binary not built. Run `make dev` first.") unless CLITestHelper.binary_exists?
      pending!("claude-persona not installed") unless CLITestHelper.claude_persona_available?

      exit_code, stdout, stderr = CLITestHelper.run_cli_with_env(["show", "nonexistent-persona-xyz"])

      # claude-persona show <nonexistent> should exit 1
      exit_code.should eq(1)
      stderr.should contain("not found")
    end

    it "passes through exit codes from claude-persona" do
      pending!("Binary not built. Run `make dev` first.") unless CLITestHelper.binary_exists?
      pending!("claude-persona not installed") unless CLITestHelper.claude_persona_available?

      # "show" with no args triggers claude-persona's usage error (exit 1)
      exit_code, stdout, stderr = CLITestHelper.run_cli_with_env(["show"])

      exit_code.should eq(1)
    end
  end

  describe "non-interactive flag detection" do
    it "delegates --dry-run locally" do
      pending!("Binary not built. Run `make dev` first.") unless CLITestHelper.binary_exists?
      pending!("claude-persona not installed") unless CLITestHelper.claude_persona_available?

      exit_code, stdout, stderr = CLITestHelper.run_cli_with_env(
        ["test-basic", "--dry-run"],
        {
          "CLAUDE_PERSONA_DIR"        => SPEC_FIXTURES.to_s,
          "CLAUDE_PERSONA_CONFIG_DIR" => SPEC_FIXTURES.to_s,
        }
      )

      # Dry-run should output the claude command
      exit_code.should eq(0)
      stdout.should contain("claude")
    end
  end
end
