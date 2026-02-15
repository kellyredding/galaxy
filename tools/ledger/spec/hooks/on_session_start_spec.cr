require "../spec_helper"

describe "OnSessionStart GALAXY_SKIP_HOOKS" do
  it "returns early when GALAXY_SKIP_HOOKS=1 is set" do
    ENV["GALAXY_SKIP_HOOKS"] = "1"

    test_session_id = "skip-hooks-test-#{Random.rand(10000)}"
    session_dir = GalaxyLedger.session_dir(test_session_id)
    Dir.mkdir_p(session_dir)

    # Ensure session record exists and write last interaction to DB
    GalaxyLedger::Database.upsert_session(test_session_id)
    exchange = GalaxyLedger::Exchange::LastExchange.new(
      user_message: "Test message",
      full_content: "Test response",
      assistant_messages: [] of GalaxyLedger::Exchange::AssistantMessage
    )
    GalaxyLedger::Database.update_session_last_interaction(test_session_id, exchange.to_pretty_json)

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-session-start"], stdin: hook_input)
    result[:status].should eq(0)

    # Should return empty output (no terminal display, no hookSpecificOutput)
    result[:output].strip.should eq("")

    # Clean up
    FileUtils.rm_rf(session_dir.to_s)
    GalaxyLedger::Database.delete_session(test_session_id)
  ensure
    ENV.delete("GALAXY_SKIP_HOOKS")
  end
end

describe GalaxyLedger::Hooks::OnSessionStart do
  describe "#run" do
    it "creates instance successfully" do
      handler = GalaxyLedger::Hooks::OnSessionStart.new
      handler.should be_a(GalaxyLedger::Hooks::OnSessionStart)
    end
  end
end

describe "OnSessionStart JSON output" do
  test_session_id = "session-start-json-#{Random.rand(10000)}"

  before_each do
    session_dir = GalaxyLedger.session_dir(test_session_id)
    FileUtils.rm_rf(session_dir.to_s)
    Dir.mkdir_p(session_dir)
    GalaxyLedger::Database.delete_session(test_session_id)
    GalaxyLedger::Database.upsert_session(test_session_id)
  end

  after_each do
    session_dir = GalaxyLedger.session_dir(test_session_id)
    FileUtils.rm_rf(session_dir.to_s)
    GalaxyLedger::Database.delete_session(test_session_id)
  end

  it "outputs clean JSON with systemMessage and hookSpecificOutput" do
    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-session-start"], stdin: hook_input)
    result[:status].should eq(0)

    # Must be valid JSON
    output = JSON.parse(result[:output])
    output["systemMessage"].should be_a(JSON::Any)
    output["hookSpecificOutput"]["hookEventName"].should eq("SessionStart")
    output["hookSpecificOutput"]["additionalContext"].should be_a(JSON::Any)
  end

  it "outputs no non-JSON text on stdout" do
    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-session-start"], stdin: hook_input)
    result[:status].should eq(0)

    # The entire stdout should be a single JSON object
    JSON.parse(result[:output].strip) # Should not raise
  end
end

