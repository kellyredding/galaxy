require "../spec_helper"

describe "OnClear GALAXY_SKIP_HOOKS" do
  it "returns early when GALAXY_SKIP_HOOKS=1 is set" do
    ENV["GALAXY_SKIP_HOOKS"] = "1"

    test_session_id = "skip-hooks-test-#{Random.rand(10000)}"

    # Ensure session record exists and write last interaction to DB
    ledger_session_id = GalaxyLedger::Database.create_session(test_session_id)
    exchange = GalaxyLedger::Exchange::LastExchange.new(
      user_message: "Test message",
      full_content: "Test response",
      assistant_messages: [] of GalaxyLedger::Exchange::AssistantMessage
    )
    GalaxyLedger::Database.update_session_last_interaction(ledger_session_id, exchange.to_pretty_json)

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-clear"], stdin: hook_input)
    result[:status].should eq(0)

    # Should return empty output (no terminal display, no hookSpecificOutput)
    result[:output].strip.should eq("")
  ensure
    ENV.delete("GALAXY_SKIP_HOOKS")
  end
end

describe GalaxyLedger::Hooks::OnClear do
  describe "#run" do
    it "creates instance successfully" do
      handler = GalaxyLedger::Hooks::OnClear.new
      handler.should be_a(GalaxyLedger::Hooks::OnClear)
    end
  end
end

describe "OnClear JSON output" do
  test_session_id = "clear-json-#{Random.rand(10000)}"
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
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-clear"], stdin: hook_input)
    result[:status].should eq(0)

    # Must be valid JSON
    output = JSON.parse(result[:output])
    output["systemMessage"].should be_a(JSON::Any)
    output["hookSpecificOutput"]["hookEventName"].should eq("SessionStart")
    output["hookSpecificOutput"]["additionalContext"].should be_a(JSON::Any)
  end

  it "outputs no non-JSON text on stdout" do
    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-clear"], stdin: hook_input)
    result[:status].should eq(0)

    # The entire stdout should be a single JSON object
    JSON.parse(result[:output].strip) # Should not raise
  end
end

describe "OnClear systemMessage" do
  test_session_id = "clear-sm-#{Random.rand(10000)}"
  ledger_session_id = 0_i64

  before_each do
    GalaxyLedger::Database.delete_session(test_session_id)
    ledger_session_id = GalaxyLedger::Database.create_session(test_session_id)
  end

  after_each do
    GalaxyLedger::Database.delete_session(test_session_id)
  end

  it "includes entry counts when data exists" do
    # Add some guideline entries
    3.times do |i|
      entry = GalaxyLedger::Entry.new(
        entry_type: "guideline",
        content: "Guideline rule #{i + 1}",
        importance: "medium",
        source_file: "/home/user/agent-guidelines/ruby-style.md"
      )
      GalaxyLedger::Database.insert(ledger_session_id, entry)
    end

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-clear"], stdin: hook_input)
    output = JSON.parse(result[:output])
    msg = output["systemMessage"].as_s
    msg.should contain("Handoff")
    msg.should contain("3 guidelines")
  end

  it "includes session file count" do
    # Add a session file
    GalaxyLedger::Database.upsert_session_file(
      ledger_session_id, "/home/user/app.rb", :read
    )

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-clear"], stdin: hook_input)
    output = JSON.parse(result[:output])
    msg = output["systemMessage"].as_s
    msg.should contain("1 session file")
  end

  it "includes last exchange snippet" do
    exchange = GalaxyLedger::Exchange::LastExchange.new(
      user_message: "Fix the auth bug in login flow",
      full_content: "I fixed the auth bug.",
      assistant_messages: [] of GalaxyLedger::Exchange::AssistantMessage
    )
    GalaxyLedger::Database.update_session_last_interaction(ledger_session_id, exchange.to_pretty_json)

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-clear"], stdin: hook_input)
    output = JSON.parse(result[:output])
    msg = output["systemMessage"].as_s
    msg.should contain("Last:")
    msg.should contain("Fix the auth bug")
  end

  it "combines counts and files in status line" do
    # Add guidelines and decisions
    entry = GalaxyLedger::Entry.new(
      entry_type: "guideline",
      content: "Use double quotes",
      importance: "medium",
      source_file: "/home/user/guidelines/ruby.md"
    )
    GalaxyLedger::Database.insert(ledger_session_id, entry)

    entry = GalaxyLedger::Entry.new(
      entry_type: "decision",
      content: "Use SQLite",
      importance: "high"
    )
    GalaxyLedger::Database.insert(ledger_session_id, entry)

    GalaxyLedger::Database.upsert_session_file(ledger_session_id, "/home/user/app.rb", :edit)

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-clear"], stdin: hook_input)
    output = JSON.parse(result[:output])
    msg = output["systemMessage"].as_s
    msg.should contain("1 guideline")
    msg.should contain("1 decision")
    msg.should contain("1 session file")
  end
