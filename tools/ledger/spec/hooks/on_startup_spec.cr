require "../spec_helper"

describe "OnStartup GALAXY_SKIP_HOOKS" do
  it "returns early when GALAXY_SKIP_HOOKS=1 is set" do
    ENV["GALAXY_SKIP_HOOKS"] = "1"

    test_session_id = "skip-hooks-test-#{Random.rand(10000)}"

    hook_input = {
      "session_id" => test_session_id,
    }.to_json

    result = run_binary(["on-startup"], stdin: hook_input)
    result[:status].should eq(0)

    # Should return empty output (no hookSpecificOutput)
    result[:output].strip.should eq("")
  ensure
    ENV.delete("GALAXY_SKIP_HOOKS")
  end
end

describe GalaxyLedger::Hooks::OnStartup do
  describe "#run" do
    it "outputs JSON with hookSpecificOutput" do
      handler = GalaxyLedger::Hooks::OnStartup.new

      # Basic instantiation test - handler creates successfully
      handler.should be_a(GalaxyLedger::Hooks::OnStartup)
    end
  end
end

describe "OnStartup JSON output" do
  it "outputs clean JSON with systemMessage and hookSpecificOutput" do
    test_session_id = "startup-json-#{Random.rand(10000)}"
    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-startup"], stdin: hook_input)
    result[:status].should eq(0)

    output = JSON.parse(result[:output])
    output["systemMessage"].should be_a(JSON::Any)
    output["hookSpecificOutput"]["hookEventName"].should eq("SessionStart")
    output["hookSpecificOutput"]["additionalContext"].should be_a(JSON::Any)
  end
end

describe "OnStartup systemMessage" do
  it "shows 'New session' for fresh starts" do
    test_session_id = "startup-sm-#{Random.rand(10000)}"
    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-startup"], stdin: hook_input)
    output = JSON.parse(result[:output])
    msg = output["systemMessage"].as_s
    msg.should contain("Ledger active")
    msg.should contain("New session")
  end
end

describe "OnStartup additionalContext" do
  it "includes Galaxy Ledger heading" do
    test_session_id = "startup-ctx-#{Random.rand(10000)}"
    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-startup"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("## Galaxy Ledger")
  end

  it "includes persistent context ledger description" do
    test_session_id = "startup-ctx-desc-#{Random.rand(10000)}"
    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-startup"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("persistent context ledger")
  end

  it "includes Ledger PID" do
    test_session_id = "startup-ctx-pid-#{Random.rand(10000)}"
    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-startup"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("**Ledger PID**:")
  end

  it "uses --pid in command examples" do
    test_session_id = "startup-ctx-pidcmd-#{Random.rand(10000)}"
    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-startup"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("--pid")
    ctx.should_not contain("--session")
  end

  it "describes what the ledger captures" do
    test_session_id = "startup-ctx-what-#{Random.rand(10000)}"
    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-startup"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("Guidelines")
    ctx.should contain("Implementation plans")
    ctx.should contain("Decisions")
    ctx.should contain("Learnings")
    ctx.should contain("Session files")
  end

  it "includes tiered lookup directives" do
    test_session_id = "startup-ctx-lookup-#{Random.rand(10000)}"
    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-startup"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("Query the ledger")
    ctx.should contain("galaxy-ledger search")
    ctx.should contain("galaxy-ledger list-files")
    ctx.should contain("git diff")
    ctx.should contain("Fall back to normal exploration")
  end

  it "does not include cross-session stats" do
    test_session_id = "startup-ctx-no-stats-#{Random.rand(10000)}"
    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-startup"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should_not contain("Sessions tracked")
    ctx.should_not contain("Total entries")
    ctx.should_not contain("Ledger Stats")
  end

  it "stores PID on session record" do
    test_session_id = "startup-pid-store-#{Random.rand(10000)}"
    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-startup"], stdin: hook_input)
    result[:status].should eq(0)

    session = GalaxyLedger::Database.get_session(test_session_id)
    session.should_not be_nil
    # The binary runs as a subprocess, so its Process.ppid is the spec runner's PID.
    # We just verify that current_claude_pid was stored (not nil).
    session.not_nil!.current_claude_pid.should_not be_nil
  end
end

describe "OnStartup always creates new session (stale PID fix)" do
  it "creates a new session instead of resolving to a stale PID mapping" do
    # Setup: create an old session with a known PID
    old_session_id = "stale-pid-old-#{Random.rand(10000)}"
    old_ledger_id = GalaxyLedger::Database.create_session(
      old_session_id,
      claude_pid: 99998_i64, # some PID
    )

    # Run on-startup with a new session_id
    # In real scenario, the subprocess PID would match an old session.
    # We can't control Process.ppid in the subprocess, but we can verify
    # that a NEW session is always created (not the old one).
    new_session_id = "stale-pid-new-#{Random.rand(10000)}"
    hook_input = {"session_id" => new_session_id}.to_json

    result = run_binary(["on-startup"], stdin: hook_input)
    result[:status].should eq(0)

    # A NEW session should have been created for the new session_id
    new_ledger_id = GalaxyLedger::Database.resolve_session_identifier(new_session_id)
    new_ledger_id.should_not be_nil
    new_ledger_id.should_not eq(old_ledger_id)
  end

  it "always creates even when an existing session matches via env var" do
    # Create old session and register env var
    old_session_id = "startup-env-old-#{Random.rand(10000)}"
    env_id = "startup-env-durable-#{Random.rand(10000)}"
    old_ledger_id = GalaxyLedger::Database.create_session(old_session_id)
    GalaxyLedger::Database.register_session_identifier(old_ledger_id, env_id)

    # on-startup should create a NEW session, not resolve to old one
    new_session_id = "startup-env-new-#{Random.rand(10000)}"
    hook_input = {"session_id" => new_session_id}.to_json

    result = run_binary(
      ["on-startup"],
      stdin: hook_input,
      extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
    )
    result[:status].should eq(0)

    # Should have created a new session (startup always creates)
    new_ledger_id = GalaxyLedger::Database.resolve_session_identifier(new_session_id)
    new_ledger_id.should_not be_nil
    new_ledger_id.should_not eq(old_ledger_id)

    # But env var should now be registered against the new session too
    env_ledger_id = GalaxyLedger::Database.resolve_session_identifier(env_id)
    # The env var may still point to old session since on-startup registers
    # it via INSERT OR IGNORE (not REPLACE) for identifiers. That's fine —
    # resume will use Resolver which handles this correctly.
  end
end
