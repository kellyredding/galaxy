require "../spec_helper"

describe "OnStopFailure GALAXY_SKIP_HOOKS" do
  it "returns early when GALAXY_SKIP_HOOKS=1 is set" do
    ENV["GALAXY_SKIP_HOOKS"] = "1"

    session_id = "skip-hooks-test-#{Random.rand(100000)}"

    input = {
      "session_id"             => session_id,
      "transcript_path"        => "/tmp/fake.jsonl",
      "hook_event_name"        => "StopFailure",
      "last_assistant_message" => "Error occurred",
    }.to_json

    result = run_binary(
      ["on-stop-failure"],
      stdin: input,
    )
    result[:status].should eq(0)
  ensure
    ENV.delete("GALAXY_SKIP_HOOKS")
  end
end

describe GalaxyLedger::Hooks::OnStopFailure do
  describe "#run" do
    it "creates instance successfully" do
      handler = GalaxyLedger::Hooks::OnStopFailure.new
      handler.should be_a(
        GalaxyLedger::Hooks::OnStopFailure,
      )
    end
  end
end

describe "OnStopFailure turn state consumption" do
  test_session_id = "stop-failure-test-#{Random.rand(100000)}"

  before_each do
    GalaxyLedger::Database.delete_session(
      test_session_id,
    )
    GalaxyLedger::Hooks::TurnState.delete(
      test_session_id,
    )
  end

  after_each do
    GalaxyLedger::Database.delete_session(
      test_session_id,
    )
    GalaxyLedger::Hooks::TurnState.delete(
      test_session_id,
    )
  end

  it "deletes turn state file when it exists" do
    # Create session and state file
    ledger_id = GalaxyLedger::Database.create_session(
      test_session_id,
    )
    flush_wal

    GalaxyLedger::Hooks::TurnState.write(
      test_session_id,
      "fail-uuid-123",
      "This will fail",
    )

    GalaxyLedger::Hooks::TurnState.exists?(
      test_session_id,
    ).should be_true

    input = {
      "session_id"             => test_session_id,
      "transcript_path"        => "/tmp/fake.jsonl",
      "hook_event_name"        => "StopFailure",
      "last_assistant_message" => "API error",
    }.to_json

    result = run_binary(
      ["on-stop-failure"],
      stdin: input,
    )
    result[:status].should eq(0)

    # State file should be consumed (deleted)
    GalaxyLedger::Hooks::TurnState.exists?(
      test_session_id,
    ).should be_false
  end

  it "runs cleanly when no state file exists" do
    ledger_id = GalaxyLedger::Database.create_session(
      test_session_id,
    )
    flush_wal

    input = {
      "session_id"             => test_session_id,
      "transcript_path"        => "/tmp/fake.jsonl",
      "hook_event_name"        => "StopFailure",
      "last_assistant_message" => "Error",
    }.to_json

    result = run_binary(
      ["on-stop-failure"],
      stdin: input,
    )
    result[:status].should eq(0)
  end

  it "handles empty input gracefully" do
    result = run_binary(
      ["on-stop-failure"],
      stdin: "",
    )
    result[:status].should eq(0)
  end

  it "handles invalid JSON gracefully" do
    result = run_binary(
      ["on-stop-failure"],
      stdin: "not json",
    )
    result[:status].should eq(0)
  end

  describe "CLI help" do
    it "shows help with -h flag" do
      result = run_binary(["on-stop-failure", "-h"])
      result[:status].should eq(0)

      result[:output].should contain("on-stop-failure")
      result[:output].should contain("StopFailure")
      result[:output].should contain("turn:failed")
    end

    it "shows help with --help flag" do
      result = run_binary(["on-stop-failure", "--help"])
      result[:status].should eq(0)
      result[:output].should contain("on-stop-failure")
    end
  end
end
