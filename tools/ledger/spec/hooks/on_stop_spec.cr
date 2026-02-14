require "../spec_helper"

describe "OnStop GALAXY_SKIP_HOOKS" do
  it "returns early when GALAXY_SKIP_HOOKS=1 is set" do
    ENV["GALAXY_SKIP_HOOKS"] = "1"

    test_session_id = "skip-hooks-test-#{Random.rand(10000)}"
    session_dir = GalaxyLedger.session_dir(test_session_id)
    Dir.mkdir_p(session_dir)

    # Ensure session record exists for FK constraints
    GalaxyLedger::Database.upsert_session(test_session_id)

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

    # Last interaction should NOT be written to DB (early return)
    session_record = GalaxyLedger::Database.get_session(test_session_id)
    session_record.try(&.last_interaction).should be_nil

    # Clean up
    File.delete(transcript_file.path)
    FileUtils.rm_rf(session_dir.to_s)
    GalaxyLedger::Database.delete_session(test_session_id)
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
    GalaxyLedger::Database.delete_session(test_session_id)
    # Ensure session record exists for FK constraints
    GalaxyLedger::Database.upsert_session(test_session_id)
  end

  after_each do
    session_dir = GalaxyLedger.session_dir(test_session_id)
    FileUtils.rm_rf(session_dir.to_s)
    GalaxyLedger::Database.delete_session(test_session_id)
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

    # Verify last interaction was written to DB
    session_record = GalaxyLedger::Database.get_session(test_session_id)
    session_record.should_not be_nil
    json_str = session_record.not_nil!.last_interaction
    json_str.should_not be_nil

    exchange = GalaxyLedger::Exchange::LastExchange.from_json(json_str.not_nil!)
    exchange.user_message.should eq("Add authentication")
    exchange.full_content.should contain("I'll help you add authentication")

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

    # Last interaction should NOT be written to DB (early return)
    session_record = GalaxyLedger::Database.get_session(test_session_id)
    session_record.try(&.last_interaction).should be_nil

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

    # No last interaction written to DB (no valid transcript)
    session_record = GalaxyLedger::Database.get_session(test_session_id)
    session_record.try(&.last_interaction).should be_nil
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
    GalaxyLedger::Database.delete_session(test_session_id)
    # Ensure session record exists for FK constraints
    GalaxyLedger::Database.upsert_session(test_session_id)
  end

  after_each do
    session_dir = GalaxyLedger.session_dir(test_session_id)
    FileUtils.rm_rf(session_dir.to_s)
    GalaxyLedger::Database.delete_session(test_session_id)
  end

  it "outputs warning when context exceeds warning threshold" do
    # Create context status file at 75%
    session_dir = GalaxyLedger.session_dir(test_session_id)
    status_file = GalaxyLedger.context_status_path(test_session_id)
    File.write(status_file, %|{"context": {"percentage": 75.0}}|)

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
    File.write(status_file, %|{"context": {"percentage": 90.0}}|)

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
    File.write(status_file, %|{"context": {"percentage": 50.0}}|)

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

