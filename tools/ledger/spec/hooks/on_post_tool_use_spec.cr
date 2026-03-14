require "../spec_helper"

describe "OnPostToolUse GALAXY_SKIP_HOOKS" do
  it "returns early when GALAXY_SKIP_HOOKS=1 is set" do
    ENV["GALAXY_SKIP_HOOKS"] = "1"

    session_id = "skip-hooks-test-#{rand(100000)}"
    ledger_session_id = GalaxyLedger::Database.create_session(session_id)

    input = {
      "session_id"      => session_id,
      "tool_name"       => "Read",
      "tool_input"      => {"file_path" => "/path/to/file.rb"},
      "tool_response"   => "file contents",
      "hook_event_name" => "PostToolUse",
    }.to_json

    result = run_binary(["on-post-tool-use"], stdin: input)
    result[:status].should eq(0)

    # Database should remain empty (early return, no entry created)
    entries = GalaxyLedger::Database.query_by_session(ledger_session_id)
    entries.size.should eq(0)

    # Clean up
    GalaxyLedger::Database.delete_session(session_id)
  ensure
    ENV.delete("GALAXY_SKIP_HOOKS")
  end
end

describe GalaxyLedger::Hooks::OnPostToolUse do
  describe "#run" do
    describe "with Read tool" do
      it "creates a session file record for regular files" do
        session_id = "post-tool-test-#{rand(100000)}"
        ledger_session_id = GalaxyLedger::Database.create_session(session_id)

        input = {
          "session_id"      => session_id,
          "tool_name"       => "Read",
          "tool_input"      => {"file_path" => "/path/to/some/file.rb"},
          "tool_response"   => "file contents",
          "hook_event_name" => "PostToolUse",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: input)
        result[:status].should eq(0)

        # No entry records should be created for file reads
        entries = GalaxyLedger::Database.query_by_session(ledger_session_id)
        entries.size.should eq(0)

        # Should have a session_file record
        files = GalaxyLedger::Database.session_files(ledger_session_id)
        files.size.should eq(1)
        files.first.file_path.should eq("/path/to/some/file.rb")
        files.first.is_read.should be_true
        files.first.is_edited.should be_false
        files.first.is_written.should be_false
        files.first.is_searched.should be_false

        # Clean up
        GalaxyLedger::Database.delete_session(session_id)
      end

      it "detects guideline file type for agent-guidelines files" do
        session_id = "post-tool-test-#{rand(100000)}"
        ledger_session_id = GalaxyLedger::Database.create_session(session_id)

        input = {
          "session_id"      => session_id,
          "tool_name"       => "Read",
          "tool_input"      => {"file_path" => "/home/user/agent-guidelines/ruby-style.md"},
          "tool_response"   => "guideline contents",
          "hook_event_name" => "PostToolUse",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: input)
        result[:status].should eq(0)

        # No extraction_marker entries should be created
        entries = GalaxyLedger::Database.query_by_session(ledger_session_id)
        entries.size.should eq(0)

        # Should have a session_file record with guideline file_type
        files = GalaxyLedger::Database.session_files(ledger_session_id)
        files.size.should eq(1)
        files.first.file_path.should eq("/home/user/agent-guidelines/ruby-style.md")
        files.first.file_type.should eq("guideline")
        files.first.is_read.should be_true

        # Clean up
        GalaxyLedger::Database.delete_session(session_id)
      end

      it "detects implementation_plan file type for plan files" do
        session_id = "post-tool-test-#{rand(100000)}"
        ledger_session_id = GalaxyLedger::Database.create_session(session_id)

        input = {
          "session_id"      => session_id,
          "tool_name"       => "Read",
          "tool_input"      => {"file_path" => "/home/user/implementation-plans/feature-x.md"},
          "tool_response"   => "plan contents",
          "hook_event_name" => "PostToolUse",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: input)
        result[:status].should eq(0)

        # No extraction_marker entries should be created
        entries = GalaxyLedger::Database.query_by_session(ledger_session_id)
        entries.size.should eq(0)

        # Should have a session_file record with implementation_plan file_type
        files = GalaxyLedger::Database.session_files(ledger_session_id)
        files.size.should eq(1)
        files.first.file_path.should eq("/home/user/implementation-plans/feature-x.md")
        files.first.file_type.should eq("implementation_plan")
        files.first.is_read.should be_true

        # Clean up
        GalaxyLedger::Database.delete_session(session_id)
      end

      it "detects source file type for src/ files" do
        session_id = "post-tool-test-#{rand(100000)}"
        ledger_session_id = GalaxyLedger::Database.create_session(session_id)

        input = {
          "session_id"      => session_id,
          "tool_name"       => "Read",
          "tool_input"      => {"file_path" => "/home/user/projects/myapp/src/main.cr"},
          "tool_response"   => "source code",
          "hook_event_name" => "PostToolUse",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: input)
        result[:status].should eq(0)

        files = GalaxyLedger::Database.session_files(ledger_session_id)
        files.size.should eq(1)
        files.first.file_type.should eq("source")

        # Clean up
        GalaxyLedger::Database.delete_session(session_id)
      end

      it "detects test file type for spec/ files" do
        session_id = "post-tool-test-#{rand(100000)}"
        ledger_session_id = GalaxyLedger::Database.create_session(session_id)

        input = {
          "session_id"      => session_id,
          "tool_name"       => "Read",
          "tool_input"      => {"file_path" => "/home/user/projects/myapp/spec/models/user_spec.cr"},
          "tool_response"   => "spec code",
          "hook_event_name" => "PostToolUse",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: input)
        result[:status].should eq(0)

        files = GalaxyLedger::Database.session_files(ledger_session_id)
        files.size.should eq(1)
        files.first.file_type.should eq("test")

        # Clean up
        GalaxyLedger::Database.delete_session(session_id)
      end

      it "preserves file_type on upsert (first classification wins)" do
        session_id = "post-tool-test-#{rand(100000)}"
        ledger_session_id = GalaxyLedger::Database.create_session(session_id)

        guideline_input = {
          "session_id"      => session_id,
          "tool_name"       => "Read",
          "tool_input"      => {"file_path" => "/home/user/agent-guidelines/ruby.md"},
          "tool_response"   => "contents",
          "hook_event_name" => "PostToolUse",
        }.to_json

        # First read
        run_binary(["on-post-tool-use"], stdin: guideline_input)

        # Second read — file_type should remain guideline
        run_binary(["on-post-tool-use"], stdin: guideline_input)

        files = GalaxyLedger::Database.session_files(ledger_session_id)
        files.size.should eq(1)
        files.first.file_type.should eq("guideline")
        files.first.access_count.should eq(2)

        # Clean up
        GalaxyLedger::Database.delete_session(session_id)
      end
    end

    describe "with Edit tool" do
      it "creates a session file record with file_type" do
        session_id = "post-tool-test-#{rand(100000)}"
        ledger_session_id = GalaxyLedger::Database.create_session(session_id)

        input = {
          "session_id" => session_id,
          "tool_name"  => "Edit",
          "tool_input" => {
            "file_path"  => "/home/user/projects/myapp/src/app.cr",
            "old_string" => "old",
            "new_string" => "new",
          },
          "tool_response"   => "success",
          "hook_event_name" => "PostToolUse",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: input)
        result[:status].should eq(0)

        # No entry records should be created for file edits
        entries = GalaxyLedger::Database.query_by_session(ledger_session_id)
        entries.size.should eq(0)

        # Should have a session_file record with file_type
        files = GalaxyLedger::Database.session_files(ledger_session_id)
        files.size.should eq(1)
        files.first.file_path.should eq("/home/user/projects/myapp/src/app.cr")
        files.first.file_type.should eq("source")
        files.first.is_edited.should be_true
        files.first.is_read.should be_false
        files.first.is_written.should be_false
        files.first.is_searched.should be_false

        # Clean up
        GalaxyLedger::Database.delete_session(session_id)
      end
    end

    describe "with Write tool" do
      it "creates a session file record with file_type" do
        session_id = "post-tool-test-#{rand(100000)}"
        ledger_session_id = GalaxyLedger::Database.create_session(session_id)

        input = {
          "session_id" => session_id,
          "tool_name"  => "Write",
          "tool_input" => {
            "file_path" => "/home/user/projects/myapp/spec/new_spec.cr",
            "content"   => "spec content",
          },
          "tool_response"   => "success",
          "hook_event_name" => "PostToolUse",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: input)
        result[:status].should eq(0)

        # No entry records should be created for file writes
        entries = GalaxyLedger::Database.query_by_session(ledger_session_id)
        entries.size.should eq(0)

        # Should have a session_file record with file_type
        files = GalaxyLedger::Database.session_files(ledger_session_id)
        files.size.should eq(1)
        files.first.file_path.should eq("/home/user/projects/myapp/spec/new_spec.cr")
        files.first.file_type.should eq("test")
        files.first.is_written.should be_true
        files.first.is_read.should be_false
        files.first.is_edited.should be_false
        files.first.is_searched.should be_false

        # Clean up
        GalaxyLedger::Database.delete_session(session_id)
      end
    end

    describe "with Grep tool" do
      it "creates a session file record with search pattern and file_type" do
        session_id = "post-tool-test-#{rand(100000)}"
        ledger_session_id = GalaxyLedger::Database.create_session(session_id)

        input = {
          "session_id" => session_id,
          "tool_name"  => "Grep",
          "tool_input" => {
            "pattern" => "def authenticate",
            "path"    => "/home/user/projects/myapp/app/models",
          },
          "tool_response"   => "matches",
          "hook_event_name" => "PostToolUse",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: input)
        result[:status].should eq(0)

        # No entry records should be created for searches
        entries = GalaxyLedger::Database.query_by_session(ledger_session_id)
        entries.size.should eq(0)

        # Should have a session_file record with search pattern and file_type
        files = GalaxyLedger::Database.session_files(ledger_session_id)
        files.size.should eq(1)
        files.first.file_path.should eq("/home/user/projects/myapp/app/models")
        files.first.search_pattern.should eq("def authenticate")
        files.first.file_type.should eq("source")
        files.first.is_searched.should be_true
        files.first.is_read.should be_false
        files.first.is_edited.should be_false
        files.first.is_written.should be_false

        # Clean up
        GalaxyLedger::Database.delete_session(session_id)
      end
    end

    describe "with Glob tool" do
      it "creates a session file record with search pattern and file_type" do
        session_id = "post-tool-test-#{rand(100000)}"
        ledger_session_id = GalaxyLedger::Database.create_session(session_id)

        input = {
          "session_id" => session_id,
          "tool_name"  => "Glob",
          "tool_input" => {
            "pattern" => "**/*.rb",
            "path"    => "/home/user/projects/myapp/spec/models",
          },
          "tool_response"   => "files",
          "hook_event_name" => "PostToolUse",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: input)
        result[:status].should eq(0)

        # No entry records should be created for searches
        entries = GalaxyLedger::Database.query_by_session(ledger_session_id)
        entries.size.should eq(0)

        # Should have a session_file record with search pattern and file_type
        files = GalaxyLedger::Database.session_files(ledger_session_id)
        files.size.should eq(1)
        files.first.file_path.should eq("/home/user/projects/myapp/spec/models")
        files.first.search_pattern.should eq("**/*.rb")
        files.first.file_type.should eq("test")
        files.first.is_searched.should be_true
        files.first.is_read.should be_false
        files.first.is_edited.should be_false
        files.first.is_written.should be_false

        # Clean up
        GalaxyLedger::Database.delete_session(session_id)
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
          "tool_name"     => "Read",
          "tool_input"    => {"file_path" => "/path/to/file.rb"},
          "tool_response" => "contents",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: input)
        result[:status].should eq(0)
      end

      it "handles unsupported tool_name gracefully" do
        session_id = "post-tool-test-#{rand(100000)}"
        ledger_session_id = GalaxyLedger::Database.create_session(session_id)

        input = {
          "session_id"    => session_id,
          "tool_name"     => "UnsupportedTool",
          "tool_input"    => {"dummy" => "value"},
          "tool_response" => "result",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: input)
        result[:status].should eq(0)

        # No entry should be created
        entries = GalaxyLedger::Database.query_by_session(ledger_session_id)
        entries.size.should eq(0)

        # Clean up
        GalaxyLedger::Database.delete_session(session_id)
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
    end

    it "shows help with --help flag" do
      result = run_binary(["on-post-tool-use", "--help"])
      result[:status].should eq(0)
      result[:output].should contain("on-post-tool-use")
    end
  end
end