describe "OnSessionStart systemMessage" do
  test_session_id = "session-start-sm-#{Random.rand(10000)}"

  before_each do
    session_dir = GalaxyLedger.session_dir(test_session_id)
    FileUtils.rm_rf(session_dir.to_s)
    Dir.mkdir_p(session_dir)
    GalaxyLedger::Database.delete_session(test_session_id)
    GalaxyLedger::Database.upsert_session(test_session_id)
  end

  after_each do
    session_dir = GalaxyLedger.session_dir(test_session_id)
    FileUtils.rm_rf(session_dir.to_s)
    GalaxyLedger::Database.delete_session(test_session_id)
  end

  it "shows empty state when no data exists" do
    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-session-start"], stdin: hook_input)
    output = JSON.parse(result[:output])
    msg = output["systemMessage"].as_s
    msg.should contain("Handoff")
    msg.should contain("No previous context to hand off.")
  end

  it "includes entry counts when data exists" do
    # Add some guideline entries
    3.times do |i|
      entry = GalaxyLedger::Entry.new(
        entry_type: "guideline",
        content: "Guideline rule #{i + 1}",
        importance: "medium",
        source_file: "/home/user/agent-guidelines/ruby-style.md"
      )
      GalaxyLedger::Database.insert(test_session_id, entry)
    end

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-session-start"], stdin: hook_input)
    output = JSON.parse(result[:output])
    msg = output["systemMessage"].as_s
    msg.should contain("Handoff")
    msg.should contain("3 guidelines")
  end

  it "includes session file count" do
    # Add a session file
    GalaxyLedger::Database.upsert_session_file(
      test_session_id, "/home/user/app.rb", :read
    )

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-session-start"], stdin: hook_input)
    output = JSON.parse(result[:output])
    msg = output["systemMessage"].as_s
    msg.should contain("1 session file")
  end

  it "includes last exchange snippet" do
    exchange = GalaxyLedger::Exchange::LastExchange.new(
      user_message: "Fix the auth bug in login flow",
      full_content: "I fixed the auth bug.",
      assistant_messages: [] of GalaxyLedger::Exchange::AssistantMessage
    )
    GalaxyLedger::Database.update_session_last_interaction(test_session_id, exchange.to_pretty_json)

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-session-start"], stdin: hook_input)
    output = JSON.parse(result[:output])
    msg = output["systemMessage"].as_s
    msg.should contain("Last:")
    msg.should contain("Fix the auth bug")
  end

  it "truncates long last exchange snippet" do
    long_message = "A" * 200
    exchange = GalaxyLedger::Exchange::LastExchange.new(
      user_message: long_message,
      full_content: "Response",
      assistant_messages: [] of GalaxyLedger::Exchange::AssistantMessage
    )
    GalaxyLedger::Database.update_session_last_interaction(test_session_id, exchange.to_pretty_json)

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-session-start"], stdin: hook_input)
    output = JSON.parse(result[:output])
    msg = output["systemMessage"].as_s
    msg.should contain("...")
    # Snippet should not exceed 125 chars + surrounding text
    last_part = msg.split("Last: \"").last
    snippet = last_part.rstrip('"')
    snippet.size.should be <= 125
  end

  it "combines counts and files in status line" do
    # Add guidelines and decisions
    entry = GalaxyLedger::Entry.new(
      entry_type: "guideline",
      content: "Use double quotes",
      importance: "medium",
      source_file: "/home/user/guidelines/ruby.md"
    )
    GalaxyLedger::Database.insert(test_session_id, entry)

    entry = GalaxyLedger::Entry.new(
      entry_type: "decision",
      content: "Use SQLite",
      importance: "high"
    )
    GalaxyLedger::Database.insert(test_session_id, entry)

    GalaxyLedger::Database.upsert_session_file(test_session_id, "/home/user/app.rb", :edit)

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-session-start"], stdin: hook_input)
    output = JSON.parse(result[:output])
    msg = output["systemMessage"].as_s
    msg.should contain("1 guideline")
    msg.should contain("1 decision")
    msg.should contain("1 session file")
  end
end

