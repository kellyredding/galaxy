require "../spec_helper"

describe "OnStop GALAXY_SKIP_HOOKS" do
  it "returns early when GALAXY_SKIP_HOOKS=1 is set" do
    ENV["GALAXY_SKIP_HOOKS"] = "1"

    test_session_id = "skip-hooks-test-#{Random.rand(10000)}"
    session_dir = GalaxyLedger.session_dir(test_session_id)
    Dir.mkdir_p(session_dir)

    # Create test transcript file
    transcript_file = File.tempfile("transcript", ".jsonl")
    transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:00:00Z", "message": {"role": "user", "content": "Test"}}\n|)
    transcript_file.print(%|{"type": "assistant", "timestamp": "2026-02-01T10:01:00Z", "message": {"role": "assistant", "content": "Response"}}\n|)
    transcript_file.close

    hook_input = {
      "session_id"       => test_session_id,
      "transcript_path"  => transcript_file.path,
      "stop_hook_active" => false,
    }.to_json

    result = run_binary(["on-stop"], stdin: hook_input)
    result[:status].should eq(0)

    # Exchange file should NOT be created (early return)
    exchange_file = session_dir / GalaxyLedger::LEDGER_LAST_EXCHANGE_FILENAME
    File.exists?(exchange_file).should eq(false)

    # Clean up
    File.delete(transcript_file.path)
    FileUtils.rm_rf(session_dir.to_s)
  ensure
    ENV.delete("GALAXY_SKIP_HOOKS")
  end
end

describe GalaxyLedger::Hooks::OnStop do
  describe "#run" do
    it "creates instance successfully" do
      handler = GalaxyLedger::Hooks::OnStop.new
      handler.should be_a(GalaxyLedger::Hooks::OnStop)
    end
  end
end

describe "OnStop last exchange capture" do
  test_session_id = "on-stop-test-#{Random.rand(10000)}"

  before_each do
    session_dir = GalaxyLedger.session_dir(test_session_id)
    FileUtils.rm_rf(session_dir.to_s)
  end

  after_each do
    session_dir = GalaxyLedger.session_dir(test_session_id)
    FileUtils.rm_rf(session_dir.to_s)
  end

  it "captures last exchange from transcript" do
    # Create test transcript file
    transcript_file = File.tempfile("transcript", ".jsonl")
    transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:00:00Z", "message": {"role": "user", "content": "Add authentication"}}\n|)
    transcript_file.print(%|{"type": "assistant", "timestamp": "2026-02-01T10:01:00Z", "message": {"role": "assistant", "content": "I'll help you add authentication to the app."}}\n|)
    transcript_file.close

    # Run on-stop with stdin providing session_id and transcript_path
    hook_input = {
      "session_id"       => test_session_id,
      "transcript_path"  => transcript_file.path,
      "stop_hook_active" => false,
    }.to_json

    result = run_binary(["on-stop"], stdin: hook_input)
    result[:status].should eq(0)

    # Verify last exchange file was created
    session_dir = GalaxyLedger.session_dir(test_session_id)
    exchange_file = session_dir / GalaxyLedger::LEDGER_LAST_EXCHANGE_FILENAME
    File.exists?(exchange_file).should eq(true)

    # Verify content
    exchange = GalaxyLedger::Exchange.read(test_session_id)
    exchange.should_not be_nil
    exchange.not_nil!.user_message.should eq("Add authentication")
    exchange.not_nil!.full_content.should contain("I'll help you add authentication")

    # Clean up
    File.delete(transcript_file.path)
  end

  it "returns early when stop_hook_active is true" do
    # Create test transcript file
    transcript_file = File.tempfile("transcript", ".jsonl")
    transcript_file.print(%|{"type": "user", "message": {"role": "user", "content": "Test"}}\n|)
    transcript_file.close

    # Run on-stop with stop_hook_active = true
    hook_input = {
      "session_id"       => test_session_id,
      "transcript_path"  => transcript_file.path,
      "stop_hook_active" => true,
    }.to_json

    result = run_binary(["on-stop"], stdin: hook_input)
    result[:status].should eq(0)

    # Exchange file should NOT be created (early return)
    session_dir = GalaxyLedger.session_dir(test_session_id)
    exchange_file = session_dir / GalaxyLedger::LEDGER_LAST_EXCHANGE_FILENAME
    File.exists?(exchange_file).should eq(false)

    # Clean up
    File.delete(transcript_file.path)
  end

  it "handles non-existent transcript gracefully" do
    hook_input = {
      "session_id"       => test_session_id,
      "transcript_path"  => "/nonexistent/path/transcript.jsonl",
      "stop_hook_active" => false,
    }.to_json

    result = run_binary(["on-stop"], stdin: hook_input)
    result[:status].should eq(0) # Should not crash

    # No exchange file created (no valid transcript)
    session_dir = GalaxyLedger.session_dir(test_session_id)
    exchange_file = session_dir / GalaxyLedger::LEDGER_LAST_EXCHANGE_FILENAME
    File.exists?(exchange_file).should eq(false)
  end

  it "handles empty stdin gracefully" do
    result = run_binary(["on-stop"], stdin: "")
    result[:status].should eq(0)
  end

  it "handles malformed JSON stdin gracefully" do
    result = run_binary(["on-stop"], stdin: "not valid json {{{")
    result[:status].should eq(0)
  end
