require "../spec_helper"

describe "CLI Integration" do
  describe "version subcommand" do
    it "outputs version" do
      result = run_binary(["version"])
      result[:output].should contain(GalaxyLedger::VERSION)
      result[:status].should eq(0)
    end
  end

  describe "--version flag" do
    it "outputs version" do
      result = run_binary(["--version"])
      result[:output].should contain(GalaxyLedger::VERSION)
      result[:status].should eq(0)
    end
  end

  describe "help subcommand" do
    it "outputs usage information" do
      result = run_binary(["help"])
      result[:output].should contain("galaxy-ledger")
      result[:output].should contain("Commands:")
      result[:status].should eq(0)
    end
  end

  describe "--help flag" do
    it "outputs usage information" do
      result = run_binary(["--help"])
      result[:output].should contain("galaxy-ledger")
      result[:status].should eq(0)
    end
  end

  describe "no arguments" do
    it "shows help when no arguments provided" do
      result = run_binary([] of String)
      result[:output].should contain("galaxy-ledger")
      result[:output].should contain("Commands:")
      result[:status].should eq(0)
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
        result[:output].should contain("thresholds")
        result[:output].should contain("warnings")
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
        result[:output].should contain("thresholds")
        result[:output].should contain("warnings")
        result[:status].should eq(0)
      end
    end

    describe "config set KEY VALUE" do
      it "updates config" do
        result = run_binary(["config", "set", "thresholds.warning", "75"])
        result[:output].should contain("Set thresholds.warning")
        result[:status].should eq(0)

        # Verify it was set
        result = run_binary(["config", "get", "thresholds.warning"])
        result[:output].strip.should eq("75")
      end

      it "handles nested keys" do
        result = run_binary(["config", "set", "storage.postgres_enabled", "true"])
        result[:status].should eq(0)

        result = run_binary(["config", "get", "storage.postgres_enabled"])
        result[:output].strip.should eq("true")
      end

      it "handles deeply nested keys" do
        result = run_binary(["config", "set", "restoration.tier2_limits.learnings", "8"])
        result[:status].should eq(0)

        result = run_binary(["config", "get", "restoration.tier2_limits.learnings"])
        result[:output].strip.should eq("8")
      end

      it "outputs error for invalid value" do
        result = run_binary(["config", "set", "thresholds.warning", "invalid"])
        result[:error].should contain("must be integer")
        result[:status].should_not eq(0)
      end
    end

    describe "config get KEY" do
      it "outputs value for valid key" do
        result = run_binary(["config", "get", "thresholds.warning"])
        result[:status].should eq(0)
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
        run_binary(["config", "set", "thresholds.warning", "80"])

        # Reset
        result = run_binary(["config", "reset"])
        result[:output].should contain("reset to defaults")
        result[:status].should eq(0)

        # Verify it's back to default
        result = run_binary(["config", "get", "thresholds.warning"])
        result[:output].strip.should eq("70")
      end
    end
  end

  describe "on-startup subcommand" do
    it "outputs JSON with additionalContext" do
      result = run_binary(["on-startup"])
      result[:status].should eq(0)

      # Parse the output as JSON
      output = JSON.parse(result[:output])
      output["hookSpecificOutput"]["hookEventName"].should eq("SessionStart")
      output["hookSpecificOutput"]["additionalContext"].as_s.should contain("Galaxy Ledger Available")
    end

    it "includes ledger awareness information" do
      result = run_binary(["on-startup"])
      result[:status].should eq(0)

      output = JSON.parse(result[:output])
      context = output["hookSpecificOutput"]["additionalContext"].as_s
      context.should contain("persistent context ledger")
      context.should contain("galaxy-ledger search")
    end

    it "creates session folder when session_id provided" do
      session_id = "test-startup-session-#{Random.rand(100000)}"
      session_dir = GalaxyLedger.session_dir(session_id)

      # Clean up any existing session
      FileUtils.rm_rf(session_dir.to_s)

      # Run on-startup with session_id
      result = run_binary(["on-startup"], stdin: %({"session_id": "#{session_id}"}))
      result[:status].should eq(0)

      # Verify session folder was created
      Dir.exists?(session_dir).should eq(true)

      # Clean up
      FileUtils.rm_rf(session_dir.to_s)
    end
  end

  describe "session subcommand" do
    test_session_id = "test-cli-session-#{Random.rand(100000)}"

    describe "session (no args)" do
      it "shows help when no subcommand provided" do
        result = run_binary(["session"])
        result[:output].should contain("galaxy-ledger session")
        result[:output].should contain("USAGE")
        result[:status].should eq(0)
      end
    end

    describe "session list" do
      it "lists sessions" do
        result = run_binary(["session", "list"])
        result[:status].should eq(0)
        # Output should either show sessions or "No sessions found"
        output = result[:output]
        (output.includes?("Sessions") || output.includes?("No sessions")).should eq(true)
      end
    end

    describe "session show SESSION_ID" do
      it "shows session details for existing session" do
        # Create a test session
        session_dir = GalaxyLedger.session_dir(test_session_id)
        Dir.mkdir_p(session_dir)

        result = run_binary(["session", "show", test_session_id])
        result[:status].should eq(0)
        result[:output].should contain("Session: #{test_session_id}")
        result[:output].should contain("Path:")
        result[:output].should contain("Status:")

        # Clean up
        FileUtils.rm_rf(session_dir.to_s)
      end

      it "outputs error for non-existent session" do
        result = run_binary(["session", "show", "nonexistent-session-#{Random.rand(100000)}"])
        result[:error].should contain("Session not found")
        result[:status].should_not eq(0)
      end

      it "outputs error when session_id not provided" do
        result = run_binary(["session", "show"])
        result[:error].should contain("Usage")
        result[:status].should_not eq(0)
      end
    end

    describe "session remove SESSION_ID" do
      it "removes existing session" do
        # Create a test session
        session_dir = GalaxyLedger.session_dir(test_session_id)
        Dir.mkdir_p(session_dir)
        # Add a test file
        File.write(session_dir / "test.txt", "test content")

        # Verify it exists
        Dir.exists?(session_dir).should eq(true)

        result = run_binary(["session", "remove", test_session_id])
        result[:status].should eq(0)
        result[:output].should contain("Removed session")
        result[:output].should contain("Folder removed: yes")

        # Verify it's gone
        Dir.exists?(session_dir).should eq(false)
      end

      it "outputs error for non-existent session" do
        result = run_binary(["session", "remove", "nonexistent-session-#{Random.rand(100000)}"])
        result[:error].should contain("Session not found")
        result[:status].should_not eq(0)
      end

      it "outputs error when session_id not provided" do
        result = run_binary(["session", "remove"])
        result[:error].should contain("Usage")
        result[:status].should_not eq(0)
      end
    end

    describe "session help" do
      it "shows session help" do
        result = run_binary(["session", "help"])
        result[:output].should contain("galaxy-ledger session")
        result[:output].should contain("USAGE")
        result[:status].should eq(0)
      end
    end
  end
end
