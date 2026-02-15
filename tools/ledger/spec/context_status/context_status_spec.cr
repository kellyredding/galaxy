require "../spec_helper"

describe GalaxyLedger::ContextStatus do
  describe "JSON parsing" do
    it "parses full context status JSON" do
      json = %|{
        "session_id": "test-session",
        "timestamp": 1234567890,
        "cwd": "/test/working/dir",
        "git_branch": "main",
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
      }|

      status = GalaxyLedger::ContextStatus.from_json(json)

      status.session_id.should eq("test-session")
      status.timestamp.should eq(1234567890)
      status.cwd.should eq("/test/working/dir")
      status.git_branch.should eq("main")
      status.claude_version.should eq("1.0.80")

      # Workspace
      status.workspace.should_not be_nil
      status.workspace.not_nil!.current_dir.should eq("/test/current")
      status.workspace.not_nil!.project_dir.should eq("/test/project")
      status.project_dir.should eq("/test/project")

      # Model
      status.model_id.should eq("claude-sonnet-4-20250514")
      status.model_display_name.should eq("Sonnet")

      # Context
      status.percentage.should eq(72.5)
      status.tokens_used.should eq(145000)
      status.tokens_max.should eq(200000)

      # Cost
      status.cost_usd.should eq(0.42)
      status.lines_added.should eq(45)
      status.lines_removed.should eq(12)
    end

    it "parses minimal JSON with only context" do
      json = %|{
        "session_id": "minimal",
        "timestamp": 1234567890,
        "context": {
          "percentage": 50.0
        }
      }|

      status = GalaxyLedger::ContextStatus.from_json(json)
      status.session_id.should eq("minimal")
      status.percentage.should eq(50.0)
      status.tokens_used.should be_nil
      status.tokens_max.should be_nil
      status.model_id.should be_nil
      status.workspace.should be_nil
      status.cost.should be_nil
      status.git_branch.should be_nil
      status.project_dir.should be_nil
    end

    it "handles nil git_branch" do
      json = %|{"session_id": "no-branch"}|
      status = GalaxyLedger::ContextStatus.from_json(json)
      status.git_branch.should be_nil
    end

    it "handles git_branch with slashes" do
      json = %|{"session_id": "branch-test", "git_branch": "kr/galaxy-ledger01-foundation"}|
      status = GalaxyLedger::ContextStatus.from_json(json)
      status.git_branch.should eq("kr/galaxy-ledger01-foundation")
    end

    it "exposes project_dir convenience accessor" do
      json = %|{
        "session_id": "project-dir-test",
        "workspace": {"project_dir": "/path/to/project"}
      }|
      status = GalaxyLedger::ContextStatus.from_json(json)
      status.project_dir.should eq("/path/to/project")
    end

    it "returns nil project_dir when workspace is nil" do
      json = %|{"session_id": "no-workspace"}|
      status = GalaxyLedger::ContextStatus.from_json(json)
      status.project_dir.should be_nil
    end
  end
end

describe "GalaxyLedger session helpers" do
  describe ".session_dir" do
    it "returns correct directory for session" do
      dir = GalaxyLedger.session_dir("my-session")
      dir.to_s.should contain("sessions")
      dir.to_s.should end_with("my-session")
    end
  end
end
