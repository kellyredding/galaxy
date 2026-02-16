require "../spec_helper"

describe "OnResume GALAXY_SKIP_HOOKS" do
  it "returns early when GALAXY_SKIP_HOOKS=1 is set" do
    ENV["GALAXY_SKIP_HOOKS"] = "1"

    test_session_id = "skip-hooks-resume-#{Random.rand(10000)}"
    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    result[:status].should eq(0)
    result[:output].strip.should eq("")
  ensure
    ENV.delete("GALAXY_SKIP_HOOKS")
  end
end

describe GalaxyLedger::Hooks::OnResume do
  describe "#run" do
    it "creates instance successfully" do
      handler = GalaxyLedger::Hooks::OnResume.new
      handler.should be_a(GalaxyLedger::Hooks::OnResume)
    end
  end
end

describe "OnResume JSON output" do
  it "outputs clean JSON with systemMessage and hookSpecificOutput" do
    test_session_id = "resume-json-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(test_session_id)

    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    result[:status].should eq(0)

    output = JSON.parse(result[:output])
    output["systemMessage"].should be_a(JSON::Any)
    output["hookSpecificOutput"]["hookEventName"].should eq("SessionStart")
    output["hookSpecificOutput"]["additionalContext"].should be_a(JSON::Any)
  end
end

describe "OnResume systemMessage" do
  it "shows 'Resumed' prefix" do
    test_session_id = "resume-sm-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(test_session_id)

    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    output = JSON.parse(result[:output])
    msg = output["systemMessage"].as_s
    msg.should contain("Resumed")
  end

  it "shows data counts when session has data" do
    test_session_id = "resume-sm-data-#{Random.rand(10000)}"
    ledger_id = GalaxyLedger::Database.create_session(test_session_id)

    2.times do |i|
      entry = GalaxyLedger::Entry.new(
        entry_type: "guideline",
        content: "Resume guideline #{i + 1}",
        importance: "medium",
        source_file: "/home/user/guidelines/style.md"
      )
      GalaxyLedger::Database.insert(ledger_id, entry)
    end

    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    output = JSON.parse(result[:output])
    msg = output["systemMessage"].as_s
    msg.should contain("Resumed")
    msg.should contain("2 guidelines")
  end
end

describe "OnResume additionalContext" do
  it "includes Galaxy Ledger heading" do
    test_session_id = "resume-ctx-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(test_session_id)

    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("## Galaxy Ledger")
  end

  it "includes Ledger PID" do
    test_session_id = "resume-ctx-pid-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(test_session_id)

    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("**Ledger PID**:")
  end

  it "includes ledger awareness description" do
    test_session_id = "resume-ctx-aware-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(test_session_id)

    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("persistent context ledger")
    ctx.should contain("Guidelines")
    ctx.should contain("Decisions")
    ctx.should contain("Learnings")
  end

  it "includes lookup directives with --pid" do
    test_session_id = "resume-ctx-lookup-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(test_session_id)

    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("Query the ledger")
    ctx.should contain("galaxy-ledger search")
    ctx.should contain("--pid")
    ctx.should contain("galaxy-ledger list-files")
  end

  it "includes resumed session note when data exists" do
    test_session_id = "resume-ctx-note-#{Random.rand(10000)}"
    ledger_id = GalaxyLedger::Database.create_session(test_session_id)

    entry = GalaxyLedger::Entry.new(
      entry_type: "guideline",
      content: "Test guideline for resume",
      importance: "medium",
      source_file: "/home/user/guidelines/style.md"
    )
    GalaxyLedger::Database.insert(ledger_id, entry)

    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("resumed session")
    ctx.should contain("conversation history is already")
    ctx.should contain("1 guidelines")
  end

  it "includes condensed counts for accumulated data" do
    test_session_id = "resume-ctx-counts-#{Random.rand(10000)}"
    ledger_id = GalaxyLedger::Database.create_session(test_session_id)

    # Add various data types
    entry = GalaxyLedger::Entry.new(
      entry_type: "guideline",
      content: "Ruby guideline",
      importance: "medium",
      source_file: "/home/user/guidelines/ruby.md"
    )
    GalaxyLedger::Database.insert(ledger_id, entry)

    entry = GalaxyLedger::Entry.new(
      entry_type: "decision",
      content: "Use SQLite",
      importance: "high"
    )
    GalaxyLedger::Database.insert(ledger_id, entry)

    entry = GalaxyLedger::Entry.new(
      entry_type: "learning",
      content: "SQLite WAL mode is fast",
      importance: "medium"
    )
    GalaxyLedger::Database.insert(ledger_id, entry)

    GalaxyLedger::Database.upsert_session_file(ledger_id, "/home/user/app.cr", :read)

    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("1 guidelines")
    ctx.should contain("1 decisions")
    ctx.should contain("1 learnings")
    ctx.should contain("1 session files tracked")
  end
