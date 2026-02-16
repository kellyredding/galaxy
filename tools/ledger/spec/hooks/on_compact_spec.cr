require "../spec_helper"

describe "OnCompact GALAXY_SKIP_HOOKS" do
  it "returns early when GALAXY_SKIP_HOOKS=1 is set" do
    ENV["GALAXY_SKIP_HOOKS"] = "1"

    test_session_id = "skip-hooks-compact-#{Random.rand(10000)}"

    ledger_session_id = GalaxyLedger::Database.create_session(test_session_id)
    exchange = GalaxyLedger::Exchange::LastExchange.new(
      user_message: "Test message",
      full_content: "Test response",
      assistant_messages: [] of GalaxyLedger::Exchange::AssistantMessage
    )
    GalaxyLedger::Database.update_session_last_interaction(ledger_session_id, exchange.to_pretty_json)

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "compact",
    }.to_json

    result = run_binary(["on-compact"], stdin: hook_input)
    result[:status].should eq(0)
    result[:output].strip.should eq("")
  ensure
    ENV.delete("GALAXY_SKIP_HOOKS")
  end
end

describe GalaxyLedger::Hooks::OnCompact do
  describe "#run" do
    it "creates instance successfully" do
      handler = GalaxyLedger::Hooks::OnCompact.new
      handler.should be_a(GalaxyLedger::Hooks::OnCompact)
    end
  end
end

describe "OnCompact JSON output" do
  test_session_id = "compact-json-#{Random.rand(10000)}"
  ledger_session_id = 0_i64

  before_each do
    GalaxyLedger::Database.delete_session(test_session_id)
    ledger_session_id = GalaxyLedger::Database.create_session(test_session_id)
  end

  after_each do
    GalaxyLedger::Database.delete_session(test_session_id)
  end

  it "outputs clean JSON with systemMessage and hookSpecificOutput" do
    hook_input = {
      "session_id" => test_session_id,
      "source"     => "compact",
    }.to_json

    result = run_binary(["on-compact"], stdin: hook_input)
    result[:status].should eq(0)

    output = JSON.parse(result[:output])
    output["systemMessage"].should be_a(JSON::Any)
    output["hookSpecificOutput"]["hookEventName"].should eq("SessionStart")
    output["hookSpecificOutput"]["additionalContext"].should be_a(JSON::Any)
  end
end

describe "OnCompact systemMessage" do
  test_session_id = "compact-sm-#{Random.rand(10000)}"
  ledger_session_id = 0_i64

  before_each do
    GalaxyLedger::Database.delete_session(test_session_id)
    ledger_session_id = GalaxyLedger::Database.create_session(test_session_id)
  end

  after_each do
    GalaxyLedger::Database.delete_session(test_session_id)
  end

  it "includes entry counts when data exists" do
    3.times do |i|
      entry = GalaxyLedger::Entry.new(
        entry_type: "guideline",
        content: "Compact guideline #{i + 1}",
        importance: "medium",
        source_file: "/home/user/agent-guidelines/ruby-style.md"
      )
      GalaxyLedger::Database.insert(ledger_session_id, entry)
    end

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "compact",
    }.to_json

    result = run_binary(["on-compact"], stdin: hook_input)
    output = JSON.parse(result[:output])
    msg = output["systemMessage"].as_s
    msg.should contain("Handoff")
    msg.should contain("3 guidelines")
  end
end

describe "OnCompact additionalContext" do
  test_session_id = "compact-ctx-#{Random.rand(10000)}"
  ledger_session_id = 0_i64

  before_each do
    GalaxyLedger::Database.delete_session(test_session_id)
    ledger_session_id = GalaxyLedger::Database.create_session(test_session_id)
  end

  after_each do
    GalaxyLedger::Database.delete_session(test_session_id)
  end

  it "includes context handoff header" do
    hook_input = {
      "session_id" => test_session_id,
      "source"     => "compact",
    }.to_json

    result = run_binary(["on-compact"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("## Session Context Handoff")
    ctx.should contain("**Ledger PID**:")
  end

  it "includes full restoration data (same as on-clear)" do
    entry = GalaxyLedger::Entry.new(
      entry_type: "decision",
      content: "Use SQLite for compact test",
      importance: "high"
    )
    GalaxyLedger::Database.insert(ledger_session_id, entry)

    GalaxyLedger::Database.upsert_session_file(ledger_session_id, "/home/user/src/app.cr", :edit)

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "compact",
    }.to_json

    result = run_binary(["on-compact"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("### Key Decisions")
    ctx.should contain("Use SQLite for compact test")
    ctx.should contain("### Session File Manifest")
  end
end

describe "OnCompact edge cases" do
  it "handles empty stdin gracefully" do
    result = run_binary(["on-compact"], stdin: "")
    result[:status].should eq(0)
    output = JSON.parse(result[:output])
    output["hookSpecificOutput"].should_not be_nil
  end

  it "handles malformed JSON stdin gracefully" do
    result = run_binary(["on-compact"], stdin: "not valid json {{{")
    result[:status].should eq(0)
    output = JSON.parse(result[:output])
    output["hookSpecificOutput"].should_not be_nil
  end
end
