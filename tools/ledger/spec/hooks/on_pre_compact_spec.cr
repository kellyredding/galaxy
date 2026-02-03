require "../spec_helper"

describe GalaxyLedger::Hooks::OnPreCompact do
  describe "#run" do
    it "flushes buffered entries to SQLite" do
      session_id = "pre-compact-test-#{rand(100000)}"
      session_dir = GalaxyLedger::SESSIONS_DIR / session_id
      Dir.mkdir_p(session_dir)

      # Add some entries to the buffer
      entry1 = GalaxyLedger::Buffer::Entry.new(
        entry_type: "learning",
        content: "Test learning 1",
        importance: "medium"
      )
      entry2 = GalaxyLedger::Buffer::Entry.new(
        entry_type: "decision",
        content: "Test decision 1",
        importance: "high"
      )
      GalaxyLedger::Buffer.append(session_id, entry1)
      GalaxyLedger::Buffer.append(session_id, entry2)

      # Verify entries are in buffer
      buffer_entries = GalaxyLedger::Buffer.read(session_id)
      buffer_entries.size.should eq(2)

      # Run the hook
      input = {
        "session_id"      => session_id,
        "source"          => "auto",
        "hook_event_name" => "PreCompact",
      }.to_json

      result = run_binary(["on-pre-compact"], stdin: input)
      result[:status].should eq(0)

      # Buffer should now be empty
      buffer_entries = GalaxyLedger::Buffer.read(session_id)
      buffer_entries.size.should eq(0)

      # Entries should be in database
      db_entries = GalaxyLedger::Database.query_by_session(session_id)
      db_entries.size.should eq(2)
    end

    it "handles empty buffer gracefully" do
      session_id = "pre-compact-test-#{rand(100000)}"
      session_dir = GalaxyLedger::SESSIONS_DIR / session_id
      Dir.mkdir_p(session_dir)

      # No entries in buffer
      input = {
        "session_id"      => session_id,
        "source"          => "manual",
        "hook_event_name" => "PreCompact",
      }.to_json

      result = run_binary(["on-pre-compact"], stdin: input)
      result[:status].should eq(0)
    end

    it "handles missing session_id gracefully" do
      input = {
        "source"          => "auto",
        "hook_event_name" => "PreCompact",
      }.to_json

      result = run_binary(["on-pre-compact"], stdin: input)
      result[:status].should eq(0)
    end

    it "handles empty input gracefully" do
      result = run_binary(["on-pre-compact"], stdin: "")
      result[:status].should eq(0)
    end

    it "handles invalid JSON gracefully" do
      result = run_binary(["on-pre-compact"], stdin: "not json")
      result[:status].should eq(0)
    end
  end

  describe "CLI help" do
    it "shows help with -h flag" do
      result = run_binary(["on-pre-compact", "-h"])
      result[:status].should eq(0)

      result[:output].should contain("on-pre-compact")
      result[:output].should contain("PreCompact")
      result[:output].should contain("USAGE")
      result[:output].should contain("auto")
      result[:output].should contain("manual")
    end

    it "shows help with --help flag" do
      result = run_binary(["on-pre-compact", "--help"])
      result[:status].should eq(0)
      result[:output].should contain("on-pre-compact")
    end
  end
end