end

describe "OnStop context threshold warnings" do
  test_session_id = "threshold-test-#{Random.rand(10000)}"

  before_each do
    session_dir = GalaxyLedger.session_dir(test_session_id)
    FileUtils.rm_rf(session_dir.to_s)
    Dir.mkdir_p(session_dir)
  end

  after_each do
    session_dir = GalaxyLedger.session_dir(test_session_id)
    FileUtils.rm_rf(session_dir.to_s)
  end

  it "outputs warning when context exceeds warning threshold" do
    # Create context status file at 75%
    session_dir = GalaxyLedger.session_dir(test_session_id)
    status_file = GalaxyLedger.context_status_path(test_session_id)
    File.write(status_file, %|{"percentage": 75.0}|)

    # Create minimal transcript
    transcript_file = File.tempfile("transcript", ".jsonl")
    transcript_file.print(%|{"type": "user", "message": {"role": "user", "content": "Test"}}\n|)
    transcript_file.close

    hook_input = {
      "session_id"       => test_session_id,
      "transcript_path"  => transcript_file.path,
      "stop_hook_active" => false,
    }.to_json

    result = run_binary(["on-stop"], stdin: hook_input)
    result[:output].should contain("⚠️")
    result[:output].should contain("75%")
    result[:output].should contain("/clear")

    # Clean up
    File.delete(transcript_file.path)
  end

  it "outputs critical warning when context exceeds critical threshold" do
    # Create context status file at 90%
    session_dir = GalaxyLedger.session_dir(test_session_id)
    status_file = GalaxyLedger.context_status_path(test_session_id)
    File.write(status_file, %|{"percentage": 90.0}|)

    # Create minimal transcript
    transcript_file = File.tempfile("transcript", ".jsonl")
    transcript_file.print(%|{"type": "user", "message": {"role": "user", "content": "Test"}}\n|)
    transcript_file.close

    hook_input = {
      "session_id"       => test_session_id,
      "transcript_path"  => transcript_file.path,
      "stop_hook_active" => false,
    }.to_json

    result = run_binary(["on-stop"], stdin: hook_input)
    result[:output].should contain("🚨")
    result[:output].should contain("90%")
    result[:output].should contain("Auto-compact")

    # Clean up
    File.delete(transcript_file.path)
  end

  it "outputs no warning when context is below threshold" do
    # Create context status file at 50%
    session_dir = GalaxyLedger.session_dir(test_session_id)
    status_file = GalaxyLedger.context_status_path(test_session_id)
    File.write(status_file, %|{"percentage": 50.0}|)

    # Create minimal transcript
    transcript_file = File.tempfile("transcript", ".jsonl")
    transcript_file.print(%|{"type": "user", "message": {"role": "user", "content": "Test"}}\n|)
    transcript_file.close

    hook_input = {
      "session_id"       => test_session_id,
      "transcript_path"  => transcript_file.path,
      "stop_hook_active" => false,
    }.to_json

    result = run_binary(["on-stop"], stdin: hook_input)
    result[:output].should_not contain("⚠️")
    result[:output].should_not contain("🚨")

    # Clean up
    File.delete(transcript_file.path)
  end
end