end

describe "OnClear additionalContext" do
  test_session_id = "clear-ctx-#{Random.rand(10000)}"
  ledger_session_id = 0_i64

  before_each do
    GalaxyLedger::Database.delete_session(test_session_id)
    ledger_session_id = GalaxyLedger::Database.create_session(test_session_id)
  end

  after_each do
    GalaxyLedger::Database.delete_session(test_session_id)
  end

  it "includes header and Ledger PID" do
    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-clear"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("## Session Context Handoff")
    ctx.should contain("**Ledger PID**:")
  end

  it "uses --pid in command examples" do
    exchange = GalaxyLedger::Exchange::LastExchange.new(
      user_message: "Test",
      full_content: "Response",
      assistant_messages: [] of GalaxyLedger::Exchange::AssistantMessage
    )
    GalaxyLedger::Database.update_session_last_interaction(ledger_session_id, exchange.to_pretty_json)

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-clear"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("--pid")
    ctx.should_not contain("--session")
  end

  it "includes orientation paragraph when data exists" do
    exchange = GalaxyLedger::Exchange::LastExchange.new(
      user_message: "Test",
      full_content: "Response",
      assistant_messages: [] of GalaxyLedger::Exchange::AssistantMessage
    )
    GalaxyLedger::Database.update_session_last_interaction(ledger_session_id, exchange.to_pretty_json)

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-clear"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("Your context was just reset")
    ctx.should contain("full awareness")
  end

  it "includes recovery directives with PID-scoped commands" do
    exchange = GalaxyLedger::Exchange::LastExchange.new(
      user_message: "Test",
      full_content: "Response",
      assistant_messages: [] of GalaxyLedger::Exchange::AssistantMessage
    )
    GalaxyLedger::Database.update_session_last_interaction(ledger_session_id, exchange.to_pretty_json)

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-clear"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("Query the ledger")
    ctx.should contain("galaxy-ledger search")
    ctx.should contain("galaxy-ledger list-files")
    ctx.should contain("git diff")
    ctx.should contain("Fall back to normal exploration")
  end

  it "includes guidelines grouped by source file" do
    2.times do |i|
      entry = GalaxyLedger::Entry.new(
        entry_type: "guideline",
        content: "Ruby rule #{i + 1}",
        importance: "medium",
        source_file: "/home/user/agent-guidelines/ruby-style.md"
      )
      GalaxyLedger::Database.insert(ledger_session_id, entry)
    end

    entry = GalaxyLedger::Entry.new(
      entry_type: "guideline",
      content: "RSpec rule 1",
      importance: "medium",
      source_file: "/home/user/agent-guidelines/rspec-style.md"
    )
    GalaxyLedger::Database.insert(ledger_session_id, entry)

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-clear"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("### Guidelines Active This Session")
    ctx.should contain("ruby-style.md")
    ctx.should contain("rspec-style.md")
    ctx.should contain("Ruby rule 1")
    ctx.should contain("RSpec rule 1")
  end

  it "includes key decisions with importance labels" do
    entry_high = GalaxyLedger::Entry.new(
      entry_type: "decision",
      content: "Use SQLite for storage",
      importance: "high"
    )
    GalaxyLedger::Database.insert(ledger_session_id, entry_high)

    entry_med = GalaxyLedger::Entry.new(
      entry_type: "decision",
      content: "Use JSON output format",
      importance: "medium"
    )
    GalaxyLedger::Database.insert(ledger_session_id, entry_med)

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-clear"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("### Key Decisions")
    ctx.should contain("Use SQLite for storage (high)")
    ctx.should contain("Use JSON output format (medium)")
  end

  it "includes session file manifest split by operation" do
    GalaxyLedger::Database.upsert_session_file(ledger_session_id, "/home/user/src/app.cr", :edit)
    GalaxyLedger::Database.upsert_session_file(ledger_session_id, "/home/user/src/app.cr", :read)
    GalaxyLedger::Database.upsert_session_file(ledger_session_id, "/home/user/README.md", :read)

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-clear"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("### Session File Manifest")
    ctx.should contain("**Edited/Written:**")
    ctx.should contain("src/app.cr")
    ctx.should contain("**Read:**")
    ctx.should contain("README.md")
  end
end

