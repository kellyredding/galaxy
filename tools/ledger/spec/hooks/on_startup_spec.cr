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

    # Clean up
    GalaxyLedger::Database.delete_session(test_session_id)
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

    # Clean up
    GalaxyLedger::Database.delete_session(test_session_id)
  end

  it "shows counts when session already has data" do
    test_session_id = "startup-sm-data-#{Random.rand(10000)}"
    GalaxyLedger::Database.upsert_session(test_session_id)

    # Add some pre-existing guideline entries
    2.times do |i|
      entry = GalaxyLedger::Entry.new(
        entry_type: "guideline",
        content: "Pre-existing guideline #{i + 1}",
        importance: "medium",
        source_file: "/home/user/guidelines/style.md"
      )
      GalaxyLedger::Database.insert(test_session_id, entry)
    end

    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-startup"], stdin: hook_input)
    output = JSON.parse(result[:output])
    msg = output["systemMessage"].as_s
    msg.should contain("Ledger active")
    msg.should contain("2 guidelines")

    # Clean up
    GalaxyLedger::Database.delete_session(test_session_id)
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

    # Clean up
    GalaxyLedger::Database.delete_session(test_session_id)
  end

  it "includes session ID" do
    test_session_id = "startup-ctx-sid-#{Random.rand(10000)}"
    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-startup"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain(test_session_id)

    # Clean up
    GalaxyLedger::Database.delete_session(test_session_id)
  end

  it "includes Ledger PID" do
    test_session_id = "startup-ctx-pid-#{Random.rand(10000)}"
    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-startup"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("**Ledger PID**:")

    # Clean up
    GalaxyLedger::Database.delete_session(test_session_id)
  end

  it "uses --pid in command examples" do
    test_session_id = "startup-ctx-pidcmd-#{Random.rand(10000)}"
    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-startup"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("--pid")
    ctx.should_not contain("--session")

    # Clean up
    GalaxyLedger::Database.delete_session(test_session_id)
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

    # Clean up
    GalaxyLedger::Database.delete_session(test_session_id)
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

    # Clean up
    GalaxyLedger::Database.delete_session(test_session_id)
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

    # Clean up
    GalaxyLedger::Database.delete_session(test_session_id)
  end

  it "stores PID on session record" do
    test_session_id = "startup-pid-store-#{Random.rand(10000)}"
    hook_input = {"session_id" => test_session_id}.to_json

    result = run_binary(["on-startup"], stdin: hook_input)
    result[:status].should eq(0)

    session = GalaxyLedger::Database.get_session(test_session_id)
    session.should_not be_nil
    # The binary runs as a subprocess, so its Process.ppid is the spec runner's PID.
    # We just verify that claude_pid was stored (not nil).
    session.not_nil!.claude_pid.should_not be_nil

    # Clean up
    GalaxyLedger::Database.delete_session(test_session_id)
  end
end
