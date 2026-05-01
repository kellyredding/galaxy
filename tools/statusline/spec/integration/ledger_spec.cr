require "../spec_helper"

describe "Statusline → Ledger integration" do
  describe ".build_metrics_json" do
    it "builds complete JSON with all fields including git_branch" do
      json = read_fixture("claude_input/valid_complete.json")
      input = GalaxyStatusline::ClaudeInput.parse(json)

      result = GalaxyStatusline::CLI.build_metrics_json(input, "main")
      parsed = JSON.parse(result)

      parsed["session_id"].should eq("abc123")
      parsed["timestamp"].as_i64.should be > 0
      parsed["cwd"].should eq("/current/working/directory")
      parsed["claude_version"].should eq("1.0.80")
      parsed["git_branch"].should eq("main")

      # Workspace
      parsed["workspace"]["current_dir"].should eq("/Users/kelly/projects/galaxy")
      parsed["workspace"]["project_dir"].should eq("/Users/kelly/projects/galaxy")

      # Model
      parsed["model"]["id"].should eq("claude-sonnet-4-20250514")
      parsed["model"]["display_name"].should eq("Sonnet")

      # Context
      parsed["context"]["percentage"].should eq(45.2)
      parsed["context"]["tokens_used"].should eq(90400)
      parsed["context"]["tokens_max"].should eq(200000)

      # Cost
      parsed["cost"]["usd"].should eq(0.42)
      parsed["cost"]["lines_added"].should eq(45)
      parsed["cost"]["lines_removed"].should eq(12)
    end

    it "handles nil git_branch" do
      json = read_fixture("claude_input/valid_complete.json")
      input = GalaxyStatusline::ClaudeInput.parse(json)

      result = GalaxyStatusline::CLI.build_metrics_json(input, nil)
      parsed = JSON.parse(result)

      parsed["git_branch"].raw.should be_nil
    end

    it "handles minimal input (no workspace, model, context, cost)" do
      json = %|{"session_id": "minimal-test"}|
      input = GalaxyStatusline::ClaudeInput.parse(json)

      result = GalaxyStatusline::CLI.build_metrics_json(input, nil)
      parsed = JSON.parse(result)

      parsed["session_id"].should eq("minimal-test")
      parsed["timestamp"].as_i64.should be > 0
      parsed["cwd"]?.try(&.raw).should be_nil
      parsed["claude_version"]?.try(&.raw).should be_nil
      parsed["git_branch"]?.try(&.raw).should be_nil
      parsed["workspace"]?.should be_nil
      parsed["model"]?.should be_nil
      parsed["context"]?.should be_nil
      parsed["cost"]?.should be_nil
    end

    it "includes git_branch from statusline git helper" do
      json = read_fixture("claude_input/valid_complete.json")
      input = GalaxyStatusline::ClaudeInput.parse(json)

      result = GalaxyStatusline::CLI.build_metrics_json(input, "kr/feature-01-test")
      parsed = JSON.parse(result)

      parsed["git_branch"].should eq("kr/feature-01-test")
    end
  end

  describe ".send_metrics_to_ledger" do
    it "silently skips when session_id is nil" do
      json = %|{"context_window": {"used_percentage": 50.0}}|
      input = GalaxyStatusline::ClaudeInput.parse(json)

      # Should not raise
      GalaxyStatusline::CLI.send_metrics_to_ledger(input, nil)
    end

    it "silently skips when ledger binary does not exist" do
      json = %|{"session_id": "test-no-binary"}|
      input = GalaxyStatusline::ClaudeInput.parse(json)

      # Should not raise even when binary doesn't exist
      # (it won't exist at the test GALAXY_DIR path)
      GalaxyStatusline::CLI.send_metrics_to_ledger(input, nil)
    end
  end
end