describe "OnClear cwd and git_branch in additionalContext" do
  it "includes working directory when session has cwd" do
    test_session_id = "clear-cwd-#{Random.rand(10000)}"
    ledger_session_id = GalaxyLedger::Database.create_session(test_session_id)
    GalaxyLedger::Database.update_session(ledger_session_id, cwd: "#{Path.home}/projects/my-app")

    # Add data so we get full context (not empty)
    exchange = GalaxyLedger::Exchange::LastExchange.new(
      user_message: "Test",
      full_content: "Response",
      assistant_messages: [] of GalaxyLedger::Exchange::AssistantMessage
    )
    GalaxyLedger::Database.update_session_last_interaction(ledger_session_id, exchange.to_pretty_json)

    hook_input = {"session_id" => test_session_id, "source" => "clear"}.to_json

    result = run_binary(["on-clear"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("**Working directory**: `~/projects/my-app`")
  end

  it "uses previous_cwd from context JSON when status line has overwritten cwd" do
    test_session_id = "clear-prev-cwd-#{Random.rand(10000)}"
    ledger_session_id = GalaxyLedger::Database.create_session(test_session_id,
      cwd: "#{Path.home}/projects/galaxy",
    )

    # Simulate the timing issue: status line fires after reset and overwrites
    # cwd to the project root, but previous_cwd is preserved in context JSON.
    status = GalaxyLedger::ContextStatus.from_json(%({"cwd":"#{Path.home}/projects/kajabi","context":{"percentage":5.0}}))
    GalaxyLedger::Database.update_session_metrics(ledger_session_id, status)

    # Add data so we get full context (not empty)
    exchange = GalaxyLedger::Exchange::LastExchange.new(
      user_message: "Test",
      full_content: "Response",
      assistant_messages: [] of GalaxyLedger::Exchange::AssistantMessage
    )
    GalaxyLedger::Database.update_session_last_interaction(ledger_session_id, exchange.to_pretty_json)

    hook_input = {"session_id" => test_session_id, "source" => "clear"}.to_json

    result = run_binary(["on-clear"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    # Should show the PREVIOUS cwd (where user was working), not the current
    # cwd (project root after reset)
    ctx.should contain("**Working directory**: `~/projects/galaxy`")
    ctx.should_not contain("**Working directory**: `~/projects/kajabi`")
  end

  it "includes git branch when session has git_branch" do
    test_session_id = "clear-branch-#{Random.rand(10000)}"
    ledger_session_id = GalaxyLedger::Database.create_session(test_session_id)
    GalaxyLedger::Database.update_session(ledger_session_id, git_branch: "kr/feature-branch")

    exchange = GalaxyLedger::Exchange::LastExchange.new(
      user_message: "Test",
      full_content: "Response",
      assistant_messages: [] of GalaxyLedger::Exchange::AssistantMessage
    )
    GalaxyLedger::Database.update_session_last_interaction(ledger_session_id, exchange.to_pretty_json)

    hook_input = {"session_id" => test_session_id, "source" => "clear"}.to_json

    result = run_binary(["on-clear"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("**Git branch**: `kr/feature-branch`")
  end

  it "omits working directory and git branch when nil" do
    test_session_id = "clear-no-cwd-#{Random.rand(10000)}"
    ledger_session_id = GalaxyLedger::Database.create_session(test_session_id)

    exchange = GalaxyLedger::Exchange::LastExchange.new(
      user_message: "Test",
      full_content: "Response",
      assistant_messages: [] of GalaxyLedger::Exchange::AssistantMessage
    )
    GalaxyLedger::Database.update_session_last_interaction(ledger_session_id, exchange.to_pretty_json)

    hook_input = {"session_id" => test_session_id, "source" => "clear"}.to_json

    result = run_binary(["on-clear"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should_not contain("**Working directory**:")
    ctx.should_not contain("**Git branch**:")
  end

  it "includes both cwd and git_branch together" do
    test_session_id = "clear-both-#{Random.rand(10000)}"
    ledger_session_id = GalaxyLedger::Database.create_session(test_session_id)
    GalaxyLedger::Database.update_session(
      ledger_session_id,
      cwd: "#{Path.home}/projects/galaxy",
      git_branch: "main",
    )

    exchange = GalaxyLedger::Exchange::LastExchange.new(
      user_message: "Test",
      full_content: "Response",
      assistant_messages: [] of GalaxyLedger::Exchange::AssistantMessage
    )
    GalaxyLedger::Database.update_session_last_interaction(ledger_session_id, exchange.to_pretty_json)

    hook_input = {"session_id" => test_session_id, "source" => "clear"}.to_json

    result = run_binary(["on-clear"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("**Working directory**: `~/projects/galaxy`")
    ctx.should contain("**Git branch**: `main`")
  end
end

describe "OnClear edge cases" do
  it "handles empty session_id gracefully" do
    hook_input = {
      "session_id" => "",
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-clear"], stdin: hook_input)
    result[:status].should eq(0)
    output = JSON.parse(result[:output])
    output["hookSpecificOutput"].should_not be_nil
  end

  it "handles empty stdin gracefully" do
    result = run_binary(["on-clear"], stdin: "")
    result[:status].should eq(0)
    output = JSON.parse(result[:output])
    output["hookSpecificOutput"].should_not be_nil
  end

  it "handles malformed JSON stdin gracefully" do
    result = run_binary(["on-clear"], stdin: "not valid json {{{")
    result[:status].should eq(0)
    output = JSON.parse(result[:output])
    output["hookSpecificOutput"].should_not be_nil
  end
end

describe "OnClear cwd reset timing regression" do
  # End-to-end test for the cwd timing issue:
  # 1. Session starts in /projects/galaxy (status line updates cwd)
  # 2. /clear fires → Claude resets to project root
  # 3. Status line fires → overwrites cwd to /projects/kajabi
  # 4. Handoff should still report /projects/galaxy (from previous_cwd)

  it "full cycle: status line updates, cwd changes on reset, handoff reports previous" do
    session_id = "e2e-cwd-reset-#{Random.rand(100000)}"
    ledger_session_id = GalaxyLedger::Database.create_session(session_id,
      cwd: "#{Path.home}/projects/kajabi",
    )

    begin
      # Step 1: Status line updates cwd to where user cd'd during session
      status1 = GalaxyLedger::ContextStatus.from_json(
        %({"cwd":"#{Path.home}/projects/galaxy","context":{"percentage":25.0}})
      )
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status1)

      # Verify: cwd is now galaxy, previous_cwd is kajabi
      s1 = GalaxyLedger::Database.get_session(session_id).not_nil!
      s1.cwd.should eq("#{Path.home}/projects/galaxy")
      JSON.parse(s1.context)["previous_cwd"].as_s.should eq("#{Path.home}/projects/kajabi")

      # Step 2: More status line ticks with same cwd (previous_cwd stays put)
      status2 = GalaxyLedger::ContextStatus.from_json(
        %({"cwd":"#{Path.home}/projects/galaxy","context":{"percentage":40.0}})
      )
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status2)

      s2 = GalaxyLedger::Database.get_session(session_id).not_nil!
      JSON.parse(s2.context)["previous_cwd"].as_s.should eq("#{Path.home}/projects/kajabi")

      # Step 3: /clear happens → Claude resets → status line pushes project root
      status3 = GalaxyLedger::ContextStatus.from_json(
        %({"cwd":"#{Path.home}/projects/kajabi","context":{"percentage":5.0}})
      )
      GalaxyLedger::Database.update_session_metrics(ledger_session_id, status3)

      # Verify: cwd is now kajabi (wrong), but previous_cwd is galaxy (correct)
      s3 = GalaxyLedger::Database.get_session(session_id).not_nil!
      s3.cwd.should eq("#{Path.home}/projects/kajabi")
      JSON.parse(s3.context)["previous_cwd"].as_s.should eq("#{Path.home}/projects/galaxy")

      # Step 4: Handoff runs — should use previous_cwd, not cwd
      exchange = GalaxyLedger::Exchange::LastExchange.new(
        user_message: "Working on galaxy",
        full_content: "Implemented feature",
        assistant_messages: [] of GalaxyLedger::Exchange::AssistantMessage
      )
      GalaxyLedger::Database.update_session_last_interaction(ledger_session_id, exchange.to_pretty_json)

      hook_input = {"session_id" => session_id, "source" => "clear"}.to_json
      result = run_binary(["on-clear"], stdin: hook_input)
      result[:status].should eq(0)

      output = JSON.parse(result[:output])
      ctx = output["hookSpecificOutput"]["additionalContext"].as_s
      ctx.should contain("**Working directory**: `~/projects/galaxy`")
      ctx.should_not contain("**Working directory**: `~/projects/kajabi`")
    ensure
      GalaxyLedger::Database.delete_session(session_id)
    end
  end

  it "falls back to live cwd when no previous_cwd exists" do
    session_id = "e2e-cwd-no-prev-#{Random.rand(100000)}"
    ledger_session_id = GalaxyLedger::Database.create_session(session_id,
      cwd: "#{Path.home}/projects/my-app",
    )

    begin
      # No status line updates — no previous_cwd in context JSON
      exchange = GalaxyLedger::Exchange::LastExchange.new(
        user_message: "Test",
        full_content: "Response",
        assistant_messages: [] of GalaxyLedger::Exchange::AssistantMessage
      )
      GalaxyLedger::Database.update_session_last_interaction(ledger_session_id, exchange.to_pretty_json)

      hook_input = {"session_id" => session_id, "source" => "clear"}.to_json
      result = run_binary(["on-clear"], stdin: hook_input)
      result[:status].should eq(0)

      output = JSON.parse(result[:output])
      ctx = output["hookSpecificOutput"]["additionalContext"].as_s
      ctx.should contain("**Working directory**: `~/projects/my-app`")
    ensure
      GalaxyLedger::Database.delete_session(session_id)
    end
  end
end
