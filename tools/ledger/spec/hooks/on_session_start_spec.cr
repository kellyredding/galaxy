require "../spec_helper"

describe GalaxyLedger::Hooks::OnSessionStart do
  describe "#run" do
    it "creates instance successfully" do
      handler = GalaxyLedger::Hooks::OnSessionStart.new
      handler.should be_a(GalaxyLedger::Hooks::OnSessionStart)
    end
  end
end

describe "OnSessionStart context restoration" do
  test_session_id = "session-start-test-#{Random.rand(10000)}"

  before_each do
    session_dir = GalaxyLedger.session_dir(test_session_id)
    FileUtils.rm_rf(session_dir.to_s)
    Dir.mkdir_p(session_dir)
  end

  after_each do
    session_dir = GalaxyLedger.session_dir(test_session_id)
    FileUtils.rm_rf(session_dir.to_s)
  end

  it "displays last exchange when available" do
    # Create last exchange file
    exchange = GalaxyLedger::Exchange::LastExchange.new(
      user_message: "Add user authentication",
      full_content: "I'll help you implement user authentication. First, let me create the auth controller...",
      assistant_messages: [
        GalaxyLedger::Exchange::AssistantMessage.new(
          content: "I'll help you implement user authentication. First, let me create the auth controller...",
          timestamp: "2026-02-01T10:00:00Z"
        ),
      ],
      user_timestamp: "2026-02-01T09:59:00Z"
    )
    GalaxyLedger::Exchange.write(test_session_id, exchange)

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-session-start"], stdin: hook_input)
    result[:status].should eq(0)

    # Check terminal output contains the exchange info
    result[:output].should contain("Last Interaction")
    result[:output].should contain("You asked")
    result[:output].should contain("Add user authentication")
    result[:output].should contain("I responded")
  end

  it "outputs JSON with additionalContext" do
    # Create last exchange file
    exchange = GalaxyLedger::Exchange::LastExchange.new(
      user_message: "Fix the bug",
      full_content: "I found the issue in the config file.",
      assistant_messages: [] of GalaxyLedger::Exchange::AssistantMessage
    )
    GalaxyLedger::Exchange.write(test_session_id, exchange)

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "compact",
    }.to_json

    result = run_binary(["on-session-start"], stdin: hook_input)
    result[:status].should eq(0)

    # Check JSON output
    result[:output].should contain("hookSpecificOutput")
    result[:output].should contain("additionalContext")
    result[:output].should contain("Restored Context")
    result[:output].should contain("Fix the bug")
  end

  it "handles missing last exchange gracefully" do
    # Don't create any exchange file

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-session-start"], stdin: hook_input)
    result[:status].should eq(0)

    # Should indicate no previous context
    result[:output].should contain("No previous context")
  end

  it "handles empty session_id gracefully" do
    hook_input = {
      "session_id" => "",
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-session-start"], stdin: hook_input)
    result[:status].should eq(0)
    result[:output].should contain("hookSpecificOutput")
  end

  it "handles empty stdin gracefully" do
    result = run_binary(["on-session-start"], stdin: "")
    result[:status].should eq(0)
    result[:output].should contain("hookSpecificOutput")
  end

  it "handles malformed JSON stdin gracefully" do
    result = run_binary(["on-session-start"], stdin: "not valid json {{{")
    result[:status].should eq(0)
    result[:output].should contain("hookSpecificOutput")
  end

  it "includes source in terminal output title" do
    exchange = GalaxyLedger::Exchange::LastExchange.new(
      user_message: "Test",
      full_content: "Response",
      assistant_messages: [] of GalaxyLedger::Exchange::AssistantMessage
    )
    GalaxyLedger::Exchange.write(test_session_id, exchange)

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-session-start"], stdin: hook_input)
    result[:output].should contain("Before clear")
  end

  it "truncates long responses in terminal output" do
    # Create exchange with very long content
    long_content = "This is a very long response. " * 100

    exchange = GalaxyLedger::Exchange::LastExchange.new(
      user_message: "Test",
      full_content: long_content,
      assistant_messages: [] of GalaxyLedger::Exchange::AssistantMessage
    )
    GalaxyLedger::Exchange.write(test_session_id, exchange)

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-session-start"], stdin: hook_input)
    result[:status].should eq(0)

    # Should show truncation indicator
    result[:output].should contain("more lines")
  end

  it "uses summary when available (Phase 6 feature)" do
    exchange = GalaxyLedger::Exchange::LastExchange.new(
      user_message: "Add feature",
      full_content: "Full response content here...",
      assistant_messages: [] of GalaxyLedger::Exchange::AssistantMessage,
      summary: GalaxyLedger::Exchange::ExchangeSummary.new(
        user_request: "Add feature",
        assistant_response: "Implemented the feature with tests",
        files_modified: ["app/feature.rb", "spec/feature_spec.rb"],
        key_actions: ["Created feature class", "Added test coverage"]
      )
    )
    GalaxyLedger::Exchange.write(test_session_id, exchange)

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-session-start"], stdin: hook_input)
    result[:status].should eq(0)

    # Should include summary info in additionalContext
    result[:output].should contain("Implemented the feature with tests")
    result[:output].should contain("Files modified")
  end
end

describe "OnSessionStart box formatting" do
  test_session_id = "box-format-test-#{Random.rand(10000)}"

  before_each do
    session_dir = GalaxyLedger.session_dir(test_session_id)
    FileUtils.rm_rf(session_dir.to_s)
    Dir.mkdir_p(session_dir)
  end

  after_each do
    session_dir = GalaxyLedger.session_dir(test_session_id)
    FileUtils.rm_rf(session_dir.to_s)
  end

  it "uses box drawing characters" do
    exchange = GalaxyLedger::Exchange::LastExchange.new(
      user_message: "Test",
      full_content: "Response",
      assistant_messages: [] of GalaxyLedger::Exchange::AssistantMessage
    )
    GalaxyLedger::Exchange.write(test_session_id, exchange)

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-session-start"], stdin: hook_input)

    # Check for box drawing characters
    result[:output].should contain("╭")
    result[:output].should contain("╯")
    result[:output].should contain("│")
  end
end
