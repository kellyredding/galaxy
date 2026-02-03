require "../spec_helper"

describe GalaxyLedger::Hooks::OnPostToolUse do
  describe "#run" do
    describe "with Read tool" do
      it "creates a file_read entry for regular files" do
        session_id = "post-tool-test-#{rand(100000)}"
        session_dir = GalaxyLedger::SESSIONS_DIR / session_id
        Dir.mkdir_p(session_dir)

        input = {
          "session_id"      => session_id,
          "tool_name"       => "Read",
          "tool_input"      => {"file_path" => "/path/to/some/file.rb"},
          "tool_result"     => "file contents",
          "hook_event_name" => "PostToolUse",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: input)
        result[:status].should eq(0)

        entries = GalaxyLedger::Buffer.read(session_id)
        entries.size.should eq(1)
        entries.first.entry_type.should eq("file_read")
        entries.first.content.should eq("/path/to/some/file.rb")
        entries.first.importance.should eq("low")
      end

      it "creates a guideline entry for agent-guidelines files" do
        session_id = "post-tool-test-#{rand(100000)}"
        session_dir = GalaxyLedger::SESSIONS_DIR / session_id
        Dir.mkdir_p(session_dir)

        input = {
          "session_id"      => session_id,
          "tool_name"       => "Read",
          "tool_input"      => {"file_path" => "/home/user/agent-guidelines/ruby-style.md"},
          "tool_result"     => "guideline contents",
          "hook_event_name" => "PostToolUse",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: input)
        result[:status].should eq(0)

        entries = GalaxyLedger::Buffer.read(session_id)
        entries.size.should eq(1)
        entries.first.entry_type.should eq("guideline")
        entries.first.importance.should eq("medium")
      end

      it "creates a guideline entry for *-style.md files" do
        session_id = "post-tool-test-#{rand(100000)}"
        session_dir = GalaxyLedger::SESSIONS_DIR / session_id
        Dir.mkdir_p(session_dir)

        input = {
          "session_id"      => session_id,
          "tool_name"       => "Read",
          "tool_input"      => {"file_path" => "/home/user/docs/rspec-style.md"},
          "tool_result"     => "style guide",
          "hook_event_name" => "PostToolUse",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: input)
        result[:status].should eq(0)

        entries = GalaxyLedger::Buffer.read(session_id)
        entries.size.should eq(1)
        entries.first.entry_type.should eq("guideline")
      end

      it "creates an implementation_plan entry for implementation-plans files" do
        session_id = "post-tool-test-#{rand(100000)}"
        session_dir = GalaxyLedger::SESSIONS_DIR / session_id
        Dir.mkdir_p(session_dir)

        input = {
          "session_id"      => session_id,
          "tool_name"       => "Read",
          "tool_input"      => {"file_path" => "/home/user/implementation-plans/feature-x.md"},
          "tool_result"     => "plan contents",
          "hook_event_name" => "PostToolUse",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: input)
        result[:status].should eq(0)

        entries = GalaxyLedger::Buffer.read(session_id)
        entries.size.should eq(1)
        entries.first.entry_type.should eq("implementation_plan")
        entries.first.importance.should eq("medium")
      end
    end

    describe "with Edit tool" do
      it "creates a file_edit entry" do
        session_id = "post-tool-test-#{rand(100000)}"
        session_dir = GalaxyLedger::SESSIONS_DIR / session_id
        Dir.mkdir_p(session_dir)

        input = {
          "session_id"      => session_id,
          "tool_name"       => "Edit",
          "tool_input"      => {
            "file_path"  => "/path/to/file.rb",
            "old_string" => "old",
            "new_string" => "new",
          },
          "tool_result"     => "success",
          "hook_event_name" => "PostToolUse",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: input)
        result[:status].should eq(0)

        entries = GalaxyLedger::Buffer.read(session_id)
        entries.size.should eq(1)
        entries.first.entry_type.should eq("file_edit")
        entries.first.content.should eq("/path/to/file.rb")
        entries.first.importance.should eq("medium")
      end
    end

    describe "with Write tool" do
      it "creates a file_write entry" do
        session_id = "post-tool-test-#{rand(100000)}"
        session_dir = GalaxyLedger::SESSIONS_DIR / session_id
        Dir.mkdir_p(session_dir)

        input = {
          "session_id"      => session_id,
          "tool_name"       => "Write",
          "tool_input"      => {
            "file_path" => "/path/to/new_file.rb",
            "content"   => "file content",
          },
          "tool_result"     => "success",
          "hook_event_name" => "PostToolUse",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: input)
        result[:status].should eq(0)

        entries = GalaxyLedger::Buffer.read(session_id)
        entries.size.should eq(1)
        entries.first.entry_type.should eq("file_write")
        entries.first.content.should eq("/path/to/new_file.rb")
        entries.first.importance.should eq("medium")
      end
    end

    describe "with Grep tool" do
      it "creates a search entry" do
        session_id = "post-tool-test-#{rand(100000)}"
        session_dir = GalaxyLedger::SESSIONS_DIR / session_id
        Dir.mkdir_p(session_dir)

        input = {
          "session_id"      => session_id,
          "tool_name"       => "Grep",
          "tool_input"      => {
            "pattern" => "def authenticate",
            "path"    => "/app/models",
          },
          "tool_result"     => "matches",
          "hook_event_name" => "PostToolUse",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: input)
        result[:status].should eq(0)

        entries = GalaxyLedger::Buffer.read(session_id)
        entries.size.should eq(1)
        entries.first.entry_type.should eq("search")
        entries.first.content.should eq("def authenticate in /app/models")
        entries.first.importance.should eq("low")
      end
    end

    describe "with Glob tool" do
      it "creates a search entry" do
        session_id = "post-tool-test-#{rand(100000)}"
        session_dir = GalaxyLedger::SESSIONS_DIR / session_id
        Dir.mkdir_p(session_dir)

        input = {
          "session_id"      => session_id,
          "tool_name"       => "Glob",
          "tool_input"      => {
            "pattern" => "**/*.rb",
            "path"    => "/app",
          },
          "tool_result"     => "files",
          "hook_event_name" => "PostToolUse",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: input)
        result[:status].should eq(0)

        entries = GalaxyLedger::Buffer.read(session_id)
        entries.size.should eq(1)
        entries.first.entry_type.should eq("search")
        entries.first.content.should eq("**/*.rb in /app")
      end
    end

    describe "with missing or invalid input" do
      it "handles empty input gracefully" do
        result = run_binary(["on-post-tool-use"], stdin: "")
        result[:status].should eq(0)
      end

      it "handles invalid JSON gracefully" do
        result = run_binary(["on-post-tool-use"], stdin: "not json")
        result[:status].should eq(0)
      end

      it "handles missing session_id gracefully" do
        input = {
          "tool_name"   => "Read",
          "tool_input"  => {"file_path" => "/path/to/file.rb"},
          "tool_result" => "contents",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: input)
        result[:status].should eq(0)
      end

      it "handles unsupported tool_name gracefully" do
        session_id = "post-tool-test-#{rand(100000)}"
        session_dir = GalaxyLedger::SESSIONS_DIR / session_id
        Dir.mkdir_p(session_dir)

        input = {
          "session_id"  => session_id,
          "tool_name"   => "UnsupportedTool",
          "tool_input"  => {"dummy" => "value"},
          "tool_result" => "result",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: input)
        result[:status].should eq(0)

        # No entry should be created
        entries = GalaxyLedger::Buffer.read(session_id)
        entries.size.should eq(0)
      end
    end
  end

  describe "CLI help" do
    it "shows help with -h flag" do
      result = run_binary(["on-post-tool-use", "-h"])
      result[:status].should eq(0)

      result[:output].should contain("on-post-tool-use")
      result[:output].should contain("PostToolUse")
      result[:output].should contain("USAGE")
      result[:output].should contain("tool_name")
      result[:output].should contain("ENTRY TYPES CREATED")
    end

    it "shows help with --help flag" do
      result = run_binary(["on-post-tool-use", "--help"])
      result[:status].should eq(0)
      result[:output].should contain("on-post-tool-use")
    end
  end
