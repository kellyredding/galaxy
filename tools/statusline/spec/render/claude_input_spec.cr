require "../spec_helper"

describe GalaxcStatusline::ClaudeInput do
  describe ".parse" do
    it "parses complete valid JSON" do
      json = read_fixture("claude_input/valid_complete.json")
      input = GalaxcStatusline::ClaudeInput.parse(json)

      input.hook_event_name.should eq("Status")
      input.session_id.should eq("abc123")
    end

    it "extracts cwd as current directory" do
      json = read_fixture("claude_input/valid_complete.json")
      input = GalaxcStatusline::ClaudeInput.parse(json)

      # cwd is preferred over workspace.current_dir
      input.current_directory.should eq("/current/working/directory")
    end

    it "extracts model.display_name" do
      json = read_fixture("claude_input/valid_complete.json")
      input = GalaxcStatusline::ClaudeInput.parse(json)

      input.model_name.should eq("Sonnet")
    end

    it "extracts cost.total_cost_usd" do
      json = read_fixture("claude_input/valid_complete.json")
      input = GalaxcStatusline::ClaudeInput.parse(json)

      input.total_cost.should eq(0.42)
    end

    it "extracts context_window.used_percentage" do
      json = read_fixture("claude_input/valid_complete.json")
      input = GalaxcStatusline::ClaudeInput.parse(json)

      input.context_percentage.should eq(45.2)
    end

    it "handles minimal input gracefully" do
      json = read_fixture("claude_input/valid_minimal.json")
      input = GalaxcStatusline::ClaudeInput.parse(json)

      input.current_directory.should eq("/tmp/test")
      input.model_name.should eq(nil)
      input.total_cost.should eq(nil)
      input.context_percentage.should eq(nil)
    end

    it "raises on malformed JSON" do
      json = read_fixture("claude_input/malformed.json")

      expect_raises(JSON::ParseException) do
        GalaxcStatusline::ClaudeInput.parse(json)
      end
    end
  end

  describe "#current_directory" do
    it "prefers cwd over workspace.current_dir" do
      json = read_fixture("claude_input/valid_complete.json")
      input = GalaxcStatusline::ClaudeInput.parse(json)

      # cwd should be preferred (actual working directory vs project root)
      input.current_directory.should eq("/current/working/directory")
    end

    it "falls back to workspace.current_dir when cwd missing" do
      json = %({"workspace": {"current_dir": "/fallback/dir"}})
      input = GalaxcStatusline::ClaudeInput.parse(json)

      input.current_directory.should eq("/fallback/dir")
    end
  end
end
