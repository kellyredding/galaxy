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

        # No entry records should be created for regular file reads
        entries = GalaxyLedger::Database.query_by_session(ledger_session_id)
        entries.size.should eq(0)

        # Should have a session_file record instead
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

      it "creates an extraction_marker entry for agent-guidelines files" do
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

        entries = GalaxyLedger::Database.query_by_type(ledger_session_id, "extraction_marker")
        entries.size.should eq(1)
        entries.first.entry_type.should eq("extraction_marker")
        entries.first.importance.should eq("medium")
        entries.first.source_file.should eq("/home/user/agent-guidelines/ruby-style.md")

        # Metadata should contain the original extraction type
        meta = JSON.parse(entries.first.metadata.not_nil!)
        meta["extraction_type"]?.try(&.as_s?).should eq("guideline")

        # Should also have a session_file record (regression: special files
        # must be tracked in session_files, not just extraction markers)
        files = GalaxyLedger::Database.session_files(ledger_session_id)
        files.size.should eq(1)
        files.first.file_path.should eq("/home/user/agent-guidelines/ruby-style.md")
        files.first.is_read.should be_true

        # Clean up
        GalaxyLedger::Database.delete_session(session_id)
      end

      it "creates an extraction_marker entry for any file in agent-guidelines" do
        session_id = "post-tool-test-#{rand(100000)}"
        ledger_session_id = GalaxyLedger::Database.create_session(session_id)

        input = {
          "session_id"      => session_id,
          "tool_name"       => "Read",
          "tool_input"      => {"file_path" => "/home/user/agent-guidelines/git-workflow.md"},
          "tool_response"   => "workflow guide",
          "hook_event_name" => "PostToolUse",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: input)
        result[:status].should eq(0)

        entries = GalaxyLedger::Database.query_by_type(ledger_session_id, "extraction_marker")
        entries.size.should eq(1)
        entries.first.entry_type.should eq("extraction_marker")

        # Clean up
        GalaxyLedger::Database.delete_session(session_id)
      end

      it "creates an extraction_marker entry for implementation-plans files" do
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

        entries = GalaxyLedger::Database.query_by_type(ledger_session_id, "extraction_marker")
        entries.size.should eq(1)
        entries.first.entry_type.should eq("extraction_marker")
        entries.first.importance.should eq("medium")

        # Metadata should contain implementation_plan as extraction type
        meta = JSON.parse(entries.first.metadata.not_nil!)
        meta["extraction_type"]?.try(&.as_s?).should eq("implementation_plan")

        # Should also have a session_file record (regression: special files
        # must be tracked in session_files, not just extraction markers)
        files = GalaxyLedger::Database.session_files(ledger_session_id)
        files.size.should eq(1)
        files.first.file_path.should eq("/home/user/implementation-plans/feature-x.md")
        files.first.is_read.should be_true

        # Clean up
        GalaxyLedger::Database.delete_session(session_id)
      end
    end

    describe "extraction deduplication" do
      it "skips extraction on second read of same guideline file" do
        session_id = "post-tool-dedup-#{rand(100000)}"
        ledger_session_id = GalaxyLedger::Database.create_session(session_id)

        input = {
          "session_id"      => session_id,
          "tool_name"       => "Read",
          "tool_input"      => {"file_path" => "/home/user/agent-guidelines/ruby-style.md"},
          "tool_response"   => "guideline contents",
          "hook_event_name" => "PostToolUse",
        }.to_json

        # First read — should create extraction_marker entry with full path source_file
        result = run_binary(["on-post-tool-use"], stdin: input)
        result[:status].should eq(0)

        markers = GalaxyLedger::Database.query_by_type(ledger_session_id, "extraction_marker")
        markers.size.should eq(1)
        markers.first.source_file.should eq("/home/user/agent-guidelines/ruby-style.md")

        # Pre-flight check should now return true
        GalaxyLedger::Database.has_extracted_source_file?(ledger_session_id, "/home/user/agent-guidelines/ruby-style.md").should be_true

        # First marker should have extraction_spawned: true and extraction_type: guideline
        meta = JSON.parse(markers.first.metadata.not_nil!)
        meta["extraction_spawned"]?.try(&.as_bool?).should be_true
        meta["extraction_type"]?.try(&.as_s?).should eq("guideline")

        # Second read — entry count shouldn't increase (unique index + pre-flight)
        result = run_binary(["on-post-tool-use"], stdin: input)
        result[:status].should eq(0)

        markers_after = GalaxyLedger::Database.query_by_type(ledger_session_id, "extraction_marker")
        markers_after.size.should eq(1) # No new marker entry (same content_hash)

        # Clean up
        GalaxyLedger::Database.delete_session(session_id)
      end

      it "skips extraction on second read of same implementation plan" do
        session_id = "post-tool-dedup-#{rand(100000)}"
        ledger_session_id = GalaxyLedger::Database.create_session(session_id)

        input = {
          "session_id"      => session_id,
          "tool_name"       => "Read",
          "tool_input"      => {"file_path" => "/home/user/implementation-plans/feature.md"},
          "tool_response"   => "plan contents",
          "hook_event_name" => "PostToolUse",
        }.to_json

        # First read
        result = run_binary(["on-post-tool-use"], stdin: input)
        result[:status].should eq(0)

        GalaxyLedger::Database.has_extracted_source_file?(ledger_session_id, "/home/user/implementation-plans/feature.md").should be_true

        # Second read — no new entries
        result = run_binary(["on-post-tool-use"], stdin: input)
        result[:status].should eq(0)

        markers = GalaxyLedger::Database.query_by_type(ledger_session_id, "extraction_marker")
        markers.size.should eq(1)

        # Clean up
        GalaxyLedger::Database.delete_session(session_id)
      end

      it "allows extraction for different guideline files in same session" do
        session_id = "post-tool-dedup-#{rand(100000)}"
        ledger_session_id = GalaxyLedger::Database.create_session(session_id)

        # Read first guideline
        input1 = {
          "session_id"      => session_id,
          "tool_name"       => "Read",
          "tool_input"      => {"file_path" => "/home/user/agent-guidelines/ruby-style.md"},
          "tool_response"   => "ruby style contents",
          "hook_event_name" => "PostToolUse",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: input1)
        result[:status].should eq(0)

        # Read different guideline
        input2 = {
          "session_id"      => session_id,
          "tool_name"       => "Read",
          "tool_input"      => {"file_path" => "/home/user/agent-guidelines/rspec-style.md"},
          "tool_response"   => "rspec style contents",
          "hook_event_name" => "PostToolUse",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: input2)
        result[:status].should eq(0)

        markers = GalaxyLedger::Database.query_by_type(ledger_session_id, "extraction_marker")
        markers.size.should eq(2)

        # Both should have spawned extraction
        metadata_values = markers.map do |e|
          if meta = e.metadata
            JSON.parse(meta)["extraction_spawned"]?.try(&.as_bool?)
          end
        end

        metadata_values.all? { |v| v == true }.should be_true

        # Clean up
        GalaxyLedger::Database.delete_session(session_id)
      end
    end

    describe "with Edit tool" do
      it "creates a session file record" do
        session_id = "post-tool-test-#{rand(100000)}"
        ledger_session_id = GalaxyLedger::Database.create_session(session_id)

        input = {
          "session_id" => session_id,
          "tool_name"  => "Edit",
          "tool_input" => {
            "file_path"  => "/path/to/file.rb",
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

        # Should have a session_file record instead
        files = GalaxyLedger::Database.session_files(ledger_session_id)
        files.size.should eq(1)
        files.first.file_path.should eq("/path/to/file.rb")
        files.first.is_edited.should be_true
        files.first.is_read.should be_false
        files.first.is_written.should be_false
        files.first.is_searched.should be_false

        # Clean up
        GalaxyLedger::Database.delete_session(session_id)
      end
    end

    describe "with Write tool" do
      it "creates a session file record" do
        session_id = "post-tool-test-#{rand(100000)}"
        ledger_session_id = GalaxyLedger::Database.create_session(session_id)

        input = {
          "session_id" => session_id,
          "tool_name"  => "Write",
          "tool_input" => {
            "file_path" => "/path/to/new_file.rb",
            "content"   => "file content",
          },
          "tool_response"   => "success",
          "hook_event_name" => "PostToolUse",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: input)
        result[:status].should eq(0)

        # No entry records should be created for file writes
        entries = GalaxyLedger::Database.query_by_session(ledger_session_id)
        entries.size.should eq(0)

        # Should have a session_file record instead
        files = GalaxyLedger::Database.session_files(ledger_session_id)
        files.size.should eq(1)
        files.first.file_path.should eq("/path/to/new_file.rb")
        files.first.is_written.should be_true
        files.first.is_read.should be_false
        files.first.is_edited.should be_false
        files.first.is_searched.should be_false

        # Clean up
        GalaxyLedger::Database.delete_session(session_id)
      end
    end

    describe "stale extraction marking" do
      it "marks extraction_marker entries stale when editing a guideline file" do
        session_id = "post-tool-stale-#{rand(100000)}"
        ledger_session_id = GalaxyLedger::Database.create_session(session_id)

        # First: read the guideline to create extraction_marker entry
        read_input = {
          "session_id"      => session_id,
          "tool_name"       => "Read",
          "tool_input"      => {"file_path" => "/home/user/agent-guidelines/ruby-style.md"},
          "tool_response"   => "guideline contents",
          "hook_event_name" => "PostToolUse",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: read_input)
        result[:status].should eq(0)

        # Verify marker exists and is not stale
        GalaxyLedger::Database.has_extracted_source_file?(ledger_session_id, "/home/user/agent-guidelines/ruby-style.md").should be_true
        GalaxyLedger::Database.stale_entries(ledger_session_id).should be_empty

        # Second: edit the guideline file
        edit_input = {
          "session_id" => session_id,
          "tool_name"  => "Edit",
          "tool_input" => {
            "file_path"  => "/home/user/agent-guidelines/ruby-style.md",
            "old_string" => "old",
            "new_string" => "new",
          },
          "tool_response"   => "success",
          "hook_event_name" => "PostToolUse",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: edit_input)
        result[:status].should eq(0)

        # Marker should now be stale
        stale = GalaxyLedger::Database.stale_entries(ledger_session_id)
        stale.size.should eq(1)
        stale[0][:source_file].should eq("/home/user/agent-guidelines/ruby-style.md")
        stale[0][:entry_type].should eq("guideline")

        # Clean up
        GalaxyLedger::Database.delete_session(session_id)
      end

      it "marks extraction_marker entries stale when writing a plan file" do
        session_id = "post-tool-stale-#{rand(100000)}"
        ledger_session_id = GalaxyLedger::Database.create_session(session_id)

        # First: read the plan to create extraction_marker entry
        read_input = {
          "session_id"      => session_id,
          "tool_name"       => "Read",
          "tool_input"      => {"file_path" => "/home/user/implementation-plans/feature.md"},
          "tool_response"   => "plan contents",
          "hook_event_name" => "PostToolUse",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: read_input)
        result[:status].should eq(0)

        # Verify marker exists and is not stale
        GalaxyLedger::Database.has_extracted_source_file?(ledger_session_id, "/home/user/implementation-plans/feature.md").should be_true
        GalaxyLedger::Database.stale_entries(ledger_session_id).should be_empty

        # Second: write to the plan file
        write_input = {
          "session_id" => session_id,
          "tool_name"  => "Write",
          "tool_input" => {
            "file_path" => "/home/user/implementation-plans/feature.md",
            "content"   => "updated plan",
          },
          "tool_response"   => "success",
          "hook_event_name" => "PostToolUse",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: write_input)
        result[:status].should eq(0)

        # Marker should now be stale
        stale = GalaxyLedger::Database.stale_entries(ledger_session_id)
        stale.size.should eq(1)
        stale[0][:source_file].should eq("/home/user/implementation-plans/feature.md")
        stale[0][:entry_type].should eq("implementation_plan")

        # Clean up
        GalaxyLedger::Database.delete_session(session_id)
      end

      it "does not mark entries stale when editing a regular file" do
        session_id = "post-tool-stale-#{rand(100000)}"
        ledger_session_id = GalaxyLedger::Database.create_session(session_id)

        # Read a guideline first
        read_input = {
          "session_id"      => session_id,
          "tool_name"       => "Read",
          "tool_input"      => {"file_path" => "/home/user/agent-guidelines/ruby-style.md"},
          "tool_response"   => "guideline contents",
          "hook_event_name" => "PostToolUse",
        }.to_json

        run_binary(["on-post-tool-use"], stdin: read_input)

        # Edit a regular file (not a guideline)
        edit_input = {
          "session_id" => session_id,
          "tool_name"  => "Edit",
          "tool_input" => {
            "file_path"  => "/home/user/src/app.rb",
            "old_string" => "old",
            "new_string" => "new",
          },
          "tool_response"   => "success",
          "hook_event_name" => "PostToolUse",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: edit_input)
        result[:status].should eq(0)

        # Nothing should be stale
        GalaxyLedger::Database.stale_entries(ledger_session_id).should be_empty

        # Clean up
        GalaxyLedger::Database.delete_session(session_id)
      end
    end

    describe "with Grep tool" do
      it "creates a session file record with search pattern" do
        session_id = "post-tool-test-#{rand(100000)}"
        ledger_session_id = GalaxyLedger::Database.create_session(session_id)

        input = {
          "session_id" => session_id,
          "tool_name"  => "Grep",
          "tool_input" => {
            "pattern" => "def authenticate",
            "path"    => "/app/models",
          },
          "tool_response"   => "matches",
          "hook_event_name" => "PostToolUse",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: input)
        result[:status].should eq(0)

        # No entry records should be created for searches
        entries = GalaxyLedger::Database.query_by_session(ledger_session_id)
        entries.size.should eq(0)

        # Should have a session_file record with search pattern
        files = GalaxyLedger::Database.session_files(ledger_session_id)
        files.size.should eq(1)
        files.first.file_path.should eq("/app/models")
        files.first.search_pattern.should eq("def authenticate")
        files.first.is_searched.should be_true
        files.first.is_read.should be_false
        files.first.is_edited.should be_false
        files.first.is_written.should be_false

        # Clean up
        GalaxyLedger::Database.delete_session(session_id)
      end
    end

    describe "with Glob tool" do
      it "creates a session file record with search pattern" do
        session_id = "post-tool-test-#{rand(100000)}"
        ledger_session_id = GalaxyLedger::Database.create_session(session_id)

        input = {
          "session_id" => session_id,
          "tool_name"  => "Glob",
          "tool_input" => {
            "pattern" => "**/*.rb",
            "path"    => "/app",
          },
          "tool_response"   => "files",
          "hook_event_name" => "PostToolUse",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: input)
        result[:status].should eq(0)

        # No entry records should be created for searches
        entries = GalaxyLedger::Database.query_by_session(ledger_session_id)
        entries.size.should eq(0)

        # Should have a session_file record with search pattern
        files = GalaxyLedger::Database.session_files(ledger_session_id)
        files.size.should eq(1)
        files.first.file_path.should eq("/app")
        files.first.search_pattern.should eq("**/*.rb")
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
      patterns.any?(&.matches?("/project/agent-guidelines/l.md")).should be_true
    end

    it "does not match files outside agent-guidelines" do
      patterns.any?(&.matches?("/path/to/regular.md")).should be_false
      patterns.any?(&.matches?("/path/to/file.rb")).should be_false
      patterns.any?(&.matches?("/docs/ruby-style.md")).should be_false
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