end

describe GalaxyLedger::Hooks::OnPostToolUse, "pattern matching" do
  describe "GUIDELINE_PATTERNS" do
    patterns = GalaxyLedger::Hooks::OnPostToolUse::GUIDELINE_PATTERNS

    it "matches /agent-guidelines/ paths" do
      patterns.any?(&.matches?("/home/user/agent-guidelines/ruby-style.md")).should be_true
      patterns.any?(&.matches?("/project/agent-guidelines/test.md")).should be_true
    end

    it "matches *-style.md files" do
      patterns.any?(&.matches?("/docs/ruby-style.md")).should be_true
      patterns.any?(&.matches?("/project/rspec-style.md")).should be_true
      patterns.any?(&.matches?("/kajabi-style.md")).should be_true
    end

    it "does not match regular files" do
      patterns.any?(&.matches?("/path/to/regular.md")).should be_false
      patterns.any?(&.matches?("/path/to/file.rb")).should be_false
      patterns.any?(&.matches?("/path/style/file.md")).should be_false
    end
  end

  describe "IMPLEMENTATION_PLAN_PATTERNS" do
    patterns = GalaxyLedger::Hooks::OnPostToolUse::IMPLEMENTATION_PLAN_PATTERNS

    it "matches /implementation-plans/ paths" do
      patterns.any?(&.matches?("/home/user/implementation-plans/feature.md")).should be_true
      patterns.any?(&.matches?("/project/implementation-plans/2026-01-01_plan.md")).should be_true
    end

    it "does not match regular files" do
      patterns.any?(&.matches?("/path/to/regular.md")).should be_false
      patterns.any?(&.matches?("/path/implementation/file.md")).should be_false
    end
  end
end
