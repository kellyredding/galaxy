require "../spec_helper"

# Build a galaxy-artifacts stub script that logs its args
# to a file. Returns {stub_path, log_path}. The hook calls
# `galaxy-artifacts save ...` synchronously when a Write
# classifies as an artifact — this stub captures the exact
# argument list so specs can assert on it.
private def build_artifacts_logging_stub : {Path, Path}
  log_path = SPEC_GALAXY_DIR / "artifacts_invocations.log"
  stub_path = SPEC_GALAXY_DIR / "bin" / "galaxy-artifacts"

  File.write(stub_path, <<-BASH)
  #!/bin/bash
  echo "$@" >> "#{log_path}"
  exit 0
  BASH
  File.chmod(stub_path, 0o755)

  {stub_path, log_path}
end

# Restore the default no-op artifacts stub so other specs
# that don't care about this binary keep getting a clean
# `exit 0`.
private def restore_artifacts_noop
  stub_path = SPEC_GALAXY_DIR / "bin" / "galaxy-artifacts"
  File.write(stub_path, "#!/bin/sh\nexit 0\n")
  File.chmod(stub_path, 0o755)
end

private def read_artifacts_log(log_path : Path) : Array(String)
  return [] of String unless File.exists?(log_path)
  File.read_lines(log_path).reject(&.empty?)
end

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

    describe "with Write tool that classifies as an artifact" do
      it "passes --skip-event to galaxy-artifacts save" do
        _, log_path = build_artifacts_logging_stub
        File.delete(log_path) if File.exists?(log_path)

        # Real file on disk so the hook's File.size check
        # passes (size > 0 is required for the artifact
        # save to fire).
        artifact_path = "/tmp/galaxy-spec-artifact-#{rand(100000)}.csv"
        File.write(artifact_path, "col1,col2\n1,2\n")

        session_id = "post-tool-test-#{rand(100000)}"
        ledger_session_id = GalaxyLedger::Database
          .create_session(session_id)

        input = {
          "session_id" => session_id,
          "tool_name"  => "Write",
          "tool_input" => {
            "file_path" => artifact_path,
            "content"   => "col1,col2\n1,2\n",
          },
          "tool_response"   => "success",
          "hook_event_name" => "PostToolUse",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: input)
        result[:status].should eq(0)

        lines = read_artifacts_log(log_path)
        lines.size.should eq(1)
        lines.first.should contain("save")
        lines.first.should contain("--skip-event")
        lines.first.should contain("--artifact-type csv")
        lines.first.should contain(
          "--source-path #{artifact_path}"
        )

        # Session file row still recorded as before
        files = GalaxyLedger::Database.session_files(
          ledger_session_id
        )
        files.size.should eq(1)
        files.first.is_written.should be_true

        GalaxyLedger::Database.delete_session(session_id)
      ensure
        File.delete(artifact_path) if (
                                        artifact_path && File.exists?(artifact_path)
                                      )
        restore_artifacts_noop
      end

      it "does not invoke galaxy-artifacts for excluded paths" do
        # Implementation plans live in an excluded source
        # path — the hook must not classify them, so no
        # artifacts subprocess fires from the hook even
        # though the agent's explicit save (per the plan
        # guideline) still publishes the show event.
        _, log_path = build_artifacts_logging_stub
        File.delete(log_path) if File.exists?(log_path)

        # The exclusion regex matches the literal substring
        # "/implementation-plans/" — keep the unique suffix
        # on the parent dir so that segment is exact.
        parent_dir = "/tmp/galaxy-spec-#{rand(100000)}"
        plan_dir = "#{parent_dir}/implementation-plans"
        Dir.mkdir_p(plan_dir)
        plan_path = "#{plan_dir}/2026-04-29_01_test-plan.md"
        File.write(plan_path, "# Plan\n\nbody\n")

        session_id = "post-tool-test-#{rand(100000)}"
        GalaxyLedger::Database.create_session(session_id)

        input = {
          "session_id" => session_id,
          "tool_name"  => "Write",
          "tool_input" => {
            "file_path" => plan_path,
            "content"   => "# Plan\n\nbody\n",
          },
          "tool_response"   => "success",
          "hook_event_name" => "PostToolUse",
        }.to_json

        result = run_binary(["on-post-tool-use"], stdin: input)
        result[:status].should eq(0)

        # The path lives under /implementation-plans/, which
        # is in SOURCE_PATH_PATTERNS — classification returns
        # nil and the artifacts binary is never invoked.
        read_artifacts_log(log_path).should be_empty

        GalaxyLedger::Database.delete_session(session_id)
      ensure
        File.delete(plan_path) if (
                                    plan_path && File.exists?(plan_path)
                                  )
        FileUtils.rm_rf(parent_dir) if parent_dir
        restore_artifacts_noop
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
