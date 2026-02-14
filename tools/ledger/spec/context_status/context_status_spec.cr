require "../spec_helper"

describe GalaxyLedger::ContextStatus do
  describe ".read" do
    it "reads full context status from session-specific file" do
      session_id = "test-ledger-read-#{Random.rand(100000)}"

      # Create session directory and write a test file
      session_dir = GalaxyLedger.session_dir(session_id)
      Dir.mkdir_p(session_dir)

      status_file = GalaxyLedger.context_status_path(session_id)
      File.write(status_file, %|{
        "session_id": "#{session_id}",
        "timestamp": 1234567890,
        "cwd": "/test/working/dir",
        "workspace": {
          "current_dir": "/test/current",
          "project_dir": "/test/project"
        },
        "model": {
          "id": "claude-sonnet-4-20250514",
          "display_name": "Sonnet"
        },
        "claude_version": "1.0.80",
        "context": {
          "percentage": 72.5,
          "tokens_used": 145000,
          "tokens_max": 200000
        },
        "cost": {
          "usd": 0.42,
          "lines_added": 45,
          "lines_removed": 12
        }
      }|)

      # Read it back
      status = GalaxyLedger::ContextStatus.read(session_id)
      status.should_not be_nil

      s = status.not_nil!
      s.session_id.should eq(session_id)
      s.timestamp.should eq(1234567890)
      s.cwd.should eq("/test/working/dir")
      s.claude_version.should eq("1.0.80")

      # Workspace
      s.workspace.should_not be_nil
      s.workspace.not_nil!.current_dir.should eq("/test/current")
      s.workspace.not_nil!.project_dir.should eq("/test/project")

      # Model
      s.model_id.should eq("claude-sonnet-4-20250514")
      s.model_display_name.should eq("Sonnet")
      s.model.should_not be_nil
      s.model.not_nil!.id.should eq("claude-sonnet-4-20250514")
      s.model.not_nil!.display_name.should eq("Sonnet")

      # Context
      s.percentage.should eq(72.5)
      s.tokens_used.should eq(145000)
      s.tokens_max.should eq(200000)

      # Cost
      s.cost_usd.should eq(0.42)
      s.lines_added.should eq(45)
      s.lines_removed.should eq(12)

      # Clean up
      FileUtils.rm_rf(session_dir.to_s)
    end

    it "returns nil when session directory doesn't exist" do
      session_id = "nonexistent-ledger-session-#{Random.rand(100000)}"

      # Ensure it doesn't exist
      session_dir = GalaxyLedger.session_dir(session_id)
      FileUtils.rm_rf(session_dir.to_s) if Dir.exists?(session_dir)

      # Read should return nil
      status = GalaxyLedger::ContextStatus.read(session_id)
      status.should be_nil
    end

    it "returns nil when file doesn't exist in session directory" do
      session_id = "empty-ledger-session-#{Random.rand(100000)}"

      # Create empty session directory
      session_dir = GalaxyLedger.session_dir(session_id)
      Dir.mkdir_p(session_dir)

      # Read should return nil (no file)
      status = GalaxyLedger::ContextStatus.read(session_id)
      status.should be_nil

      # Clean up
      FileUtils.rm_rf(session_dir.to_s)
    end

    it "returns nil for empty session_id" do
      status = GalaxyLedger::ContextStatus.read("")
      status.should be_nil
    end

    it "returns nil for malformed JSON" do
      session_id = "malformed-ledger-session-#{Random.rand(100000)}"

      # Create session directory and write malformed file
      session_dir = GalaxyLedger.session_dir(session_id)
      Dir.mkdir_p(session_dir)

      status_file = GalaxyLedger.context_status_path(session_id)
      File.write(status_file, "not valid json {{{")

      # Read should return nil (graceful degradation)
      status = GalaxyLedger::ContextStatus.read(session_id)
      status.should be_nil

      # Clean up
      FileUtils.rm_rf(session_dir.to_s)
    end

    it "handles partial format gracefully" do
      session_id = "partial-ledger-session-#{Random.rand(100000)}"

      # Create session directory and write partial format
      session_dir = GalaxyLedger.session_dir(session_id)
      Dir.mkdir_p(session_dir)

      status_file = GalaxyLedger.context_status_path(session_id)
      File.write(status_file, %|{
        "session_id": "#{session_id}",
        "timestamp": 1234567890,
        "context": {
          "percentage": 50.0
        }
      }|)

      status = GalaxyLedger::ContextStatus.read(session_id)
      status.should_not be_nil

      s = status.not_nil!
      s.session_id.should eq(session_id)
      s.percentage.should eq(50.0)
      s.tokens_used.should be_nil
      s.tokens_max.should be_nil
      s.model_id.should be_nil
      s.workspace.should be_nil
      s.cost.should be_nil

      # Clean up
      FileUtils.rm_rf(session_dir.to_s)
    end
  end

  describe ".exists?" do
    it "returns true when file exists" do
      session_id = "exists-test-#{Random.rand(100000)}"

      # Create session directory and write a test file
      session_dir = GalaxyLedger.session_dir(session_id)
      Dir.mkdir_p(session_dir)

      status_file = GalaxyLedger.context_status_path(session_id)
      File.write(status_file, "{}")

      GalaxyLedger::ContextStatus.exists?(session_id).should eq(true)

      # Clean up
      FileUtils.rm_rf(session_dir.to_s)
    end

    it "returns false when session directory doesn't exist" do
      session_id = "not-exists-test-#{Random.rand(100000)}"
      FileUtils.rm_rf(GalaxyLedger.session_dir(session_id).to_s)

      GalaxyLedger::ContextStatus.exists?(session_id).should eq(false)
    end

    it "returns false for empty session_id" do
      GalaxyLedger::ContextStatus.exists?("").should eq(false)
    end
  end
end

describe "GalaxyLedger session helpers" do
  describe ".context_status_path" do
    it "returns correct path for session" do
      path = GalaxyLedger.context_status_path("my-session")
      path.to_s.should contain("sessions")
      path.to_s.should contain("my-session")
      path.to_s.should end_with("context-status.json")
    end
  end

  describe ".session_dir" do
    it "returns correct directory for session" do
      dir = GalaxyLedger.session_dir("my-session")
      dir.to_s.should contain("sessions")
      dir.to_s.should end_with("my-session")
    end
  end
end