describe "OnStop buffer flush (Phase 5.1)" do
  test_session_id = "stop-flush-test-#{Random.rand(10000)}"

  before_each do
    session_dir = GalaxyLedger.session_dir(test_session_id)
    FileUtils.rm_rf(session_dir.to_s)
    Dir.mkdir_p(session_dir)
    GalaxyLedger::Database.ensure_database_exists
  end

  after_each do
    session_dir = GalaxyLedger.session_dir(test_session_id)
    FileUtils.rm_rf(session_dir.to_s)
    # Clean up database entries for this session
    GalaxyLedger::Database.open do |db|
      db.exec("DELETE FROM ledger_entries WHERE session_id = ?", test_session_id)
    end
  end

  it "triggers async buffer flush when buffer has entries" do
    # Add some entries to the buffer
    entry1 = GalaxyLedger::Buffer::Entry.new(
      entry_type: "learning",
      content: "Test learning for stop hook flush",
      importance: "medium",
      source: "assistant",
    )
    entry2 = GalaxyLedger::Buffer::Entry.new(
      entry_type: "decision",
      content: "Test decision for stop hook flush",
      importance: "high",
      source: "assistant",
    )
    GalaxyLedger::Buffer.append(test_session_id, entry1)
    GalaxyLedger::Buffer.append(test_session_id, entry2)

    # Verify buffer has entries
    GalaxyLedger::Buffer.count(test_session_id).should eq(2)

    # Create minimal transcript
    transcript_file = File.tempfile("transcript", ".jsonl")
    transcript_file.print(%|{"type": "user", "message": {"role": "user", "content": "Test"}}\n|)
    transcript_file.print(%|{"type": "assistant", "message": {"role": "assistant", "content": "Response"}}\n|)
    transcript_file.close

    hook_input = {
      "session_id"       => test_session_id,
      "transcript_path"  => transcript_file.path,
      "stop_hook_active" => false,
    }.to_json

    # Run on-stop hook
    result = run_binary(["on-stop"], stdin: hook_input)
    result[:status].should eq(0)

    # Wait for async flush to complete (it spawns a subprocess)
    sleep 0.5.seconds

    # Verify entries were flushed to database
    entries = GalaxyLedger::Database.query_by_session(test_session_id)
    entries.size.should eq(2)
    entries.map(&.content).should contain("Test learning for stop hook flush")
    entries.map(&.content).should contain("Test decision for stop hook flush")

    # Buffer should be cleared after flush
    GalaxyLedger::Buffer.exists?(test_session_id).should eq(false)

    # Clean up
    File.delete(transcript_file.path)
  end

  it "does not flush when buffer is empty" do
    # No buffer entries - just verify no crash and no spurious database entries

    # Create minimal transcript
    transcript_file = File.tempfile("transcript", ".jsonl")
    transcript_file.print(%|{"type": "user", "message": {"role": "user", "content": "Test"}}\n|)
    transcript_file.print(%|{"type": "assistant", "message": {"role": "assistant", "content": "Response"}}\n|)
    transcript_file.close

    hook_input = {
      "session_id"       => test_session_id,
      "transcript_path"  => transcript_file.path,
      "stop_hook_active" => false,
    }.to_json

    # Run on-stop hook
    result = run_binary(["on-stop"], stdin: hook_input)
    result[:status].should eq(0)

    # No database entries should exist
    entries = GalaxyLedger::Database.query_by_session(test_session_id)
    entries.size.should eq(0)

    # Clean up
    File.delete(transcript_file.path)
  end

  it "does not flush when stop_hook_active is true" do
    # Add entry to buffer
    entry = GalaxyLedger::Buffer::Entry.new(
      entry_type: "learning",
      content: "Should not be flushed",
      importance: "medium",
    )
    GalaxyLedger::Buffer.append(test_session_id, entry)

    # Create minimal transcript
    transcript_file = File.tempfile("transcript", ".jsonl")
    transcript_file.print(%|{"type": "user", "message": {"role": "user", "content": "Test"}}\n|)
    transcript_file.close

    hook_input = {
      "session_id"       => test_session_id,
      "transcript_path"  => transcript_file.path,
      "stop_hook_active" => true, # Early return
    }.to_json

    # Run on-stop hook
    result = run_binary(["on-stop"], stdin: hook_input)
    result[:status].should eq(0)

    # Buffer should still exist (not flushed due to early return)
    GalaxyLedger::Buffer.exists?(test_session_id).should eq(true)
    GalaxyLedger::Buffer.count(test_session_id).should eq(1)

    # No database entries
    entries = GalaxyLedger::Database.query_by_session(test_session_id)
    entries.size.should eq(0)

    # Clean up
    File.delete(transcript_file.path)
  end
end
