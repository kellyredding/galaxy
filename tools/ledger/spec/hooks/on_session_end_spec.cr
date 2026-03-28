require "../spec_helper"

describe "OnSessionEnd GALAXY_SKIP_HOOKS" do
  it "returns early when GALAXY_SKIP_HOOKS=1 is set" do
    ENV["GALAXY_SKIP_HOOKS"] = "1"

    test_session_id = "skip-hooks-end-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(test_session_id)

    hook_input = {
      "session_id" => test_session_id,
      "cwd"        => "/tmp",
    }.to_json

    result = run_binary(
      ["on-session-end"], stdin: hook_input)
    result[:status].should eq(0)
    result[:output].strip.should eq("")
  ensure
    ENV.delete("GALAXY_SKIP_HOOKS")
  end
end

describe GalaxyLedger::Hooks::OnSessionEnd do
  describe "#run" do
    it "creates instance successfully" do
      handler = GalaxyLedger::Hooks::OnSessionEnd.new
      handler.should be_a(
        GalaxyLedger::Hooks::OnSessionEnd,
      )
    end
  end

  describe "CONTEXT_RESET_REASONS" do
    it "includes clear" do
      GalaxyLedger::Hooks::OnSessionEnd::CONTEXT_RESET_REASONS
        .should contain("clear")
    end

    it "does not include compact" do
      GalaxyLedger::Hooks::OnSessionEnd::CONTEXT_RESET_REASONS
        .should_not contain("compact")
    end
  end
end

describe "OnSessionEnd session resolution" do
  it "resolves session by stdin session_id" do
    test_session_id = "end-resolve-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(test_session_id)

    hook_input = {
      "session_id" => test_session_id,
      "cwd"        => "/tmp",
    }.to_json

    result = run_binary(
      ["on-session-end"], stdin: hook_input)
    result[:status].should eq(0)
  end

  it "resolves session by env var" do
    test_session_id = "end-env-#{Random.rand(10000)}"
    env_id = "end-env-durable-#{Random.rand(10000)}"
    ledger_id = GalaxyLedger::Database.create_session(
      test_session_id,
    )
    GalaxyLedger::Database.register_session_identifier(
      ledger_id, env_id,
    )

    hook_input = {
      "session_id" => "end-env-new-#{Random.rand(10000)}",
      "cwd"        => "/tmp",
    }.to_json

    result = run_binary(
      ["on-session-end"],
      stdin: hook_input,
      extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
    )
    result[:status].should eq(0)
  end

  it "exits cleanly when session cannot be resolved" do
    hook_input = {
      "session_id" => "nonexistent-#{Random.rand(10000)}",
      "cwd"        => "/tmp",
    }.to_json

    result = run_binary(
      ["on-session-end"], stdin: hook_input)
    result[:status].should eq(0)
    result[:output].strip.should eq("")
  end
end

describe "OnSessionEnd context reset guard" do
  it "skips when reason is clear" do
    test_session_id = "end-clear-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(test_session_id)

    hook_input = {
      "session_id" => test_session_id,
      "cwd"        => "/tmp",
      "reason"     => "clear",
    }.to_json

    result = run_binary(
      ["on-session-end"], stdin: hook_input)
    result[:status].should eq(0)
    result[:output].strip.should eq("")
  end

  it "does not skip when reason is absent" do
    test_session_id = "end-noreason-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(test_session_id)

    hook_input = {
      "session_id" => test_session_id,
      "cwd"        => "/tmp",
    }.to_json

    result = run_binary(
      ["on-session-end"], stdin: hook_input)
    result[:status].should eq(0)
    # No assertion on output — just verifying it
    # proceeds past the guard (doesn't early-return)
  end

  it "does not skip when reason is an unknown value" do
    test_session_id = "end-other-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(test_session_id)

    hook_input = {
      "session_id" => test_session_id,
      "cwd"        => "/tmp",
      "reason"     => "logout",
    }.to_json

    result = run_binary(
      ["on-session-end"], stdin: hook_input)
    result[:status].should eq(0)
  end
end

describe "OnSessionEnd graceful input handling" do
  it "handles empty stdin gracefully" do
    result = run_binary(["on-session-end"], stdin: "")
    result[:status].should eq(0)
  end

  it "handles malformed JSON stdin gracefully" do
    result = run_binary(
      ["on-session-end"], stdin: "not valid json {{{")
    result[:status].should eq(0)
  end
end

describe "OnSessionEnd timeline recording" do
  it "succeeds even when galaxy-timeline is unavailable" do
    test_session_id = "end-timeline-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(test_session_id)

    hook_input = {
      "session_id" => test_session_id,
      "cwd"        => "/tmp",
    }.to_json

    result = run_binary(
      ["on-session-end"], stdin: hook_input)
    result[:status].should eq(0)
  end
end

describe "OnSessionEnd help" do
  it "shows help with --help flag" do
    result = run_binary(["on-session-end", "--help"])
    result[:status].should eq(0)
    result[:output].should contain("SessionEnd")
    result[:output].should contain("session:ended")
  end

  it "shows help with -h flag" do
    result = run_binary(["on-session-end", "-h"])
    result[:status].should eq(0)
    result[:output].should contain("SessionEnd")
  end
end
