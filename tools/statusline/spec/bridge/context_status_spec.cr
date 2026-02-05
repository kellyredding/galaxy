require "../spec_helper"

describe GalaxyStatusline::ContextStatus do
  describe ".write" do
    it "writes full context status to session-specific bridge file" do
      # Create a test input with full payload
      json = read_fixture("claude_input/valid_complete.json")
      input = GalaxyStatusline::ClaudeInput.parse(json)
      session_id = input.session_id.not_nil!

      # Clean up any existing session directory
      session_dir = GalaxyStatusline::ContextStatus.session_dir(session_id)
      FileUtils.rm_rf(session_dir.to_s) if Dir.exists?(session_dir)

      # Write the status
      GalaxyStatusline::ContextStatus.write(input)

      # Verify the session directory was created
      Dir.exists?(session_dir).should eq(true)

      # Verify the file exists in the session directory
      bridge_file = GalaxyStatusline::ContextStatus.path_for_session(session_id)
      File.exists?(bridge_file).should eq(true)

      # Verify the full content
      content = JSON.parse(File.read(bridge_file))

      # Session metadata
      content["session_id"].should eq("abc123")
      content["timestamp"].as_i64.should be > 0
      content["cwd"].should eq("/current/working/directory")
      content["claude_version"].should eq("1.0.80")

      # Workspace
      content["workspace"]["current_dir"].should eq("/Users/kelly/projects/galaxy")
      content["workspace"]["project_dir"].should eq("/Users/kelly/projects/galaxy")

      # Model
      content["model"]["id"].should eq("claude-sonnet-4-20250514")
      content["model"]["display_name"].should eq("Sonnet")

      # Context
      content["context"]["percentage"].should eq(45.2)
      content["context"]["tokens_used"].should eq(90400)
      content["context"]["tokens_max"].should eq(200000)

      # Cost
      content["cost"]["usd"].should eq(0.42)
      content["cost"]["lines_added"].should eq(45)
      content["cost"]["lines_removed"].should eq(12)

      # Clean up
      FileUtils.rm_rf(session_dir.to_s)
    end

    it "creates session directory just-in-time" do
      session_id = "test-jit-session-#{Random.rand(100000)}"

      # Ensure session directory doesn't exist
      session_dir = GalaxyStatusline::ContextStatus.session_dir(session_id)
      FileUtils.rm_rf(session_dir.to_s) if Dir.exists?(session_dir)
      Dir.exists?(session_dir).should eq(false)

      # Create input with this session_id
      json = %|{"session_id": "#{session_id}", "context_window": {"used_percentage": 50.0}}|
      input = GalaxyStatusline::ClaudeInput.parse(json)

      # Write should create the directory
      GalaxyStatusline::ContextStatus.write(input)

      # Verify directory was created
      Dir.exists?(session_dir).should eq(true)

      # Clean up
      FileUtils.rm_rf(session_dir.to_s)
    end

    it "skips writing when session_id is missing" do
      # Create input without session_id
      json = %|{"context_window": {"used_percentage": 50.0}}|
      input = GalaxyStatusline::ClaudeInput.parse(json)

      # Should not raise, should silently skip
      GalaxyStatusline::ContextStatus.write(input)

      # No way to verify nothing was written without knowing what session_id would be
      # but we can verify it didn't crash
    end

    it "isolates different sessions to different directories" do
      session_id_1 = "test-session-1-#{Random.rand(100000)}"
      session_id_2 = "test-session-2-#{Random.rand(100000)}"

      # Clean up
      FileUtils.rm_rf(GalaxyStatusline::ContextStatus.session_dir(session_id_1).to_s)
      FileUtils.rm_rf(GalaxyStatusline::ContextStatus.session_dir(session_id_2).to_s)

      # Write to session 1 with 30%
      json1 = %|{"session_id": "#{session_id_1}", "context_window": {"used_percentage": 30.0}}|
      input1 = GalaxyStatusline::ClaudeInput.parse(json1)
      GalaxyStatusline::ContextStatus.write(input1)

      # Write to session 2 with 70%
      json2 = %|{"session_id": "#{session_id_2}", "context_window": {"used_percentage": 70.0}}|
      input2 = GalaxyStatusline::ClaudeInput.parse(json2)
      GalaxyStatusline::ContextStatus.write(input2)

      # Verify each session has its own file with correct data
      file1 = GalaxyStatusline::ContextStatus.path_for_session(session_id_1)
      file2 = GalaxyStatusline::ContextStatus.path_for_session(session_id_2)

      content1 = JSON.parse(File.read(file1))
      content2 = JSON.parse(File.read(file2))

      content1["session_id"].should eq(session_id_1)
      content1["context"]["percentage"].should eq(30.0)

      content2["session_id"].should eq(session_id_2)
      content2["context"]["percentage"].should eq(70.0)

      # Clean up
      FileUtils.rm_rf(GalaxyStatusline::ContextStatus.session_dir(session_id_1).to_s)
      FileUtils.rm_rf(GalaxyStatusline::ContextStatus.session_dir(session_id_2).to_s)
    end

    it "handles partial input gracefully" do
      session_id = "test-partial-session-#{Random.rand(100000)}"

      # Clean up
      FileUtils.rm_rf(GalaxyStatusline::ContextStatus.session_dir(session_id).to_s)

      # Create input with only session_id (minimal payload)
      json = %|{"session_id": "#{session_id}"}|
      input = GalaxyStatusline::ClaudeInput.parse(json)
      GalaxyStatusline::ContextStatus.write(input)

      # Verify file was written with nulls for missing fields
      file = GalaxyStatusline::ContextStatus.path_for_session(session_id)
      content = JSON.parse(File.read(file))

      content["session_id"].should eq(session_id)
      content["timestamp"].as_i64.should be > 0
      content["cwd"]?.try(&.raw).should be_nil
      content["workspace"]?.try(&.raw).should be_nil
      content["model"]?.try(&.raw).should be_nil
      content["claude_version"]?.try(&.raw).should be_nil
      content["context"]?.try(&.raw).should be_nil
      content["cost"]?.try(&.raw).should be_nil

      # Clean up
      FileUtils.rm_rf(GalaxyStatusline::ContextStatus.session_dir(session_id).to_s)
    end
  end

  describe ".read" do
    it "reads context status from session-specific file" do
      session_id = "test-read-session-#{Random.rand(100000)}"

      # Write a status first using full payload
      json = read_fixture("claude_input/valid_complete.json").gsub("abc123", session_id)
      input = GalaxyStatusline::ClaudeInput.parse(json)
      GalaxyStatusline::ContextStatus.write(input)

      # Read it back
      status = GalaxyStatusline::ContextStatus.read(session_id)
      status.should_not be_nil

      s = status.not_nil!
      s.session_id.should eq(session_id)
      s.cwd.should eq("/current/working/directory")
      s.claude_version.should eq("1.0.80")
      s.model.not_nil!.id.should eq("claude-sonnet-4-20250514")
      s.model.not_nil!.display_name.should eq("Sonnet")
      s.context.not_nil!.percentage.should eq(45.2)
      s.context.not_nil!.tokens_used.should eq(90400)
      s.context.not_nil!.tokens_max.should eq(200000)
      s.cost.not_nil!.usd.should eq(0.42)
      s.cost.not_nil!.lines_added.should eq(45)
      s.cost.not_nil!.lines_removed.should eq(12)

      # Clean up
      FileUtils.rm_rf(GalaxyStatusline::ContextStatus.session_dir(session_id).to_s)
    end

    it "returns nil when session directory doesn't exist" do
      session_id = "nonexistent-session-#{Random.rand(100000)}"

      # Ensure it doesn't exist
      session_dir = GalaxyStatusline::ContextStatus.session_dir(session_id)
      FileUtils.rm_rf(session_dir.to_s) if Dir.exists?(session_dir)

      # Read should return nil
      status = GalaxyStatusline::ContextStatus.read(session_id)
      status.should be_nil
    end

    it "returns nil for empty session_id" do
      status = GalaxyStatusline::ContextStatus.read("")
      status.should be_nil
    end
  end

  describe ".path_for_session" do
    it "returns correct path for session" do
      path = GalaxyStatusline::ContextStatus.path_for_session("my-session")
      path.to_s.should contain("sessions")
      path.to_s.should contain("my-session")
      path.to_s.should end_with("context-status.json")
    end
  end

  describe ".session_dir" do
    it "returns correct directory for session" do
      dir = GalaxyStatusline::ContextStatus.session_dir("my-session")
      dir.to_s.should contain("sessions")
      dir.to_s.should end_with("my-session")
    end
  end

  describe "#to_pretty_json" do
    it "produces valid JSON with full payload" do
      status = GalaxyStatusline::ContextStatus.new(
        session_id: "test-session",
        cwd: "/test/path",
        workspace: GalaxyStatusline::ContextStatus::Workspace.new("/current", "/project"),
        model: GalaxyStatusline::ContextStatus::Model.new("claude-sonnet-4", "Sonnet"),
        claude_version: "1.0.80",
        context: GalaxyStatusline::ContextStatus::Context.new(72.5, 145000_i64, 200000_i64),
        cost: GalaxyStatusline::ContextStatus::Cost.new(0.50, 100, 25)
      )

      json = status.to_pretty_json
      parsed = JSON.parse(json)

      parsed["session_id"].should eq("test-session")
      parsed["cwd"].should eq("/test/path")
      parsed["claude_version"].should eq("1.0.80")
      parsed["workspace"]["current_dir"].should eq("/current")
      parsed["workspace"]["project_dir"].should eq("/project")
      parsed["model"]["id"].should eq("claude-sonnet-4")
      parsed["model"]["display_name"].should eq("Sonnet")
      parsed["context"]["percentage"].should eq(72.5)
      parsed["context"]["tokens_used"].should eq(145000)
      parsed["context"]["tokens_max"].should eq(200000)
      parsed["cost"]["usd"].should eq(0.50)
      parsed["cost"]["lines_added"].should eq(100)
      parsed["cost"]["lines_removed"].should eq(25)
      parsed["timestamp"].as_i64.should be > 0
    end
  end
end
