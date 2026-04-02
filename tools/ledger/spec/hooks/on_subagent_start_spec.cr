require "../spec_helper"

describe "OnSubagentStart GALAXY_SKIP_HOOKS" do
  it "returns early when GALAXY_SKIP_HOOKS=1 is set" do
    ENV["GALAXY_SKIP_HOOKS"] = "1"

    hook_input = {
      "session_id"      => "skip-test-#{Random.rand(10000)}",
      "agent_id"        => "a1234567890abcdef",
      "agent_type"      => "Explore",
      "transcript_path" => "/tmp/fake.jsonl",
    }.to_json

    result = run_binary(
      ["on-subagent-start"], stdin: hook_input)
    result[:status].should eq(0)
    result[:output].strip.should eq("")
  ensure
    ENV.delete("GALAXY_SKIP_HOOKS")
  end
end

describe GalaxyLedger::Hooks::OnSubagentStart do
  describe "#run" do
    it "creates instance successfully" do
      handler = GalaxyLedger::Hooks::OnSubagentStart.new
      handler.should be_a(
        GalaxyLedger::Hooks::OnSubagentStart,
      )
    end
  end

  describe "AGENTS_BIN" do
    it "references the AGENTS_BIN_NAME constant" do
      GalaxyLedger::Hooks::OnSubagentStart::AGENTS_BIN
        .should eq(GalaxyLedger::AGENTS_BIN_NAME)
    end
  end
end

describe "OnSubagentStart skill filtering" do
  it "skips when agent_type is empty string" do
    test_session_id =
      "start-skill-empty-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(
      test_session_id,
      claude_pid: Process.pid.to_i64,
    )

    hook_input = {
      "session_id"      => test_session_id,
      "agent_id"        => "a1234567890abcdef",
      "agent_type"      => "",
      "transcript_path" => "/tmp/fake.jsonl",
    }.to_json

    result = run_binary(
      ["on-subagent-start"], stdin: hook_input)
    result[:status].should eq(0)
    result[:output].strip.should eq("")
  end

  it "skips when agent_type is missing" do
    test_session_id =
      "start-skill-nil-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(
      test_session_id,
      claude_pid: Process.pid.to_i64,
    )

    hook_input = {
      "session_id"      => test_session_id,
      "agent_id"        => "a1234567890abcdef",
      "transcript_path" => "/tmp/fake.jsonl",
    }.to_json

    result = run_binary(
      ["on-subagent-start"], stdin: hook_input)
    result[:status].should eq(0)
    result[:output].strip.should eq("")
  end
end

describe "OnSubagentStart agent_id filtering" do
  it "skips when agent_id is missing" do
    test_session_id =
      "start-no-aid-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(
      test_session_id,
      claude_pid: Process.pid.to_i64,
    )

    hook_input = {
      "session_id"      => test_session_id,
      "agent_type"      => "Explore",
      "transcript_path" => "/tmp/fake.jsonl",
    }.to_json

    result = run_binary(
      ["on-subagent-start"], stdin: hook_input)
    result[:status].should eq(0)
    result[:output].strip.should eq("")
  end
end

describe "OnSubagentStart session resolution" do
  it "resolves session by stdin session_id" do
    test_session_id =
      "start-resolve-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(
      test_session_id,
      claude_pid: Process.pid.to_i64,
    )
    flush_wal

    hook_input = {
      "session_id"      => test_session_id,
      "agent_id"        => "a1234567890abcdef",
      "agent_type"      => "Explore",
      "transcript_path" => "/tmp/fake.jsonl",
    }.to_json

    result = run_binary(
      ["on-subagent-start"], stdin: hook_input)
    result[:status].should eq(0)
  end

  it "resolves session by env var" do
    test_session_id =
      "start-env-#{Random.rand(10000)}"
    env_id =
      "start-env-durable-#{Random.rand(10000)}"
    ledger_id = GalaxyLedger::Database.create_session(
      test_session_id,
    )
    GalaxyLedger::Database
      .register_session_identifier(ledger_id, env_id)
    flush_wal

    hook_input = {
      "session_id"      => "start-env-new-#{Random.rand(10000)}",
      "agent_id"        => "a1234567890abcdef",
      "agent_type"      => "Explore",
      "transcript_path" => "/tmp/fake.jsonl",
    }.to_json

    result = run_binary(
      ["on-subagent-start"],
      stdin: hook_input,
      extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
    )
    result[:status].should eq(0)
  end

  it "exits cleanly when session cannot be resolved" do
    hook_input = {
      "session_id"      => "nonexistent-#{Random.rand(10000)}",
      "agent_id"        => "a1234567890abcdef",
      "agent_type"      => "Explore",
      "transcript_path" => "/tmp/fake.jsonl",
    }.to_json

    result = run_binary(
      ["on-subagent-start"], stdin: hook_input)
    result[:status].should eq(0)
    result[:output].strip.should eq("")
  end
end

describe "OnSubagentStart dispatch" do
  it "dispatches to galaxy-agents start (fire-and-forget)" do
    test_session_id =
      "start-dispatch-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(
      test_session_id,
      claude_pid: Process.pid.to_i64,
    )
    flush_wal

    hook_input = {
      "session_id"      => test_session_id,
      "agent_id"        => "a1234567890abcdef",
      "agent_type"      => "Explore",
      "transcript_path" => "/tmp/fake-parent.jsonl",
    }.to_json

    result = run_binary(
      ["on-subagent-start"], stdin: hook_input)
    # Should succeed — the no-op binary exits 0
    result[:status].should eq(0)
  end

  it "succeeds even when galaxy-agents binary is unavailable" do
    test_session_id =
      "start-no-bin-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(
      test_session_id,
      claude_pid: Process.pid.to_i64,
    )
    flush_wal

    hook_input = {
      "session_id"      => test_session_id,
      "agent_id"        => "a1234567890abcdef",
      "agent_type"      => "Explore",
      "transcript_path" => "/tmp/fake.jsonl",
    }.to_json

    result = run_binary(
      ["on-subagent-start"],
      stdin: hook_input,
      extra_env: {
        "GALAXY_AGENTS_BIN" => "/nonexistent/galaxy-agents",
      },
    )
    # Best-effort: should not crash
    result[:status].should eq(0)
  end
end

describe "OnSubagentStart graceful input handling" do
  it "handles empty stdin gracefully" do
    result = run_binary(
      ["on-subagent-start"], stdin: "")
    result[:status].should eq(0)
  end

  it "handles malformed JSON stdin gracefully" do
    result = run_binary(
      ["on-subagent-start"],
      stdin: "not valid json {{{",
    )
    result[:status].should eq(0)
  end
end

describe "OnSubagentStart help" do
  it "shows help with --help flag" do
    result = run_binary(
      ["on-subagent-start", "--help"],
    )
    result[:status].should eq(0)
    result[:output].should contain("SubagentStart")
    result[:output].should contain("agent_id")
  end

  it "shows help with -h flag" do
    result = run_binary(
      ["on-subagent-start", "-h"],
    )
    result[:status].should eq(0)
    result[:output].should contain("SubagentStart")
  end
end
