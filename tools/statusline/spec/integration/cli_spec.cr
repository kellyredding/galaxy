require "../spec_helper"

describe "CLI Integration" do
  describe "version subcommand" do
    it "outputs version" do
      result = run_binary(["version"])
      result[:output].strip.should eq(GalaxyStatusline::VERSION)
      result[:status].should eq(0)
    end
  end

  describe "--version flag" do
    it "outputs version" do
      result = run_binary(["--version"])
      result[:output].strip.should eq(GalaxyStatusline::VERSION)
      result[:status].should eq(0)
    end
  end

  describe "help subcommand" do
    it "outputs usage information" do
      result = run_binary(["help"])
      result[:output].should contain("galaxy-statusline")
      result[:output].should contain("Commands:")
      result[:status].should eq(0)
    end
  end

  describe "--help flag" do
    it "outputs usage information" do
      result = run_binary(["--help"])
      result[:output].should contain("galaxy-statusline")
      result[:status].should eq(0)
    end
  end

  describe "no arguments" do
    # Note: When run programmatically, stdin is not a TTY, so the binary
    # tries to render (expecting JSON input). This tests that behavior.
    it "errors when no stdin data in non-TTY mode" do
      result = run_binary([] of String)
      # Should error because it tries to render with no stdin
      result[:error].should contain("No input")
      result[:status].should_not eq(0)
    end
  end

  describe "unknown command" do
    it "outputs error and exits non-zero" do
      result = run_binary(["unknown"])
      result[:error].should contain("Unknown command")
      result[:status].should_not eq(0)
    end
  end

  describe "config subcommand" do
    describe "config (no args)" do
      it "outputs current config as JSON" do
        result = run_binary(["config"])
        result[:output].should contain("version")
        result[:output].should contain("branch_style")
        result[:status].should eq(0)
      end
    end

    describe "config path" do
      it "outputs config file path" do
        result = run_binary(["config", "path"])
        result[:output].should contain("config.json")
        result[:status].should eq(0)
      end
    end

    describe "config help" do
      it "outputs configuration documentation" do
        result = run_binary(["config", "help"])
        result[:output].should contain("AVAILABLE SETTINGS")
        result[:output].should contain("branch_style")
        result[:output].should contain("colors")
        result[:status].should eq(0)
      end
    end

    describe "config set KEY VALUE" do
      it "updates config" do
        result = run_binary(["config", "set", "branch_style", "arrows"])
        result[:output].should contain("Set branch_style")
        result[:status].should eq(0)

        # Verify it was set
        result = run_binary(["config", "get", "branch_style"])
        result[:output].strip.should eq("arrows")
      end

      it "handles nested keys" do
        result = run_binary(["config", "set", "colors.branch", "cyan"])
        result[:status].should eq(0)

        result = run_binary(["config", "get", "colors.branch"])
        result[:output].strip.should eq("cyan")
      end

      it "outputs error for invalid value" do
        result = run_binary(["config", "set", "branch_style", "invalid"])
        result[:error].should contain("Invalid branch_style")
        result[:status].should_not eq(0)
      end
    end

    describe "config get KEY" do
      it "outputs value for valid key" do
        result = run_binary(["config", "get", "branch_style"])
        result[:status].should eq(0)
        # Output should be symbolic or arrows (depending on prior tests)
        result[:output].should_not be_empty
      end

      it "outputs error for invalid key" do
        result = run_binary(["config", "get", "nonexistent"])
        result[:error].should contain("Unknown")
        result[:status].should_not eq(0)
      end
    end

    describe "config reset" do
      it "resets config to defaults" do
        # First change something
        run_binary(["config", "set", "branch_style", "arrows"])

        # Reset
        result = run_binary(["config", "reset"])
        result[:output].should contain("reset to defaults")
        result[:status].should eq(0)

        # Verify it's back to default
        result = run_binary(["config", "get", "branch_style"])
        result[:output].strip.should eq("symbolic")
      end
    end
  end

  describe "render subcommand" do
    it "outputs status line given valid JSON via stdin" do
      json = read_fixture("claude_input/valid_complete.json")
      result = run_binary(["render"], stdin: json)
      result[:status].should eq(0)
      result[:output].should_not be_empty
    end

    it "includes context percentage in output" do
      json = read_fixture("claude_input/valid_complete.json")
      result = run_binary(["render"], stdin: json)
      # Should contain percentage (45% from fixture)
      result[:output].should contain("45%")
    end

    it "outputs error given empty stdin" do
      result = run_binary(["render"], stdin: "")
      result[:error].should contain("No input")
      result[:status].should_not eq(0)
    end

    it "outputs error given malformed JSON" do
      json = read_fixture("claude_input/malformed.json")
      result = run_binary(["render"], stdin: json)
      result[:error].should contain("Invalid JSON")
      result[:status].should_not eq(0)
    end
  end
end
