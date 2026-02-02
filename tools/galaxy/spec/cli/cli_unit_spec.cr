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
end