end

describe "OnResume resolves to original session via env var" do
  it "resolves existing session and registers new hook session_id" do
    # Setup: create original session with env var
    original_hook_id = "resume-resolve-orig-#{Random.rand(10000)}"
    env_id = "resume-resolve-env-#{Random.rand(10000)}"
    original_ledger_id = GalaxyLedger::Database.create_session(original_hook_id)
    GalaxyLedger::Database.register_session_identifier(original_ledger_id, env_id)

    # Add data to verify we resolve to the right session
    entry = GalaxyLedger::Entry.new(
      entry_type: "learning",
      content: "This is the original session data",
      importance: "medium"
    )
    GalaxyLedger::Database.insert(original_ledger_id, entry)

    # Resume: new hook session_id, same env var
    new_hook_id = "resume-resolve-new-#{Random.rand(10000)}"
    hook_input = {"session_id" => new_hook_id}.to_json

    result = run_binary(
      ["on-resume"],
      stdin: hook_input,
      extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
    )
    result[:status].should eq(0)

    # New hook_id should map to the original session
    GalaxyLedger::Database.resolve_session_identifier(new_hook_id).should eq(original_ledger_id)

    # Context should mention the data
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("1 learnings")
  end
end

describe "OnResume with stale PID collision" do
  it "resolves via env var, ignoring stale PID" do
    # Session A: correct session, with env var
    session_a_id = "resume-stale-a-#{Random.rand(10000)}"
    env_id = "resume-stale-env-#{Random.rand(10000)}"
    ledger_a = GalaxyLedger::Database.create_session(session_a_id)
    GalaxyLedger::Database.register_session_identifier(ledger_a, env_id)

    entry = GalaxyLedger::Entry.new(
      entry_type: "learning",
      content: "Session A data",
      importance: "medium"
    )
    GalaxyLedger::Database.insert(ledger_a, entry)

    # Session B: stale session with a different PID
    # (We can't control the subprocess PID, but the env var resolution
    # should still work correctly regardless of PID state)

    new_hook_id = "resume-stale-new-#{Random.rand(10000)}"
    hook_input = {"session_id" => new_hook_id}.to_json

    result = run_binary(
      ["on-resume"],
      stdin: hook_input,
      extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
    )
    result[:status].should eq(0)

    # Should resolve to session A via env var
    GalaxyLedger::Database.resolve_session_identifier(new_hook_id).should eq(ledger_a)
  end
end

describe "OnResume creates new session when nothing resolves" do
  it "creates a new session with create_if_missing" do
    new_hook_id = "resume-create-#{Random.rand(10000)}"
    hook_input = {"session_id" => new_hook_id}.to_json

    result = run_binary(["on-resume"], stdin: hook_input)
    result[:status].should eq(0)

    # Should have created a new session
    ledger_id = GalaxyLedger::Database.resolve_session_identifier(new_hook_id)
    ledger_id.should_not be_nil

    # Output should still be valid JSON
    output = JSON.parse(result[:output])
    output["systemMessage"].as_s.should contain("Resumed")
  end
end

describe "OnResume edge cases" do
  it "handles empty stdin gracefully" do
    result = run_binary(["on-resume"], stdin: "")
    result[:status].should eq(0)
    # With empty stdin, no session_id is parsed, so Resolver may create
    # or fail — either way, should output valid JSON
    output = JSON.parse(result[:output])
    output["hookSpecificOutput"].should_not be_nil
  end

  it "handles malformed JSON stdin gracefully" do
    result = run_binary(["on-resume"], stdin: "not valid json")
    result[:status].should eq(0)
    output = JSON.parse(result[:output])
    output["hookSpecificOutput"].should_not be_nil
  end
end
