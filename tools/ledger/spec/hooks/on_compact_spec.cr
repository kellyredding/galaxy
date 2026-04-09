require "../spec_helper"

describe "OnCompact GALAXY_SKIP_HOOKS" do
  it "returns early when GALAXY_SKIP_HOOKS=1 is set" do
    ENV["GALAXY_SKIP_HOOKS"] = "1"

    test_session_id = "skip-hooks-compact-#{Random.rand(10000)}"

    ledger_session_id = GalaxyLedger::Database.create_session(test_session_id)

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
    ledger_session_id = GalaxyLedger::Database.create_session(
      test_session_id, claude_pid: Process.pid.to_i64)
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
    ledger_session_id = GalaxyLedger::Database.create_session(
      test_session_id, claude_pid: Process.pid.to_i64)
  end

  after_each do
    GalaxyLedger::Database.delete_session(test_session_id)
  end

  it "includes entry counts when data exists" do
    3.times do |i|
      entry = GalaxyLedger::Entry.new(
        entry_type: "learning",
        content: "Compact learning #{i + 1}",
        importance: "medium",
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
    msg.should contain("3 learnings")
  end
end

describe "OnCompact additionalContext" do
  test_session_id = "compact-ctx-#{Random.rand(10000)}"
  ledger_session_id = 0_i64

  before_each do
    GalaxyLedger::Database.delete_session(test_session_id)
    ledger_session_id = GalaxyLedger::Database.create_session(
      test_session_id, claude_pid: Process.pid.to_i64)
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

describe "OnCompact cwd and git_branch in additionalContext" do
  it "includes working directory when session has cwd" do
    test_session_id = "compact-cwd-#{Random.rand(10000)}"
    ledger_session_id = GalaxyLedger::Database.create_session(test_session_id)
    GalaxyLedger::Database.update_session(ledger_session_id, cwd: "#{Path.home}/projects/my-app")

    GalaxyLedger::Database.upsert_session_file(ledger_session_id, "/tmp/test.cr", :read)

    hook_input = {"session_id" => test_session_id, "source" => "compact"}.to_json

    result = run_binary(["on-compact"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("**Working directory**: `~/projects/my-app`")
  end

  it "includes git branch when session has git_branch" do
    test_session_id = "compact-branch-#{Random.rand(10000)}"
    ledger_session_id = GalaxyLedger::Database.create_session(test_session_id)
    GalaxyLedger::Database.update_session(ledger_session_id, git_branch: "kr/feature-branch")

    GalaxyLedger::Database.upsert_session_file(ledger_session_id, "/tmp/test.cr", :read)

    hook_input = {"session_id" => test_session_id, "source" => "compact"}.to_json

    result = run_binary(["on-compact"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("**Git branch**: `kr/feature-branch`")
  end

  it "omits working directory and git branch when nil" do
    test_session_id = "compact-no-cwd-#{Random.rand(10000)}"
    ledger_session_id = GalaxyLedger::Database.create_session(test_session_id)

    GalaxyLedger::Database.upsert_session_file(ledger_session_id, "/tmp/test.cr", :read)

    hook_input = {"session_id" => test_session_id, "source" => "compact"}.to_json

    result = run_binary(["on-compact"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should_not contain("**Working directory**:")
    ctx.should_not contain("**Git branch**:")
  end
end

describe "OnCompact timeline recording" do
  it "succeeds even when galaxy-timeline is unavailable" do
    test_session_id = "compact-timeline-#{Random.rand(10000)}"
    ledger_session_id = GalaxyLedger::Database.create_session(
      test_session_id, claude_pid: Process.pid.to_i64)

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "compact",
    }.to_json

    result = run_binary(["on-compact"], stdin: hook_input)
    result[:status].should eq(0)

    output = JSON.parse(result[:output])
    output["systemMessage"].as_s.should contain("Handoff")
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("## Session Context Handoff")
  end

  it "still produces full handoff with restoration data" do
    test_session_id = "compact-timeline-data-#{Random.rand(10000)}"
    ledger_session_id = GalaxyLedger::Database.create_session(
      test_session_id, claude_pid: Process.pid.to_i64)

    entry = GalaxyLedger::Entry.new(
      entry_type: "learning",
      content: "Compact timeline test learning",
      importance: "medium",
    )
    GalaxyLedger::Database.insert(ledger_session_id, entry)

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "compact",
    }.to_json

    result = run_binary(["on-compact"], stdin: hook_input)
    result[:status].should eq(0)

    output = JSON.parse(result[:output])
    msg = output["systemMessage"].as_s
    msg.should contain("1 learning")
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("Compact timeline test learning")
  end
end

describe "OnCompact orphan turn cleanup" do
  it "deletes orphaned turn state file during compact" do
    test_session_id = "compact-orphan-#{Random.rand(10000)}"
    ledger_session_id = GalaxyLedger::Database.create_session(
      test_session_id, claude_pid: Process.pid.to_i64)

    # Create an orphaned turn state file
    GalaxyLedger::Hooks::TurnState.write(
      test_session_id,
      "orphan-uuid-compact",
      "orphan message from compact",
    )

    GalaxyLedger::Hooks::TurnState.exists?(
      test_session_id,
    ).should be_true

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "compact",
    }.to_json

    result = run_binary(["on-compact"], stdin: hook_input)
    result[:status].should eq(0)

    # The orphaned turn state file should be cleaned up
    GalaxyLedger::Hooks::TurnState.exists?(
      test_session_id,
    ).should be_false
  end

  it "succeeds when no orphaned turn state exists" do
    test_session_id = "compact-no-orphan-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(
      test_session_id, claude_pid: Process.pid.to_i64)

    GalaxyLedger::Hooks::TurnState.exists?(
      test_session_id,
    ).should be_false

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "compact",
    }.to_json

    result = run_binary(["on-compact"], stdin: hook_input)
    result[:status].should eq(0)

    output = JSON.parse(result[:output])
    output["systemMessage"].should be_a(JSON::Any)
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
