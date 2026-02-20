require "../spec_helper"

# Unit tests for CLI module internals
# Tests logic without running the full binary

describe Galaxy::CLI do
  describe ".open_session" do
    # Note: We can't easily test open_session directly without mocking Process.run
    # The integration specs test the actual URL scheme invocation behavior
    # Here we test the URL construction logic indirectly through constants

    it "uses the correct URL scheme constant" do
      Galaxy::URL_SCHEME.should eq("galaxy")
    end

    it "has a valid app bundle ID" do
      Galaxy::APP_BUNDLE_ID.should eq("com.kellyredding.galaxy")
    end
  end

  describe "VERSION" do
    it "has a valid semver format" do
      Galaxy::VERSION.should match(/^\d+\.\d+\.\d+$/)
    end

    it "matches VERSION.txt" do
      version_file = File.join(__DIR__, "../../VERSION.txt")
      if File.exists?(version_file)
        file_version = File.read(version_file).strip
        Galaxy::VERSION.should eq(file_version)
      end
    end
  end

  describe "GALAXY_DIR" do
    it "defaults to ~/.claude/galaxy" do
      # When GALAXY_DIR env var is not set, uses default
      expected_default = Path.home / ".claude" / "galaxy"
      Galaxy::GALAXY_DIR.to_s.should eq(expected_default.to_s)
    end
  end

  describe "CLAUDE_PERSONA_DIR" do
    it "respects env var override" do
      # spec_helper sets CLAUDE_PERSONA_DIR to spec/fixtures
      Galaxy::CLAUDE_PERSONA_DIR.to_s.should eq(SPEC_FIXTURES.to_s)
    end
  end

  describe "PERSONAS_DIR" do
    it "is a subdirectory of CLAUDE_PERSONA_DIR" do
      Galaxy::PERSONAS_DIR.to_s.should eq((SPEC_FIXTURES / "personas").to_s)
    end
  end

  describe ".persona_file_exists?" do
    it "returns true when persona TOML exists" do
      # Uses SPEC_FIXTURES/personas/test-basic.toml
      Galaxy::CLI.persona_file_exists?("test-basic").should be_true
    end

    it "returns false when persona TOML does not exist" do
      Galaxy::CLI.persona_file_exists?("nonexistent").should be_false
    end

    it "returns false for empty string" do
      Galaxy::CLI.persona_file_exists?("").should be_false
    end
  end

  describe ".build_session_url" do
    it "constructs vanilla session URL" do
      url = Galaxy::CLI.build_session_url("/tmp/test")
      url.should eq("galaxy://new-session?path=/tmp/test")
    end

    it "encodes path with special characters" do
      url = Galaxy::CLI.build_session_url("/Users/foo/My Projects")
      url.should contain("path=/Users/foo/My%20Projects")
    end

    it "constructs persona session URL" do
      url = Galaxy::CLI.build_session_url("/tmp/test", persona: "dev")
      url.should eq("galaxy://new-session?path=/tmp/test&persona=dev")
    end

    it "includes vibe param when set" do
      url = Galaxy::CLI.build_session_url("/tmp/test", persona: "dev", vibe: true)
      url.should eq("galaxy://new-session?path=/tmp/test&persona=dev&vibe=true")
    end

    it "omits vibe param when false" do
      url = Galaxy::CLI.build_session_url("/tmp/test", persona: "dev", vibe: false)
      url.should_not contain("vibe")
    end

    it "includes resume param when set" do
      url = Galaxy::CLI.build_session_url("/tmp/test", persona: "dev", resume: "abc-123")
      url.should eq("galaxy://new-session?path=/tmp/test&persona=dev&resume=abc-123")
    end

    it "constructs vanilla resume URL without persona" do
      url = Galaxy::CLI.build_session_url("/tmp/test", resume: "abc-123")
      url.should eq("galaxy://new-session?path=/tmp/test&resume=abc-123")
      url.should_not contain("persona")
    end

    it "constructs full URL with all params" do
      url = Galaxy::CLI.build_session_url("/tmp/test", persona: "dev", vibe: true, resume: "abc-123")
      url.should eq("galaxy://new-session?path=/tmp/test&persona=dev&vibe=true&resume=abc-123")
    end
  end

  describe ".find_claude_persona_path" do
    it "returns a path when claude-persona is installed" do
      # This test depends on claude-persona actually being installed
      path = Galaxy::CLI.find_claude_persona_path
      if path
        File.info(path).permissions.owner_execute?.should be_true
      end
    end
  end

  describe ".command_exists?" do
    it "returns true for commands that exist" do
      Galaxy::CLI.command_exists?("bash").should be_true
      Galaxy::CLI.command_exists?("curl").should be_true
    end

    it "returns false for commands that don't exist" do
      Galaxy::CLI.command_exists?("nonexistent-command-abc123").should be_false
    end
  end

  describe "GALAXY_COMMANDS" do
    it "includes Galaxy's own commands" do
      Galaxy::CLI::GALAXY_COMMANDS.should contain("help")
      Galaxy::CLI::GALAXY_COMMANDS.should contain("version")
      Galaxy::CLI::GALAXY_COMMANDS.should contain("update")
    end
  end
end
