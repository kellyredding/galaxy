require "../spec_helper"

describe "OnStop GALAXY_SKIP_HOOKS" do
  it "returns early when GALAXY_SKIP_HOOKS=1 is set" do
    ENV["GALAXY_SKIP_HOOKS"] = "1"

    test_session_id = "skip-hooks-test-#{Random.rand(10000)}"

    # Ensure session record exists for FK constraints
    ledger_session_id = GalaxyLedger::Database.create_session(test_session_id)

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
  ledger_session_id = 0_i64

  before_each do
    GalaxyLedger::Database.delete_session(test_session_id)
    # Ensure session record exists for FK constraints
    ledger_session_id = GalaxyLedger::Database.create_session(test_session_id)
  end

  after_each do
    GalaxyLedger::Database.delete_session(test_session_id)
  end

  it "does not capture last exchange synchronously (capture moved to async subprocess)" do
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

    # last_interaction is NOT set synchronously — capture is now in the async subprocess.
    # The stop hook just spawns the subprocess and returns immediately.
    session_record = GalaxyLedger::Database.get_session(test_session_id)
    session_record.should_not be_nil
    # Note: last_interaction may or may not be nil depending on timing of the
    # spawned subprocess, but the stop hook itself does not write it.

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

describe "OnStop JSON output format" do
  test_session_id = "json-output-test-#{Random.rand(10000)}"
  ledger_session_id = 0_i64

  before_each do
    GalaxyLedger::Database.delete_session(test_session_id)
    ledger_session_id = GalaxyLedger::Database.create_session(test_session_id)
  end

  after_each do
    GalaxyLedger::Database.delete_session(test_session_id)
  end

  it "outputs valid JSON with decision and systemMessage keys" do
    transcript_file = File.tempfile("transcript", ".jsonl")
    transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:00:00Z", "message": {"role": "user", "content": "Add authentication"}}\n|)
    transcript_file.print(%|{"type": "assistant", "timestamp": "2026-02-01T10:01:00Z", "message": {"role": "assistant", "content": "I'll help you add authentication."}}\n|)
    transcript_file.close

    hook_input = {
      "session_id"       => test_session_id,
      "transcript_path"  => transcript_file.path,
      "stop_hook_active" => false,
    }.to_json

    result = run_binary(["on-stop"], stdin: hook_input)
    result[:status].should eq(0)

    json = JSON.parse(result[:output])
    json["decision"].as_s.should eq("approve")
    json["systemMessage"].as_s.should_not be_empty

    File.delete(transcript_file.path)
  end

  it "always outputs decision approve" do
    transcript_file = File.tempfile("transcript", ".jsonl")
    transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:00:00Z", "message": {"role": "user", "content": "Test message"}}\n|)
    transcript_file.print(%|{"type": "assistant", "timestamp": "2026-02-01T10:01:00Z", "message": {"role": "assistant", "content": "Test response"}}\n|)
    transcript_file.close

    # Test with various context percentages — decision should always be "approve"
    [0.0, 50.0, 75.0, 90.0].each do |pct|
      status = GalaxyLedger::ContextStatus.from_json(%|{"context": {"percentage": #{pct}}}|)
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status)

      hook_input = {
        "session_id"       => test_session_id,
        "transcript_path"  => transcript_file.path,
        "stop_hook_active" => false,
      }.to_json

      result = run_binary(["on-stop"], stdin: hook_input)
      json = JSON.parse(result[:output])
      json["decision"].as_s.should eq("approve")
    end

    File.delete(transcript_file.path)
  end

  it "does not include Exchange captured (capture moved to async subprocess)" do
    transcript_file = File.tempfile("transcript", ".jsonl")
    transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:00:00Z", "message": {"role": "user", "content": "Add authentication"}}\n|)
    transcript_file.print(%|{"type": "assistant", "timestamp": "2026-02-01T10:01:00Z", "message": {"role": "assistant", "content": "I'll help you add authentication."}}\n|)
    transcript_file.close

    hook_input = {
      "session_id"       => test_session_id,
      "transcript_path"  => transcript_file.path,
      "stop_hook_active" => false,
    }.to_json

    result = run_binary(["on-stop"], stdin: hook_input)
    json = JSON.parse(result[:output])
    # Exchange capture is now done in the async subprocess, not the stop hook
    json["systemMessage"].as_s.should_not contain("Exchange captured")

    File.delete(transcript_file.path)
  end
end

describe "OnStop context indicators" do
  test_session_id = "context-indicator-#{Random.rand(10000)}"
  ledger_session_id = 0_i64

  before_each do
    GalaxyLedger::Database.delete_session(test_session_id)
    ledger_session_id = GalaxyLedger::Database.create_session(test_session_id)
  end

  after_each do
    GalaxyLedger::Database.delete_session(test_session_id)
  end

  it "shows no context indicator when context is 0% (no metrics)" do
    # Session exists but no metrics written (context_percentage defaults to 0.0)
    transcript_file = File.tempfile("transcript", ".jsonl")
    transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:00:00Z", "message": {"role": "user", "content": "Test message here"}}\n|)
    transcript_file.print(%|{"type": "assistant", "timestamp": "2026-02-01T10:01:00Z", "message": {"role": "assistant", "content": "Test response here"}}\n|)
    transcript_file.close

    hook_input = {
      "session_id"       => test_session_id,
      "transcript_path"  => transcript_file.path,
      "stop_hook_active" => false,
    }.to_json

    result = run_binary(["on-stop"], stdin: hook_input)
    json = JSON.parse(result[:output])
    msg = json["systemMessage"].as_s
    msg.should_not contain("Context")
    msg.should_not contain("⚠️")
    msg.should_not contain("🔥")

    File.delete(transcript_file.path)
  end

  it "shows no context indicator when context is below warning threshold" do
    status = GalaxyLedger::ContextStatus.from_json(%|{"context": {"percentage": 34.0}}|)
    GalaxyLedger::Database.update_session_metrics(ledger_session_id, status)

    transcript_file = File.tempfile("transcript", ".jsonl")
    transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:00:00Z", "message": {"role": "user", "content": "Test message here"}}\n|)
    transcript_file.print(%|{"type": "assistant", "timestamp": "2026-02-01T10:01:00Z", "message": {"role": "assistant", "content": "Test response here"}}\n|)
    transcript_file.close

    hook_input = {
      "session_id"       => test_session_id,
      "transcript_path"  => transcript_file.path,
      "stop_hook_active" => false,
    }.to_json

    result = run_binary(["on-stop"], stdin: hook_input)
    json = JSON.parse(result[:output])
    msg = json["systemMessage"].as_s
    msg.should_not contain("Context")
    msg.should_not contain("⚠️")
    msg.should_not contain("🔥")

    File.delete(transcript_file.path)
  end

  it "shows no context indicator at 69% (just below warning threshold)" do
    status = GalaxyLedger::ContextStatus.from_json(%|{"context": {"percentage": 69.0}}|)
    GalaxyLedger::Database.update_session_metrics(ledger_session_id, status)

    transcript_file = File.tempfile("transcript", ".jsonl")
    transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:00:00Z", "message": {"role": "user", "content": "Test message here"}}\n|)
    transcript_file.print(%|{"type": "assistant", "timestamp": "2026-02-01T10:01:00Z", "message": {"role": "assistant", "content": "Test response here"}}\n|)
    transcript_file.close

    hook_input = {
      "session_id"       => test_session_id,
      "transcript_path"  => transcript_file.path,
      "stop_hook_active" => false,
    }.to_json

    result = run_binary(["on-stop"], stdin: hook_input)
    json = JSON.parse(result[:output])
    msg = json["systemMessage"].as_s
    msg.should_not contain("Context")

    File.delete(transcript_file.path)
  end

  it "shows warning at threshold boundary (70%)" do
    status = GalaxyLedger::ContextStatus.from_json(%|{"context": {"percentage": 70.0}}|)
    GalaxyLedger::Database.update_session_metrics(ledger_session_id, status)

    transcript_file = File.tempfile("transcript", ".jsonl")
    transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:00:00Z", "message": {"role": "user", "content": "Test message here"}}\n|)
    transcript_file.print(%|{"type": "assistant", "timestamp": "2026-02-01T10:01:00Z", "message": {"role": "assistant", "content": "Test response here"}}\n|)
    transcript_file.close

    hook_input = {
      "session_id"       => test_session_id,
      "transcript_path"  => transcript_file.path,
      "stop_hook_active" => false,
    }.to_json

    result = run_binary(["on-stop"], stdin: hook_input)
    json = JSON.parse(result[:output])
    msg = json["systemMessage"].as_s
    msg.should contain("⚠️")
    msg.should contain("Context 70%")
    msg.should contain("consider /clear soon")

    File.delete(transcript_file.path)
  end

  it "shows warning when context is in warning range (75%)" do
    status = GalaxyLedger::ContextStatus.from_json(%|{"context": {"percentage": 75.0}}|)
    GalaxyLedger::Database.update_session_metrics(ledger_session_id, status)

    transcript_file = File.tempfile("transcript", ".jsonl")
    transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:00:00Z", "message": {"role": "user", "content": "Test message here"}}\n|)
    transcript_file.print(%|{"type": "assistant", "timestamp": "2026-02-01T10:01:00Z", "message": {"role": "assistant", "content": "Test response here"}}\n|)
    transcript_file.close

    hook_input = {
      "session_id"       => test_session_id,
      "transcript_path"  => transcript_file.path,
      "stop_hook_active" => false,
    }.to_json

    result = run_binary(["on-stop"], stdin: hook_input)
    json = JSON.parse(result[:output])
    msg = json["systemMessage"].as_s
    msg.should contain("⚠️")
    msg.should contain("Context 75%")
    msg.should contain("consider /clear soon")

    File.delete(transcript_file.path)
  end

  it "shows warning at 84% (just below critical threshold)" do
    status = GalaxyLedger::ContextStatus.from_json(%|{"context": {"percentage": 84.0}}|)
    GalaxyLedger::Database.update_session_metrics(ledger_session_id, status)

    transcript_file = File.tempfile("transcript", ".jsonl")
    transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:00:00Z", "message": {"role": "user", "content": "Test message here"}}\n|)
    transcript_file.print(%|{"type": "assistant", "timestamp": "2026-02-01T10:01:00Z", "message": {"role": "assistant", "content": "Test response here"}}\n|)
    transcript_file.close

    hook_input = {
      "session_id"       => test_session_id,
      "transcript_path"  => transcript_file.path,
      "stop_hook_active" => false,
    }.to_json

    result = run_binary(["on-stop"], stdin: hook_input)
    json = JSON.parse(result[:output])
    msg = json["systemMessage"].as_s
    msg.should contain("⚠️")
    msg.should contain("Context 84%")
    msg.should contain("consider /clear soon")
    msg.should_not contain("auto-compact")

    File.delete(transcript_file.path)
  end

  it "shows critical at threshold boundary (85%)" do
    status = GalaxyLedger::ContextStatus.from_json(%|{"context": {"percentage": 85.0}}|)
    GalaxyLedger::Database.update_session_metrics(ledger_session_id, status)

    transcript_file = File.tempfile("transcript", ".jsonl")
    transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:00:00Z", "message": {"role": "user", "content": "Test message here"}}\n|)
    transcript_file.print(%|{"type": "assistant", "timestamp": "2026-02-01T10:01:00Z", "message": {"role": "assistant", "content": "Test response here"}}\n|)
    transcript_file.close

    hook_input = {
      "session_id"       => test_session_id,
      "transcript_path"  => transcript_file.path,
      "stop_hook_active" => false,
    }.to_json

    result = run_binary(["on-stop"], stdin: hook_input)
    json = JSON.parse(result[:output])
    msg = json["systemMessage"].as_s
    msg.should contain("🔥")
    msg.should contain("Context 85%")

    File.delete(transcript_file.path)
  end

  it "shows critical when context exceeds critical threshold (90%)" do
    status = GalaxyLedger::ContextStatus.from_json(%|{"context": {"percentage": 90.0}}|)
    GalaxyLedger::Database.update_session_metrics(ledger_session_id, status)

    transcript_file = File.tempfile("transcript", ".jsonl")
    transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:00:00Z", "message": {"role": "user", "content": "Test message here"}}\n|)
    transcript_file.print(%|{"type": "assistant", "timestamp": "2026-02-01T10:01:00Z", "message": {"role": "assistant", "content": "Test response here"}}\n|)
    transcript_file.close

    hook_input = {
      "session_id"       => test_session_id,
      "transcript_path"  => transcript_file.path,
      "stop_hook_active" => false,
    }.to_json

    result = run_binary(["on-stop"], stdin: hook_input)
    json = JSON.parse(result[:output])
    msg = json["systemMessage"].as_s
    msg.should contain("🔥")
    msg.should contain("Context 90%")

    File.delete(transcript_file.path)
  end

  it "shows auto-compact message when autoCompactEnabled is true" do
    status = GalaxyLedger::ContextStatus.from_json(%|{"context": {"percentage": 90.0}}|)
    GalaxyLedger::Database.update_session_metrics(ledger_session_id, status)

    transcript_file = File.tempfile("transcript", ".jsonl")
    transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:00:00Z", "message": {"role": "user", "content": "Test message here"}}\n|)
    transcript_file.print(%|{"type": "assistant", "timestamp": "2026-02-01T10:01:00Z", "message": {"role": "assistant", "content": "Test response here"}}\n|)
    transcript_file.close

    # Create isolated .claude.json with auto-compact enabled
    claude_json = File.tempfile("claude", ".json")
    claude_json.print({"autoCompactEnabled" => true}.to_json)
    claude_json.close

    hook_input = {
      "session_id"       => test_session_id,
      "transcript_path"  => transcript_file.path,
      "stop_hook_active" => false,
    }.to_json

    result = run_binary(["on-stop"], stdin: hook_input, extra_env: {
      "GALAXY_CLAUDE_JSON_PATH" => claude_json.path,
    })
    json = JSON.parse(result[:output])
    msg = json["systemMessage"].as_s
    msg.should contain("🔥")
    msg.should contain("will auto-compact soon")
    msg.should_not contain("/clear now")

    File.delete(transcript_file.path)
    File.delete(claude_json.path)
  end

  it "shows /clear message when autoCompactEnabled is false" do
    status = GalaxyLedger::ContextStatus.from_json(%|{"context": {"percentage": 90.0}}|)
    GalaxyLedger::Database.update_session_metrics(ledger_session_id, status)

    transcript_file = File.tempfile("transcript", ".jsonl")
    transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:00:00Z", "message": {"role": "user", "content": "Test message here"}}\n|)
    transcript_file.print(%|{"type": "assistant", "timestamp": "2026-02-01T10:01:00Z", "message": {"role": "assistant", "content": "Test response here"}}\n|)
    transcript_file.close

    # Create isolated .claude.json with auto-compact disabled
    claude_json = File.tempfile("claude", ".json")
    claude_json.print({"autoCompactEnabled" => false}.to_json)
    claude_json.close

    hook_input = {
      "session_id"       => test_session_id,
      "transcript_path"  => transcript_file.path,
      "stop_hook_active" => false,
    }.to_json

    result = run_binary(["on-stop"], stdin: hook_input, extra_env: {
      "GALAXY_CLAUDE_JSON_PATH" => claude_json.path,
    })
    json = JSON.parse(result[:output])
    msg = json["systemMessage"].as_s
    msg.should contain("🔥")
    msg.should contain("context nearly full")
    msg.should contain("/clear now")
    msg.should_not contain("auto-compact")

    File.delete(transcript_file.path)
    File.delete(claude_json.path)
  end
end

describe "OnStop last_stop_cwd stamping" do
  test_session_id = "stop-cwd-stamp-#{Random.rand(10000)}"
  ledger_session_id = 0_i64

  before_each do
    GalaxyLedger::Database.delete_session(test_session_id)
    ledger_session_id = GalaxyLedger::Database.create_session(test_session_id)
  end

  after_each do
    GalaxyLedger::Database.delete_session(test_session_id)
  end

  it "stamps last_stop_cwd from hook input cwd" do
    transcript_file = File.tempfile("transcript", ".jsonl")
    transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:00:00Z", "message": {"role": "user", "content": "Test"}}\n|)
    transcript_file.print(%|{"type": "assistant", "timestamp": "2026-02-01T10:01:00Z", "message": {"role": "assistant", "content": "Response"}}\n|)
    transcript_file.close

    hook_input = {
      "session_id"       => test_session_id,
      "transcript_path"  => transcript_file.path,
      "cwd"              => "/home/user/projects/galaxy-poc",
      "stop_hook_active" => false,
    }.to_json

    result = run_binary(["on-stop"], stdin: hook_input)
    result[:status].should eq(0)

    session = GalaxyLedger::Database.get_session(test_session_id).not_nil!
    ctx = JSON.parse(session.context)
    ctx["last_stop_cwd"]?.should_not be_nil
    ctx["last_stop_cwd"].as_s.should eq("/home/user/projects/galaxy-poc")

    File.delete(transcript_file.path)
  end

  it "does not stamp last_stop_cwd when hook input has no cwd" do
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

    session = GalaxyLedger::Database.get_session(test_session_id).not_nil!
    ctx = JSON.parse(session.context)
    ctx["last_stop_cwd"]?.should be_nil

    File.delete(transcript_file.path)
  end

  it "survives concurrent status line updates without being clobbered" do
    # Simulate: session starts with cwd=/projects/kajabi
    status1 = GalaxyLedger::ContextStatus.from_json(
      %({"cwd":"/projects/galaxy-poc","context":{"percentage":30.0}})
    )
    GalaxyLedger::Database.update_session_metrics(ledger_session_id, status1)

    # Stop hook stamps last_stop_cwd
    transcript_file = File.tempfile("transcript", ".jsonl")
    transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:00:00Z", "message": {"role": "user", "content": "Test"}}\n|)
    transcript_file.print(%|{"type": "assistant", "timestamp": "2026-02-01T10:01:00Z", "message": {"role": "assistant", "content": "Response"}}\n|)
    transcript_file.close

    hook_input = {
      "session_id"       => test_session_id,
      "transcript_path"  => transcript_file.path,
      "cwd"              => "/projects/galaxy-poc",
      "stop_hook_active" => false,
    }.to_json

    result = run_binary(["on-stop"], stdin: hook_input)
    result[:status].should eq(0)

    # Status line fires AFTER reset → pushes project root
    status2 = GalaxyLedger::ContextStatus.from_json(
      %({"cwd":"/projects/kajabi","context":{"percentage":5.0}})
    )
    GalaxyLedger::Database.update_session_metrics(ledger_session_id, status2)

    # last_stop_cwd should survive the status line update
    session = GalaxyLedger::Database.get_session(test_session_id).not_nil!
    ctx = JSON.parse(session.context)
    ctx["last_stop_cwd"].as_s.should eq("/projects/galaxy-poc")

    File.delete(transcript_file.path)
  end
end

# Helper: build a complete config JSON with overrides for on_stop tests.
# Partial JSONs fall back to Config.default (everything enabled),
# so tests that need to disable features must write a full config.
def build_on_stop_config(extraction_on_stop : Bool, suggested_name_enabled : Bool) : String
  config = GalaxyLedger::Config.new
  config.extraction.on_stop = extraction_on_stop
  config.extraction.on_guideline_read = false
  config.suggested_name.enabled = suggested_name_enabled
  config.to_pretty_json
end

describe "OnStop background task count in systemMessage" do
  test_session_id = "bg-task-count-#{Random.rand(10000)}"
  ledger_session_id = 0_i64

  before_each do
    GalaxyLedger::Database.delete_session(test_session_id)
    ledger_session_id = GalaxyLedger::Database.create_session(test_session_id)
  end

  after_each do
    GalaxyLedger::Database.delete_session(test_session_id)
  end

  it "shows no background tasks when both extraction and suggestion are disabled" do
    File.write(SPEC_CONFIG_DIR / "config.json", build_on_stop_config(
      extraction_on_stop: false,
      suggested_name_enabled: false,
    ))

    transcript_file = File.tempfile("transcript", ".jsonl")
    transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:00:00Z", "message": {"role": "user", "content": "Test message"}}\n|)
    transcript_file.print(%|{"type": "assistant", "timestamp": "2026-02-01T10:01:00Z", "message": {"role": "assistant", "content": "Test response"}}\n|)
    transcript_file.close

    hook_input = {
      "session_id"       => test_session_id,
      "transcript_path"  => transcript_file.path,
      "stop_hook_active" => false,
    }.to_json

    result = run_binary(["on-stop"], stdin: hook_input)
    result[:status].should eq(0)

    json = JSON.parse(result[:output])
    msg = json["systemMessage"].as_s
    msg.should_not contain("background")

    File.delete(transcript_file.path)
  end

  it "shows singular 'task' when exactly one background task spawns" do
    File.write(SPEC_CONFIG_DIR / "config.json", build_on_stop_config(
      extraction_on_stop: true,
      suggested_name_enabled: false,
    ))

    transcript_file = File.tempfile("transcript", ".jsonl")
    transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:00:00Z", "message": {"role": "user", "content": "Test message"}}\n|)
    transcript_file.print(%|{"type": "assistant", "timestamp": "2026-02-01T10:01:00Z", "message": {"role": "assistant", "content": "Test response"}}\n|)
    transcript_file.close

    hook_input = {
      "session_id"       => test_session_id,
      "transcript_path"  => transcript_file.path,
      "stop_hook_active" => false,
    }.to_json

    result = run_binary(["on-stop"], stdin: hook_input)
    result[:status].should eq(0)

    json = JSON.parse(result[:output])
    msg = json["systemMessage"].as_s
    msg.should contain("1 background task spawned")
    msg.should_not contain("tasks")

    File.delete(transcript_file.path)
  end

  it "shows plural 'tasks' when multiple background tasks spawn" do
    File.write(SPEC_CONFIG_DIR / "config.json", build_on_stop_config(
      extraction_on_stop: true,
      suggested_name_enabled: true,
    ))

    transcript_file = File.tempfile("transcript", ".jsonl")
    transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:00:00Z", "message": {"role": "user", "content": "Test message"}}\n|)
    transcript_file.print(%|{"type": "assistant", "timestamp": "2026-02-01T10:01:00Z", "message": {"role": "assistant", "content": "Test response"}}\n|)
    transcript_file.close

    hook_input = {
      "session_id"       => test_session_id,
      "transcript_path"  => transcript_file.path,
      "stop_hook_active" => false,
    }.to_json

    result = run_binary(["on-stop"], stdin: hook_input)
    result[:status].should eq(0)

    json = JSON.parse(result[:output])
    msg = json["systemMessage"].as_s
    msg.should contain("background tasks spawned")
    # Should be at least 2 (extraction + name suggestion)
    msg.should_not contain("1 background")

    File.delete(transcript_file.path)
  end

  it "skips name suggestion when already finalized" do
    File.write(SPEC_CONFIG_DIR / "config.json", build_on_stop_config(
      extraction_on_stop: false,
      suggested_name_enabled: true,
    ))

    # Finalize the name so the pre-check short-circuits
    state_data = {
      "attempts"  => 1,
      "quality"   => 4,
      "finalized" => true,
      "status"    => "finalized_quality_met",
    }.to_json
    GalaxyLedger::Database.update_suggested_name_with_data(ledger_session_id, "Test Name", state_data)

    transcript_file = File.tempfile("transcript", ".jsonl")
    transcript_file.print(%|{"type": "user", "timestamp": "2026-02-01T10:00:00Z", "message": {"role": "user", "content": "Test message"}}\n|)
    transcript_file.print(%|{"type": "assistant", "timestamp": "2026-02-01T10:01:00Z", "message": {"role": "assistant", "content": "Test response"}}\n|)
    transcript_file.close

    hook_input = {
      "session_id"       => test_session_id,
      "transcript_path"  => transcript_file.path,
      "stop_hook_active" => false,
    }.to_json

    result = run_binary(["on-stop"], stdin: hook_input)
    result[:status].should eq(0)

    json = JSON.parse(result[:output])
    msg = json["systemMessage"].as_s
    # No background tasks — extraction disabled, name already finalized
    msg.should_not contain("background")

    File.delete(transcript_file.path)
  end
end

describe "OnStop timeline recording" do
  test_session_id = "on-stop-timeline-#{Random.rand(10000)}"
  ledger_session_id = 0_i64

  before_each do
    GalaxyLedger::Database.delete_session(test_session_id)
    ledger_session_id = GalaxyLedger::Database.create_session(
      test_session_id,
    )
  end

  after_each do
    GalaxyLedger::Database.delete_session(test_session_id)
  end

  it "succeeds even when galaxy-timeline is unavailable" do
    transcript_file = File.tempfile("transcript", ".jsonl")
    transcript_file.print(
      %|{"type":"user","timestamp":"2026-02-01T10:00:00Z",| \
      %|"message":{"role":"user","content":"Test"}}\n|,
    )
    transcript_file.print(
      %|{"type":"assistant","timestamp":"2026-02-01T10:01:00Z",| \
      %|"message":{"role":"assistant","content":"Response"}}\n|,
    )
    transcript_file.close

    hook_input = {
      "session_id"       => test_session_id,
      "transcript_path"  => transcript_file.path,
      "stop_hook_active" => false,
    }.to_json

    result = run_binary(["on-stop"], stdin: hook_input)
    result[:status].should eq(0)

    json = JSON.parse(result[:output])
    json["decision"].as_s.should eq("approve")

    File.delete(transcript_file.path)
  end
end

describe "OnStop turn state consumption" do
  test_session_id = "stop-turn-test-#{Random.rand(100000)}"
  ledger_session_id = 0_i64

  before_each do
    GalaxyLedger::Database.delete_session(test_session_id)
    ledger_session_id = GalaxyLedger::Database.create_session(
      test_session_id,
    )
    GalaxyLedger::Hooks::TurnState.delete(test_session_id)
  end

  after_each do
    GalaxyLedger::Database.delete_session(test_session_id)
    GalaxyLedger::Hooks::TurnState.delete(test_session_id)
  end

  it "deletes turn state file when it exists" do
    GalaxyLedger::Hooks::TurnState.write(
      test_session_id,
      "stop-uuid-123",
      "Tell me about the architecture",
    )
    flush_wal

    transcript_file = File.tempfile("transcript", ".jsonl")
    transcript_file.print(
      %|{"type":"user","timestamp":"2026-02-01T10:00:00Z",| \
      %|"message":{"role":"user","content":"Test"}}\n|,
    )
    transcript_file.close

    hook_input = {
      "session_id"             => test_session_id,
      "transcript_path"        => transcript_file.path,
      "stop_hook_active"       => false,
      "last_assistant_message" => "Here is the architecture...",
    }.to_json

    result = run_binary(["on-stop"], stdin: hook_input)
    result[:status].should eq(0)

    # State file should be consumed
    GalaxyLedger::Hooks::TurnState.exists?(
      test_session_id,
    ).should be_false

    File.delete(transcript_file.path)
  end

  it "runs cleanly when no state file exists" do
    flush_wal

    transcript_file = File.tempfile("transcript", ".jsonl")
    transcript_file.print(
      %|{"type":"user","timestamp":"2026-02-01T10:00:00Z",| \
      %|"message":{"role":"user","content":"Test"}}\n|,
    )
    transcript_file.close

    hook_input = {
      "session_id"             => test_session_id,
      "transcript_path"        => transcript_file.path,
      "stop_hook_active"       => false,
      "last_assistant_message" => "Agent-initiated response",
    }.to_json

    result = run_binary(["on-stop"], stdin: hook_input)
    result[:status].should eq(0)

    # Should still produce valid output
    json = JSON.parse(result[:output])
    json["decision"].as_s.should eq("approve")

    File.delete(transcript_file.path)
  end

  it "skips turn recording for mismatched session_id" do
    # Write a state file for a different session
    GalaxyLedger::Hooks::TurnState.write(
      "other-session-id",
      "other-uuid",
      "other message",
    )
    flush_wal

    transcript_file = File.tempfile("transcript", ".jsonl")
    transcript_file.print(
      %|{"type":"user","timestamp":"2026-02-01T10:00:00Z",| \
      %|"message":{"role":"user","content":"Test"}}\n|,
    )
    transcript_file.close

    hook_input = {
      "session_id"             => test_session_id,
      "transcript_path"        => transcript_file.path,
      "stop_hook_active"       => false,
      "last_assistant_message" => "Response",
    }.to_json

    result = run_binary(["on-stop"], stdin: hook_input)
    result[:status].should eq(0)

    # The other session's state file should still exist
    # (not consumed by this session's Stop)
    GalaxyLedger::Hooks::TurnState.exists?(
      "other-session-id",
    ).should be_true

    File.delete(transcript_file.path)
    GalaxyLedger::Hooks::TurnState.delete("other-session-id")
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
