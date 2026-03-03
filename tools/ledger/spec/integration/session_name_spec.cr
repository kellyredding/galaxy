require "../spec_helper"

# Helper to create a session with PID and project_dir, then seed a JSONL
# file in the test Claude config directory.
private def create_session_name_test_data(
  pid : Int64,
  project_dir : String,
  session_identifier : String,
  custom_title : String? = nil,
) : Int64
  ledger_session_id = GalaxyLedger::Database.create_session(
    session_identifier,
    claude_pid: pid,
    project_dir: project_dir,
  )

  # Create the JSONL file in the test Claude config directory
  encoded_dir = project_dir.gsub(/[\/.]/, "-")
  jsonl_dir = SPEC_CLAUDE_CONFIG_DIR / "projects" / encoded_dir
  Dir.mkdir_p(jsonl_dir)
  jsonl_path = jsonl_dir / "#{session_identifier}.jsonl"

  lines = [] of String
  # Add a non-title line so the file isn't empty
  lines << %({"type":"user","sessionId":"#{session_identifier}"})
  if title = custom_title
    lines << %({"type":"custom-title","customTitle":"#{title}","sessionId":"#{session_identifier}"})
  end
  File.write(jsonl_path, lines.join("\n") + "\n")

  flush_wal
  ledger_session_id
end

describe "CLI Integration - session-name" do
  describe "help" do
    it "shows help with --help flag" do
      result = run_binary(["session-name", "--help"])
      result[:status].should eq(0)
      result[:output].should contain("Usage:")
      result[:output].should contain("--pid PID")
    end

    it "shows help with -h flag" do
      result = run_binary(["session-name", "-h"])
      result[:status].should eq(0)
      result[:output].should contain("Usage:")
    end
  end

  describe "error handling" do
    it "errors when --pid is missing" do
      result = run_binary(["session-name"])
      result[:status].should_not eq(0)
      result[:error].should contain("--pid is required")
    end

    it "errors when PID is not found" do
      result = run_binary(["session-name", "--pid", "99999"])
      result[:status].should_not eq(0)
      result[:error].should contain("no session found for PID")
    end
  end

  describe "name lookup" do
    it "outputs the custom title when session has been renamed" do
      create_session_name_test_data(
        pid: 70001_i64,
        project_dir: "/tmp/test-project",
        session_identifier: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
        custom_title: "my-cool-session",
      )

      result = run_binary(["session-name", "--pid", "70001"])
      result[:status].should eq(0)
      result[:output].strip.should eq("my-cool-session")
    end

    it "outputs the last custom title when renamed multiple times" do
      pid = 70002_i64
      identifier = "aaaaaaaa-bbbb-cccc-dddd-ffffffffffff"
      project_dir = "/tmp/test-project-2"

      ledger_session_id = GalaxyLedger::Database.create_session(
        identifier,
        claude_pid: pid,
        project_dir: project_dir,
      )

      # Write JSONL with two custom-title entries
      encoded_dir = project_dir.gsub(/[\/.]/, "-")
      jsonl_dir = SPEC_CLAUDE_CONFIG_DIR / "projects" / encoded_dir
      Dir.mkdir_p(jsonl_dir)
      jsonl_path = jsonl_dir / "#{identifier}.jsonl"
      File.write(jsonl_path, [
        %({"type":"custom-title","customTitle":"first-name","sessionId":"#{identifier}"}),
        %({"type":"custom-title","customTitle":"second-name","sessionId":"#{identifier}"}),
      ].join("\n") + "\n")

      flush_wal

      result = run_binary(["session-name", "--pid", "70002"])
      result[:status].should eq(0)
      result[:output].strip.should eq("second-name")
    end

    it "outputs (unnamed) when session has no custom title" do
      create_session_name_test_data(
        pid: 70003_i64,
        project_dir: "/tmp/test-project-3",
        session_identifier: "aaaaaaaa-bbbb-cccc-dddd-111111111111",
        custom_title: nil,
      )

      result = run_binary(["session-name", "--pid", "70003"])
      result[:status].should eq(0)
      result[:output].strip.should eq("(unnamed)")
    end

    it "outputs (unnamed) when session has no project_dir" do
      # Create session without project_dir
      identifier = "aaaaaaaa-bbbb-cccc-dddd-222222222222"
      GalaxyLedger::Database.create_session(
        identifier,
        claude_pid: 70004_i64,
      )
      flush_wal

      result = run_binary(["session-name", "--pid", "70004"])
      result[:status].should eq(0)
      result[:output].strip.should eq("(unnamed)")
    end

    it "outputs (unnamed) when JSONL file does not exist" do
      # Create session with project_dir but no JSONL file on disk
      identifier = "aaaaaaaa-bbbb-cccc-dddd-333333333333"
      GalaxyLedger::Database.create_session(
        identifier,
        claude_pid: 70005_i64,
        project_dir: "/tmp/nonexistent-project",
      )
      flush_wal

      result = run_binary(["session-name", "--pid", "70005"])
      result[:status].should eq(0)
      result[:output].strip.should eq("(unnamed)")
    end
  end
end
