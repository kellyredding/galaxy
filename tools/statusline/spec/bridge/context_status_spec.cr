require "../spec_helper"

describe GalaxyStatusline::ContextStatus do
  describe ".write" do
    it "writes context status to session-specific bridge file" do
      # Create a test input
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

      # Verify the content (session_id is NOT stored - it's implicit from path)
      content = JSON.parse(File.read(bridge_file))
      content["percentage"].should eq(45.2)
      content["timestamp"].as_i64.should be > 0
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

      # session_id is NOT stored - it's implicit from the folder path
      content1["percentage"].should eq(30.0)
      content2["percentage"].should eq(70.0)

      # Clean up
      FileUtils.rm_rf(GalaxyStatusline::ContextStatus.session_dir(session_id_1).to_s)
      FileUtils.rm_rf(GalaxyStatusline::ContextStatus.session_dir(session_id_2).to_s)
    end
  end

  describe ".read" do
    it "reads context status from session-specific file" do
      session_id = "test-read-session-#{Random.rand(100000)}"

      # Write a status first
      json = %|{"session_id": "#{session_id}", "context_window": {"used_percentage": 65.5}, "model": {"id": "claude-sonnet-4"}}|
      input = GalaxyStatusline::ClaudeInput.parse(json)
      GalaxyStatusline::ContextStatus.write(input)

      # Read it back
      status = GalaxyStatusline::ContextStatus.read(session_id)
      status.should_not be_nil
      status.not_nil!.percentage.should eq(65.5)
      status.not_nil!.model.should eq("claude-sonnet-4")

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
    it "produces valid JSON" do
      status = GalaxyStatusline::ContextStatus.new(
        percentage: 72.5,
        model: "claude-sonnet-4-20250514"
      )

      json = status.to_pretty_json
      parsed = JSON.parse(json)

      parsed["percentage"].should eq(72.5)
      parsed["model"].should eq("claude-sonnet-4-20250514")
      parsed["timestamp"].as_i64.should be > 0
    end
  end
end