describe "OnStop stale re-extraction" do
  test_session_id = "stale-reextract-#{Random.rand(10000)}"

  before_each do
    session_dir = GalaxyLedger.session_dir(test_session_id)
    FileUtils.rm_rf(session_dir.to_s)
    Dir.mkdir_p(session_dir)
    GalaxyLedger::Database.delete_session(test_session_id)
    # Ensure session record exists for FK constraints
    GalaxyLedger::Database.upsert_session(test_session_id)
  end

  after_each do
    session_dir = GalaxyLedger.session_dir(test_session_id)
    FileUtils.rm_rf(session_dir.to_s)
    GalaxyLedger::Database.delete_session(test_session_id)
  end

  it "prunes stale entries when on-stop runs with stale guideline" do
    # Simulate: read a guideline, then edit it, then on-stop fires.
    # We can't test the async re-extraction subprocess easily,
    # but we can verify that stale entries get pruned.

    # Create marker + extracted entries
    marker = GalaxyLedger::Entry.new(
      entry_type: "guideline",
      content: "/home/user/agent-guidelines/ruby-style.md",
      source_file: "ruby-style.md",
    )
    extracted = GalaxyLedger::Entry.new(
      entry_type: "guideline",
      content: "Always use double-quotes for strings",
      source_file: "ruby-style.md",
    )
    GalaxyLedger::Database.insert(test_session_id, marker)
    GalaxyLedger::Database.insert(test_session_id, extracted)

    # Mark them stale (simulates edit detection)
    GalaxyLedger::Database.mark_entries_stale(test_session_id, "ruby-style.md")

    # Verify stale
    stale = GalaxyLedger::Database.stale_entries(test_session_id)
    stale.size.should eq(1)

    # Now prune (simulates what on-stop does before spawning re-extraction)
    GalaxyLedger::Database.delete_entries_by_source_file(test_session_id, "ruby-style.md")

    # Entries should be gone
    GalaxyLedger::Database.has_extracted_source_file?(test_session_id, "ruby-style.md").should be_false
    GalaxyLedger::Database.stale_entries(test_session_id).should be_empty
  end

  it "preserves non-stale entries when pruning stale ones" do
    # Non-stale guideline
    fresh_entry = GalaxyLedger::Entry.new(
      entry_type: "guideline",
      content: "/home/user/agent-guidelines/rspec-style.md",
      source_file: "rspec-style.md",
    )
    # Stale guideline
    stale_entry = GalaxyLedger::Entry.new(
      entry_type: "guideline",
      content: "/home/user/agent-guidelines/ruby-style.md",
      source_file: "ruby-style.md",
    )
    # Learning (should never be affected)
    learning = GalaxyLedger::Entry.new(
      entry_type: "learning",
      content: "Learned something important",
    )

    GalaxyLedger::Database.insert(test_session_id, fresh_entry)
    GalaxyLedger::Database.insert(test_session_id, stale_entry)
    GalaxyLedger::Database.insert(test_session_id, learning)

    # Mark only ruby-style as stale
    GalaxyLedger::Database.mark_entries_stale(test_session_id, "ruby-style.md")

    # Prune stale entries
    GalaxyLedger::Database.delete_entries_by_source_file(test_session_id, "ruby-style.md")

    # Fresh guideline and learning should survive
    GalaxyLedger::Database.has_extracted_source_file?(test_session_id, "rspec-style.md").should be_true
    entries = GalaxyLedger::Database.query_by_session(test_session_id)
    entries.size.should eq(2)
    entry_types = entries.map(&.entry_type)
    entry_types.should contain("guideline")
    entry_types.should contain("learning")
  end

  it "handles no stale entries gracefully" do
    # Insert a fresh (non-stale) entry
    entry = GalaxyLedger::Entry.new(
      entry_type: "guideline",
      content: "/home/user/agent-guidelines/ruby-style.md",
      source_file: "ruby-style.md",
    )
    GalaxyLedger::Database.insert(test_session_id, entry)

    # No stale entries
    GalaxyLedger::Database.stale_entries(test_session_id).should be_empty

    # Running on-stop should not affect anything
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

    # Entry should still exist
    GalaxyLedger::Database.has_extracted_source_file?(test_session_id, "ruby-style.md").should be_true

    # Clean up
    File.delete(transcript_file.path)
  end
end

describe "OnStop CLI help" do
  it "shows help with -h flag" do
    result = run_binary(["on-stop", "-h"])
    result[:status].should eq(0)

    result[:output].should contain("on-stop")
    result[:output].should contain("Stop")
    result[:output].should contain("USAGE")
  end

  it "shows help with --help flag" do
    result = run_binary(["on-stop", "--help"])
    result[:status].should eq(0)
    result[:output].should contain("on-stop")
  end
end
