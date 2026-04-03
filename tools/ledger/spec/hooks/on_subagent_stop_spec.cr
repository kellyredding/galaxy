require "../spec_helper"

describe "OnSubagentStop GALAXY_SKIP_HOOKS" do
  it "returns early when GALAXY_SKIP_HOOKS=1 is set" do
    ENV["GALAXY_SKIP_HOOKS"] = "1"

    hook_input = {
      "session_id"             => "skip-stop-#{Random.rand(10000)}",
      "agent_id"               => "a1234567890abcdef",
      "agent_type"             => "Explore",
      "agent_transcript_path"  => "/tmp/agent.jsonl",
      "last_assistant_message" => "Done",
    }.to_json

    result = run_binary(
      ["on-subagent-stop"], stdin: hook_input)
    result[:status].should eq(0)
    result[:output].strip.should eq("")
  ensure
    ENV.delete("GALAXY_SKIP_HOOKS")
  end
end

describe GalaxyLedger::Hooks::OnSubagentStop do
  describe "#run" do
    it "creates instance successfully" do
      handler = GalaxyLedger::Hooks::OnSubagentStop.new
      handler.should be_a(
        GalaxyLedger::Hooks::OnSubagentStop,
      )
    end
  end

  describe "AGENTS_BIN" do
    it "references the AGENTS_BIN constant" do
      GalaxyLedger::Hooks::OnSubagentStop::AGENTS_BIN
        .should eq(GalaxyLedger::AGENTS_BIN.to_s)
    end
  end
end

describe "OnSubagentStop skill filtering" do
  it "skips when agent_type is empty string" do
    test_session_id =
      "stop-skill-empty-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(
      test_session_id,
      claude_pid: Process.pid.to_i64,
    )

    hook_input = {
      "session_id"             => test_session_id,
      "agent_id"               => "a1234567890abcdef",
      "agent_type"             => "",
      "agent_transcript_path"  => "/tmp/agent.jsonl",
      "last_assistant_message" => "Done",
    }.to_json

    result = run_binary(
      ["on-subagent-stop"], stdin: hook_input)
    result[:status].should eq(0)
    result[:output].strip.should eq("")
  end

  it "skips when agent_type is missing" do
    test_session_id =
      "stop-skill-nil-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(
      test_session_id,
      claude_pid: Process.pid.to_i64,
    )

    hook_input = {
      "session_id"             => test_session_id,
      "agent_id"               => "a1234567890abcdef",
      "agent_transcript_path"  => "/tmp/agent.jsonl",
      "last_assistant_message" => "Done",
    }.to_json

    result = run_binary(
      ["on-subagent-stop"], stdin: hook_input)
    result[:status].should eq(0)
    result[:output].strip.should eq("")
  end
end

describe "OnSubagentStop agent_id filtering" do
  it "skips when agent_id is missing" do
    test_session_id =
      "stop-no-aid-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(
      test_session_id,
      claude_pid: Process.pid.to_i64,
    )

    hook_input = {
      "session_id"             => test_session_id,
      "agent_type"             => "Explore",
      "agent_transcript_path"  => "/tmp/agent.jsonl",
      "last_assistant_message" => "Done",
    }.to_json

    result = run_binary(
      ["on-subagent-stop"], stdin: hook_input)
    result[:status].should eq(0)
    result[:output].strip.should eq("")
  end
end

describe "OnSubagentStop session resolution" do
  it "resolves session by stdin session_id" do
    test_session_id =
      "stop-resolve-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(
      test_session_id,
      claude_pid: Process.pid.to_i64,
    )
    flush_wal

    hook_input = {
      "session_id"             => test_session_id,
      "agent_id"               => "a1234567890abcdef",
      "agent_type"             => "Explore",
      "agent_transcript_path"  => "/tmp/agent.jsonl",
      "last_assistant_message" => "Done",
    }.to_json

    result = run_binary(
      ["on-subagent-stop"], stdin: hook_input)
    result[:status].should eq(0)
  end

  it "resolves session by env var" do
    test_session_id =
      "stop-env-#{Random.rand(10000)}"
    env_id =
      "stop-env-durable-#{Random.rand(10000)}"
    ledger_id = GalaxyLedger::Database.create_session(
      test_session_id,
    )
    GalaxyLedger::Database
      .register_session_identifier(ledger_id, env_id)
    flush_wal

    hook_input = {
      "session_id"             => "stop-env-new-#{Random.rand(10000)}",
      "agent_id"               => "a1234567890abcdef",
      "agent_type"             => "Explore",
      "agent_transcript_path"  => "/tmp/agent.jsonl",
      "last_assistant_message" => "Done",
    }.to_json

    result = run_binary(
      ["on-subagent-stop"],
      stdin: hook_input,
      extra_env: {"CLAUDE_CLI_SESSION_ID" => env_id},
    )
    result[:status].should eq(0)
  end

  it "exits cleanly when session cannot be resolved" do
    hook_input = {
      "session_id"             => "nonexistent-#{Random.rand(10000)}",
      "agent_id"               => "a1234567890abcdef",
      "agent_type"             => "Explore",
      "agent_transcript_path"  => "/tmp/agent.jsonl",
      "last_assistant_message" => "Done",
    }.to_json

    result = run_binary(
      ["on-subagent-stop"], stdin: hook_input)
    result[:status].should eq(0)
    result[:output].strip.should eq("")
  end
