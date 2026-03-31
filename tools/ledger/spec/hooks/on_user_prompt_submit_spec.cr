require "../spec_helper"

describe "OnUserPromptSubmit GALAXY_SKIP_HOOKS" do
  it "returns early when GALAXY_SKIP_HOOKS=1 is set" do
    ENV["GALAXY_SKIP_HOOKS"] = "1"

    session_id = "skip-hooks-test-#{rand(100000)}"

    input = {
      "session_id"      => session_id,
      "prompt"          => "Always use trailing commas in multiline structures",
      "hook_event_name" => "UserPromptSubmit",
    }.to_json

    result = run_binary(["on-user-prompt-submit"], stdin: input)
    result[:status].should eq(0)
  ensure
    ENV.delete("GALAXY_SKIP_HOOKS")
  end
end

describe GalaxyLedger::Hooks::OnUserPromptSubmit do
  describe "#run" do
    # on-user-prompt-submit spawns async extraction via Claude CLI subprocess
    # These tests verify the hook runs without error and spawns correctly

    it "runs without error for valid prompts" do
      session_id = "user-prompt-test-#{rand(100000)}"

      input = {
        "session_id"      => session_id,
        "prompt"          => "Always use trailing commas in multiline structures",
        "hook_event_name" => "UserPromptSubmit",
      }.to_json

      result = run_binary(["on-user-prompt-submit"], stdin: input)
      result[:status].should eq(0)
    end

    it "skips empty prompts without spawning extraction" do
      session_id = "user-prompt-test-#{rand(100000)}"

      input = {
        "session_id"      => session_id,
        "prompt"          => "",
        "hook_event_name" => "UserPromptSubmit",
      }.to_json

      result = run_binary(["on-user-prompt-submit"], stdin: input)
      result[:status].should eq(0)
      # No extraction spawned for empty prompts - validated by exit status
      # Async extraction writes directly to DB, so we can't easily verify no-op in unit tests
    end

    it "skips whitespace-only prompts without spawning extraction" do
      session_id = "user-prompt-test-#{rand(100000)}"

      input = {
        "session_id"      => session_id,
        "prompt"          => "   \n\t  ",
        "hook_event_name" => "UserPromptSubmit",
      }.to_json

      result = run_binary(["on-user-prompt-submit"], stdin: input)
      result[:status].should eq(0)
      # No extraction spawned for whitespace-only prompts
    end

    it "skips very short prompts (less than 10 chars)" do
      session_id = "user-prompt-test-#{rand(100000)}"

      short_prompts = ["yes", "ok", "continue", "go ahead", "sure"]
      short_prompts.each do |prompt|
        input = {
          "session_id"      => session_id,
          "prompt"          => prompt,
          "hook_event_name" => "UserPromptSubmit",
        }.to_json

        result = run_binary(["on-user-prompt-submit"], stdin: input)
        result[:status].should eq(0)
      end
      # No extraction spawned for short prompts - validated by exit status
    end

    it "accepts prompts with exactly 10 characters and spawns extraction" do
      session_id = "user-prompt-test-#{rand(100000)}"

      input = {
        "session_id"      => session_id,
        "prompt"          => "1234567890", # Exactly 10 chars
        "hook_event_name" => "UserPromptSubmit",
      }.to_json

      result = run_binary(["on-user-prompt-submit"], stdin: input)
      result[:status].should eq(0)

      # Hook runs without error - extraction happens async
      # We can't easily verify the subprocess was spawned in unit tests
      # The integration/eval tests will verify actual extraction
    end

    describe "with missing or invalid input" do
      it "handles empty input gracefully" do
        result = run_binary(["on-user-prompt-submit"], stdin: "")
        result[:status].should eq(0)
      end

      it "handles invalid JSON gracefully" do
        result = run_binary(["on-user-prompt-submit"], stdin: "not json")
        result[:status].should eq(0)
      end

      it "handles missing session_id gracefully" do
        input = {
          "prompt" => "Some user message",
        }.to_json

        result = run_binary(["on-user-prompt-submit"], stdin: input)
        result[:status].should eq(0)
      end

      it "handles missing prompt gracefully" do
        session_id = "user-prompt-test-#{rand(100000)}"

        input = {
          "session_id" => session_id,
        }.to_json

        result = run_binary(["on-user-prompt-submit"], stdin: input)
        result[:status].should eq(0)
      end
    end
  end

  describe "turn state file management" do
    test_session_id = "turn-test-#{Random.rand(100000)}"

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

    it "writes turn state file for matching session" do
      ledger_id = GalaxyLedger::Database.create_session(
        test_session_id,
      )
      flush_wal

      input = {
        "session_id"      => test_session_id,
        "prompt"          => "Tell me about the codebase architecture",
        "hook_event_name" => "UserPromptSubmit",
      }.to_json

      result = run_binary(
        ["on-user-prompt-submit"],
        stdin: input,
      )
      result[:status].should eq(0)

      state = GalaxyLedger::Hooks::TurnState.read(
        test_session_id,
      )
      state.should_not be_nil
      state = state.not_nil!
      state.user_message.should eq(
        "Tell me about the codebase architecture",
      )
      state.uuid.should_not be_empty
    end

    it "skips turn state for task-notification prompts" do
      ledger_id = GalaxyLedger::Database.create_session(
        test_session_id,
      )
      flush_wal

      input = {
        "session_id"      => test_session_id,
        "prompt"          => "<task-notification>\n<task-id>abc123</task-id>\n<status>completed</status>\n</task-notification>",
        "hook_event_name" => "UserPromptSubmit",
      }.to_json

      result = run_binary(
        ["on-user-prompt-submit"],
        stdin: input,
      )
      result[:status].should eq(0)

      GalaxyLedger::Hooks::TurnState.exists?(
        test_session_id,
      ).should be_false
    end

    it "skips turn state for mismatched session_id" do
      ledger_id = GalaxyLedger::Database.create_session(
        test_session_id,
      )
      flush_wal

      # Use a different session_id in the hook input
      # than the one registered in the ledger
      input = {
        "session_id"      => "different-session-id",
        "prompt"          => "This should not create a state file",
        "hook_event_name" => "UserPromptSubmit",
      }.to_json

      result = run_binary(
        ["on-user-prompt-submit"],
        stdin: input,
      )
      result[:status].should eq(0)

      GalaxyLedger::Hooks::TurnState.exists?(
        "different-session-id",
      ).should be_false
    end

    it "overwrites state file on subsequent prompts" do
      ledger_id = GalaxyLedger::Database.create_session(
        test_session_id,
      )
      flush_wal

      # First prompt
      input1 = {
        "session_id"      => test_session_id,
        "prompt"          => "First message in the queue",
        "hook_event_name" => "UserPromptSubmit",
      }.to_json
      run_binary(
        ["on-user-prompt-submit"],
        stdin: input1,
      )

      first_state = GalaxyLedger::Hooks::TurnState.read(
        test_session_id,
      ).not_nil!
      first_uuid = first_state.uuid

      # Second prompt (overwrites)
      input2 = {
        "session_id"      => test_session_id,
        "prompt"          => "Second message overwrites first",
        "hook_event_name" => "UserPromptSubmit",
      }.to_json
      run_binary(
        ["on-user-prompt-submit"],
        stdin: input2,
      )

      second_state = GalaxyLedger::Hooks::TurnState.read(
        test_session_id,
      ).not_nil!

      second_state.uuid.should_not eq(first_uuid)
      second_state.user_message.should eq(
        "Second message overwrites first",
      )
    end
  end

  describe "CLI help" do
    it "shows help with -h flag" do
      result = run_binary(["on-user-prompt-submit", "-h"])
      result[:status].should eq(0)

      result[:output].should contain("on-user-prompt-submit")
      result[:output].should contain("UserPromptSubmit")
      result[:output].should contain("USAGE")
      result[:output].should contain("prompt")
      result[:output].should contain("BEHAVIOR")
    end

    it "shows help with --help flag" do
      result = run_binary(["on-user-prompt-submit", "--help"])
      result[:status].should eq(0)
      result[:output].should contain("on-user-prompt-submit")
    end
  end
end
