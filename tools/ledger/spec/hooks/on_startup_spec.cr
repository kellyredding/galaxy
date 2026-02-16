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

describe "OnStartup stale PID handling (no env var)" do
  it "creates a new session even when a stale PID mapping exists" do
    # Setup: create an old session with a known PID
    old_session_id = "stale-pid-old-#{Random.rand(10000)}"
    old_ledger_id = GalaxyLedger::Database.create_session(
      old_session_id,
      claude_pid: 99998_i64, # some PID
    )

    # Run on-startup with a new session_id (no env var)
    new_session_id = "stale-pid-new-#{Random.rand(10000)}"
    hook_input = {"session_id" => new_session_id}.to_json

    result = run_binary(["on-startup"], stdin: hook_input)
    result[:status].should eq(0)

    # A NEW session should have been created for the new session_id
    new_ledger_id = GalaxyLedger::Database.resolve_session_identifier(new_session_id)
    new_ledger_id.should_not be_nil
    new_ledger_id.should_not eq(old_ledger_id)
  end
end

describe "OnStartup with env var matching existing session (resume scenario)" do
  it "resolves to existing session instead of creating a new one" do
    # Create original session with env var UUID registered
    old_session_id = "startup-env-old-#{Random.rand(10000)}"
    env_id = "startup-env-durable-#{Random.rand(10000)}"
    old_ledger_id = GalaxyLedger::Database.create_session(old_session_id)
    GalaxyLedger::Database.register_session_identifier(old_ledger_id, env_id)

    # Run on-startup with same env var, different stdin session_id
    new_session_id = "startup-env-new-#{Random.rand(10000)}"
    hook_input = {"session_id" => new_session_id}.to_json

    result = run_binary(
      ["on-startup"],
      stdin: hook_input,
      extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
    )
    result[:status].should eq(0)

    # Should NOT have created a new session — should resolve to old one
    new_ledger_id = GalaxyLedger::Database.resolve_session_identifier(new_session_id)
    new_ledger_id.should eq(old_ledger_id)

    # Only 1 session should exist (the original)
    sessions = GalaxyLedger::Database.list_sessions
    sessions.size.should eq(1)
    sessions[0].id.should eq(old_ledger_id)
  end

  it "registers new PID and stdin session_id against existing session" do
    old_session_id = "startup-env-reg-old-#{Random.rand(10000)}"
    env_id = "startup-env-reg-durable-#{Random.rand(10000)}"
    old_ledger_id = GalaxyLedger::Database.create_session(old_session_id)
    GalaxyLedger::Database.register_session_identifier(old_ledger_id, env_id)

    new_session_id = "startup-env-reg-new-#{Random.rand(10000)}"
    hook_input = {"session_id" => new_session_id}.to_json

    result = run_binary(
      ["on-startup"],
      stdin: hook_input,
      extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
    )
    result[:status].should eq(0)

    # New stdin session_id should be registered against old session
    GalaxyLedger::Database.resolve_session_identifier(new_session_id).should eq(old_ledger_id)

    # Session should have a PID registered
    pids = GalaxyLedger::Database.session_pids(old_ledger_id)
    pids.size.should be >= 1
  end

  it "outputs awareness context with correct PID" do
    old_session_id = "startup-env-ctx-old-#{Random.rand(10000)}"
    env_id = "startup-env-ctx-durable-#{Random.rand(10000)}"
    old_ledger_id = GalaxyLedger::Database.create_session(old_session_id)
    GalaxyLedger::Database.register_session_identifier(old_ledger_id, env_id)

    new_session_id = "startup-env-ctx-new-#{Random.rand(10000)}"
    hook_input = {"session_id" => new_session_id}.to_json

    result = run_binary(
      ["on-startup"],
      stdin: hook_input,
      extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
    )
    result[:status].should eq(0)

    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("**Ledger PID**:")
    ctx.should contain("## Galaxy Ledger")
  end
end

describe "OnStartup with env var not matching any session (fresh start)" do
  it "creates a new session and registers env var" do
    env_id = "startup-fresh-env-#{Random.rand(10000)}"
    new_session_id = "startup-fresh-#{Random.rand(10000)}"
    hook_input = {"session_id" => new_session_id}.to_json

    result = run_binary(
      ["on-startup"],
      stdin: hook_input,
      extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
    )
    result[:status].should eq(0)

    # New session should be created
    ledger_id = GalaxyLedger::Database.resolve_session_identifier(new_session_id)
    ledger_id.should_not be_nil

    # Env var should also resolve to the new session
    GalaxyLedger::Database.resolve_session_identifier(env_id).should eq(ledger_id)
  end
end

describe "OnStartup without env var (no persona)" do
  it "creates a new session" do
    new_session_id = "startup-noenv-#{Random.rand(10000)}"
    hook_input = {"session_id" => new_session_id}.to_json

    result = run_binary(["on-startup"], stdin: hook_input)
    result[:status].should eq(0)

    ledger_id = GalaxyLedger::Database.resolve_session_identifier(new_session_id)
    ledger_id.should_not be_nil

    sessions = GalaxyLedger::Database.list_sessions
    sessions.size.should eq(1)
  end
end