describe "OnSessionStart additionalContext" do
  test_session_id = "session-start-ctx-#{Random.rand(10000)}"

  before_each do
    session_dir = GalaxyLedger.session_dir(test_session_id)
    FileUtils.rm_rf(session_dir.to_s)
    Dir.mkdir_p(session_dir)
    GalaxyLedger::Database.delete_session(test_session_id)
    GalaxyLedger::Database.upsert_session(test_session_id)
  end

  after_each do
    session_dir = GalaxyLedger.session_dir(test_session_id)
    FileUtils.rm_rf(session_dir.to_s)
    GalaxyLedger::Database.delete_session(test_session_id)
  end

  it "includes header and session ID" do
    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-session-start"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("## Session Context Handoff")
    ctx.should contain(test_session_id)
  end

  it "shows no-data message when session is empty" do
    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-session-start"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("No previous context available.")
  end

  it "includes orientation paragraph when data exists" do
    exchange = GalaxyLedger::Exchange::LastExchange.new(
      user_message: "Test",
      full_content: "Response",
      assistant_messages: [] of GalaxyLedger::Exchange::AssistantMessage
    )
    GalaxyLedger::Database.update_session_last_interaction(test_session_id, exchange.to_pretty_json)

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-session-start"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("Your context was just reset")
    ctx.should contain("full awareness")
  end

  it "includes recovery directives with session-scoped commands" do
    exchange = GalaxyLedger::Exchange::LastExchange.new(
      user_message: "Test",
      full_content: "Response",
      assistant_messages: [] of GalaxyLedger::Exchange::AssistantMessage
    )
    GalaxyLedger::Database.update_session_last_interaction(test_session_id, exchange.to_pretty_json)

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-session-start"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("Query the ledger")
    ctx.should contain("galaxy-ledger search")
    ctx.should contain("galaxy-ledger list-files")
    ctx.should contain("git diff")
    ctx.should contain("Fall back to normal exploration")
  end

  it "includes guidelines grouped by source file" do
    2.times do |i|
      entry = GalaxyLedger::Entry.new(
        entry_type: "guideline",
        content: "Ruby rule #{i + 1}",
        importance: "medium",
        source_file: "/home/user/agent-guidelines/ruby-style.md"
      )
      GalaxyLedger::Database.insert(test_session_id, entry)
    end

    entry = GalaxyLedger::Entry.new(
      entry_type: "guideline",
      content: "RSpec rule 1",
      importance: "medium",
      source_file: "/home/user/agent-guidelines/rspec-style.md"
    )
    GalaxyLedger::Database.insert(test_session_id, entry)

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-session-start"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("### Guidelines Active This Session")
    ctx.should contain("ruby-style.md")
    ctx.should contain("rspec-style.md")
    ctx.should contain("Ruby rule 1")
    ctx.should contain("RSpec rule 1")
  end

  it "includes implementation plans grouped by source file" do
    entry = GalaxyLedger::Entry.new(
      entry_type: "implementation_plan",
      content: "Step 1: Build the feature",
      importance: "medium",
      source_file: "/home/user/implementation-plans/feature.md"
    )
    GalaxyLedger::Database.insert(test_session_id, entry)

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-session-start"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("### Implementation Plans")
    ctx.should contain("feature.md")
    ctx.should contain("Step 1: Build the feature")
  end

  it "includes last interaction with summary fields" do
    exchange = GalaxyLedger::Exchange::LastExchange.new(
      user_message: "Add feature",
      full_content: "Full response content here...",
      assistant_messages: [] of GalaxyLedger::Exchange::AssistantMessage,
      summary: GalaxyLedger::Exchange::ExchangeSummary.new(
        user_request: "Add feature X",
        assistant_response: "Implemented the feature with tests",
        files_modified: ["app/feature.rb", "spec/feature_spec.rb"],
        key_actions: ["Created feature class", "Added test coverage"]
      )
    )
    GalaxyLedger::Database.update_session_last_interaction(test_session_id, exchange.to_pretty_json)

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-session-start"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("### Last Interaction")
    ctx.should contain("Add feature X")
    ctx.should contain("Implemented the feature with tests")
    ctx.should contain("Files modified")
    ctx.should contain("app/feature.rb")
    ctx.should contain("Key actions")
    ctx.should contain("Created feature class")
  end

  it "falls back to truncated full_content when no summary" do
    exchange = GalaxyLedger::Exchange::LastExchange.new(
      user_message: "Fix the bug",
      full_content: "I found the issue in the config file and fixed it by updating the parsing logic.",
      assistant_messages: [] of GalaxyLedger::Exchange::AssistantMessage
    )
    GalaxyLedger::Database.update_session_last_interaction(test_session_id, exchange.to_pretty_json)

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-session-start"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("**You asked**: Fix the bug")
    ctx.should contain("**What was accomplished**: I found the issue")
  end

  it "includes key decisions with importance labels" do
    entry_high = GalaxyLedger::Entry.new(
      entry_type: "decision",
      content: "Use SQLite for storage",
      importance: "high"
    )
    GalaxyLedger::Database.insert(test_session_id, entry_high)

    entry_med = GalaxyLedger::Entry.new(
      entry_type: "decision",
      content: "Use JSON output format",
      importance: "medium"
    )
    GalaxyLedger::Database.insert(test_session_id, entry_med)

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-session-start"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("### Key Decisions")
    ctx.should contain("Use SQLite for storage (high)")
    ctx.should contain("Use JSON output format (medium)")
  end

  it "includes recent learnings" do
    entry = GalaxyLedger::Entry.new(
      entry_type: "learning",
      content: "Crystal requires explicit type annotations for empty arrays",
      importance: "medium"
    )
    GalaxyLedger::Database.insert(test_session_id, entry)

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-session-start"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("### Recent Learnings")
    ctx.should contain("Crystal requires explicit type annotations")
  end

  it "includes session file manifest split by operation" do
    GalaxyLedger::Database.upsert_session_file(test_session_id, "/home/user/src/app.cr", :edit)
    GalaxyLedger::Database.upsert_session_file(test_session_id, "/home/user/src/app.cr", :read)
    GalaxyLedger::Database.upsert_session_file(test_session_id, "/home/user/README.md", :read)

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-session-start"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should contain("### Session File Manifest")
    ctx.should contain("**Edited/Written:**")
    ctx.should contain("src/app.cr")
    ctx.should contain("**Read:**")
    ctx.should contain("README.md")
  end

  it "skips sections when no data exists for them" do
    # Only add a last exchange — no guidelines, plans, decisions, learnings, files
    exchange = GalaxyLedger::Exchange::LastExchange.new(
      user_message: "Test",
      full_content: "Response",
      assistant_messages: [] of GalaxyLedger::Exchange::AssistantMessage
    )
    GalaxyLedger::Database.update_session_last_interaction(test_session_id, exchange.to_pretty_json)

    hook_input = {
      "session_id" => test_session_id,
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-session-start"], stdin: hook_input)
    output = JSON.parse(result[:output])
    ctx = output["hookSpecificOutput"]["additionalContext"].as_s
    ctx.should_not contain("### Guidelines")
    ctx.should_not contain("### Implementation Plans")
    ctx.should_not contain("### Key Decisions")
    ctx.should_not contain("### Recent Learnings")
    ctx.should_not contain("### Session File Manifest")
    # But should contain last interaction
    ctx.should contain("### Last Interaction")
  end
end

describe "OnSessionStart edge cases" do
  it "handles empty session_id gracefully" do
    hook_input = {
      "session_id" => "",
      "source"     => "clear",
    }.to_json

    result = run_binary(["on-session-start"], stdin: hook_input)
    result[:status].should eq(0)
    output = JSON.parse(result[:output])
    output["hookSpecificOutput"].should_not be_nil
  end

  it "handles empty stdin gracefully" do
    result = run_binary(["on-session-start"], stdin: "")
    result[:status].should eq(0)
    output = JSON.parse(result[:output])
    output["hookSpecificOutput"].should_not be_nil
  end

  it "handles malformed JSON stdin gracefully" do
    result = run_binary(["on-session-start"], stdin: "not valid json {{{")
    result[:status].should eq(0)
    output = JSON.parse(result[:output])
    output["hookSpecificOutput"].should_not be_nil
  end
end