end

describe "OnSubagentStop dispatch" do
  it "dispatches to galaxy-agents stop (fire-and-forget)" do
    test_session_id =
      "stop-dispatch-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(
      test_session_id,
      claude_pid: Process.pid.to_i64,
    )
    flush_wal

    hook_input = {
      "session_id"             => test_session_id,
      "agent_id"               => "a1234567890abcdef",
      "agent_type"             => "Explore",
      "agent_transcript_path"  => "/tmp/agent.jsonl",
      "last_assistant_message" => "The search found 20 results across the codebase.",
    }.to_json

    result = run_binary(
      ["on-subagent-stop"], stdin: hook_input)
    # Should succeed — the no-op binary exits 0
    result[:status].should eq(0)
  end

  it "dispatches without last_message when absent" do
    test_session_id =
      "stop-no-msg-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(
      test_session_id,
      claude_pid: Process.pid.to_i64,
    )
    flush_wal

    hook_input = {
      "session_id"            => test_session_id,
      "agent_id"              => "a1234567890abcdef",
      "agent_type"            => "Explore",
      "agent_transcript_path" => "/tmp/agent.jsonl",
    }.to_json

    result = run_binary(
      ["on-subagent-stop"], stdin: hook_input)
    result[:status].should eq(0)
  end

  it "dispatches without transcript path when absent" do
    test_session_id =
      "stop-no-tp-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(
      test_session_id,
      claude_pid: Process.pid.to_i64,
    )
    flush_wal

    hook_input = {
      "session_id"             => test_session_id,
      "agent_id"               => "a1234567890abcdef",
      "agent_type"             => "Explore",
      "last_assistant_message" => "Done",
    }.to_json

    result = run_binary(
      ["on-subagent-stop"], stdin: hook_input)
    result[:status].should eq(0)
  end

  it "succeeds even when galaxy-agents binary is unavailable" do
    test_session_id =
      "stop-no-bin-#{Random.rand(10000)}"
    GalaxyLedger::Database.create_session(
      test_session_id,
      claude_pid: Process.pid.to_i64,
    )
    flush_wal

    hook_input = {
      "session_id"             => test_session_id,
      "agent_id"               => "a1234567890abcdef",
      "agent_type"             => "Explore",
      "agent_transcript_path"  => "/tmp/agent.jsonl",
      "last_assistant_message" => "Done",
    }.to_json

    result = run_binary(
      ["on-subagent-stop"],
      stdin: hook_input,
      extra_env: {
        "GALAXY_AGENTS_BIN" => "/nonexistent/galaxy-agents",
      },
    )
    # Best-effort: should not crash
    result[:status].should eq(0)
  end
end

describe "OnSubagentStop graceful input handling" do
  it "handles empty stdin gracefully" do
    result = run_binary(
      ["on-subagent-stop"], stdin: "")
    result[:status].should eq(0)
  end

  it "handles malformed JSON stdin gracefully" do
    result = run_binary(
      ["on-subagent-stop"],
      stdin: "not valid json {{{",
    )
    result[:status].should eq(0)
  end
end

describe "OnSubagentStop help" do
  it "shows help with --help flag" do
    result = run_binary(
      ["on-subagent-stop", "--help"],
    )
    result[:status].should eq(0)
    result[:output].should contain("SubagentStop")
    result[:output].should contain("agent_id")
  end

  it "shows help with -h flag" do
    result = run_binary(
      ["on-subagent-stop", "-h"],
    )
    result[:status].should eq(0)
    result[:output].should contain("SubagentStop")
  end
end
