require "../spec_helper"

describe GalaxyLedger::Exchange do
  describe "LastExchange" do
    it "serializes to JSON" do
      exchange = GalaxyLedger::Exchange::LastExchange.new(
        user_message: "Add authentication",
        full_content: "I'll help you add authentication...",
        assistant_messages: [
          GalaxyLedger::Exchange::AssistantMessage.new(
            content: "I'll help you add authentication...",
            timestamp: "2026-02-01T10:30:00Z",
            tool_uses: ["Edit: app/auth.rb"]
          ),
        ],
        user_timestamp: "2026-02-01T10:29:00Z"
      )

      json = exchange.to_pretty_json
      json.should contain("Add authentication")
      json.should contain("user_message")
      json.should contain("full_content")
      json.should contain("assistant_messages")
    end

    it "deserializes from JSON" do
      json = %|{
        "user_message": "Fix the bug",
        "user_timestamp": "2026-02-01T10:00:00Z",
        "full_content": "I found the issue...",
        "assistant_messages": [
          {
            "content": "I found the issue...",
            "timestamp": "2026-02-01T10:01:00Z",
            "tool_uses": ["Read: app/model.rb"]
          }
        ]
      }|

      exchange = GalaxyLedger::Exchange::LastExchange.from_json(json)
      exchange.user_message.should eq("Fix the bug")
      exchange.full_content.should eq("I found the issue...")
      exchange.user_timestamp.should eq("2026-02-01T10:00:00Z")
      exchange.assistant_messages.size.should eq(1)
      exchange.assistant_messages[0].content.should eq("I found the issue...")
    end

    it "handles optional summary field" do
      json = %|{
        "user_message": "Test",
        "full_content": "Response",
        "assistant_messages": [],
        "summary": {
          "user_request": "Test",
          "assistant_response": "Done",
          "files_modified": ["file.rb"],
          "key_actions": ["Created file"]
        }
      }|

      exchange = GalaxyLedger::Exchange::LastExchange.from_json(json)
      exchange.summary.should_not be_nil
      exchange.summary.not_nil!.user_request.should eq("Test")
      exchange.summary.not_nil!.files_modified.should eq(["file.rb"])
    end

    it "handles missing summary field" do
      json = %|{
        "user_message": "Test",
        "full_content": "Response",
        "assistant_messages": []
      }|

      exchange = GalaxyLedger::Exchange::LastExchange.from_json(json)
      exchange.summary.should be_nil
    end
  end

  describe "AssistantMessage" do
    it "serializes to JSON" do
      msg = GalaxyLedger::Exchange::AssistantMessage.new(
        content: "Here's the fix...",
        timestamp: "2026-02-01T10:00:00Z",
        tool_uses: ["Edit: file.rb", "Read: other.rb"]
      )

      json = msg.to_json
      json.should contain("Here's the fix...")
      json.should contain("tool_uses")
    end

    it "deserializes from JSON" do
      json = %|{
        "content": "Message content",
        "timestamp": "2026-02-01T10:00:00Z",
        "tool_uses": ["Edit: test.rb"]
      }|

      msg = GalaxyLedger::Exchange::AssistantMessage.from_json(json)
      msg.content.should eq("Message content")
      msg.timestamp.should eq("2026-02-01T10:00:00Z")
      msg.tool_uses.should eq(["Edit: test.rb"])
    end

    it "handles empty tool_uses" do
      json = %|{
        "content": "Just text",
        "tool_uses": []
      }|

      msg = GalaxyLedger::Exchange::AssistantMessage.from_json(json)
      msg.tool_uses.should be_empty
    end
  end

  describe "ExchangeSummary" do
    it "serializes to JSON" do
      summary = GalaxyLedger::Exchange::ExchangeSummary.new(
        user_request: "Add feature",
        assistant_response: "Added the feature",
        files_modified: ["app/feature.rb"],
        key_actions: ["Created feature class"]
      )

      json = summary.to_json
      json.should contain("user_request")
      json.should contain("assistant_response")
      json.should contain("files_modified")
      json.should contain("key_actions")
    end

    it "deserializes from JSON" do
      json = %|{
        "user_request": "Fix bug",
        "assistant_response": "Fixed it",
        "files_modified": ["bug.rb"],
        "key_actions": ["Patched method"]
      }|

      summary = GalaxyLedger::Exchange::ExchangeSummary.from_json(json)
      summary.user_request.should eq("Fix bug")
      summary.assistant_response.should eq("Fixed it")
      summary.files_modified.should eq(["bug.rb"])
      summary.key_actions.should eq(["Patched method"])
    end
  end

  describe ".read" do
    it "reads exchange from session folder" do
      session_id = "test-exchange-read-#{Random.rand(100000)}"
      session_dir = GalaxyLedger.session_dir(session_id)
      Dir.mkdir_p(session_dir)

      # Write test exchange file
      exchange_file = session_dir / GalaxyLedger::LEDGER_LAST_EXCHANGE_FILENAME
      File.write(exchange_file, %|{
        "user_message": "Test message",
        "full_content": "Test response",
        "assistant_messages": []
      }|)

      # Read it back
      exchange = GalaxyLedger::Exchange.read(session_id)
      exchange.should_not be_nil
      exchange.not_nil!.user_message.should eq("Test message")
      exchange.not_nil!.full_content.should eq("Test response")

      # Clean up
      FileUtils.rm_rf(session_dir.to_s)
    end

    it "returns nil when session doesn't exist" do
      session_id = "nonexistent-exchange-#{Random.rand(100000)}"
      FileUtils.rm_rf(GalaxyLedger.session_dir(session_id).to_s)

      exchange = GalaxyLedger::Exchange.read(session_id)
      exchange.should be_nil
    end

    it "returns nil when file doesn't exist" do
      session_id = "empty-exchange-#{Random.rand(100000)}"
      session_dir = GalaxyLedger.session_dir(session_id)
      Dir.mkdir_p(session_dir)

      exchange = GalaxyLedger::Exchange.read(session_id)
      exchange.should be_nil

      # Clean up
      FileUtils.rm_rf(session_dir.to_s)
    end

    it "returns nil for empty session_id" do
      exchange = GalaxyLedger::Exchange.read("")
      exchange.should be_nil
    end

    it "returns nil for malformed JSON" do
      session_id = "malformed-exchange-#{Random.rand(100000)}"
      session_dir = GalaxyLedger.session_dir(session_id)
      Dir.mkdir_p(session_dir)

      exchange_file = session_dir / GalaxyLedger::LEDGER_LAST_EXCHANGE_FILENAME
      File.write(exchange_file, "not valid json {{{")

      exchange = GalaxyLedger::Exchange.read(session_id)
      exchange.should be_nil

      # Clean up
      FileUtils.rm_rf(session_dir.to_s)
    end
  end

  describe ".write" do
    it "writes exchange to session folder" do
      session_id = "test-exchange-write-#{Random.rand(100000)}"

      exchange = GalaxyLedger::Exchange::LastExchange.new(
        user_message: "Write test",
        full_content: "Write response",
        assistant_messages: [] of GalaxyLedger::Exchange::AssistantMessage
      )

      result = GalaxyLedger::Exchange.write(session_id, exchange)
      result.should eq(true)

      # Verify file exists and content
      session_dir = GalaxyLedger.session_dir(session_id)
      exchange_file = session_dir / GalaxyLedger::LEDGER_LAST_EXCHANGE_FILENAME
      File.exists?(exchange_file).should eq(true)

      content = File.read(exchange_file)
      content.should contain("Write test")
      content.should contain("Write response")

      # Clean up
      FileUtils.rm_rf(session_dir.to_s)
    end

    it "creates session directory if needed" do
      session_id = "new-session-write-#{Random.rand(100000)}"
      session_dir = GalaxyLedger.session_dir(session_id)

      # Ensure it doesn't exist
      FileUtils.rm_rf(session_dir.to_s)

      exchange = GalaxyLedger::Exchange::LastExchange.new(
        user_message: "Test",
        full_content: "Response",
        assistant_messages: [] of GalaxyLedger::Exchange::AssistantMessage
      )

      result = GalaxyLedger::Exchange.write(session_id, exchange)
      result.should eq(true)
      Dir.exists?(session_dir).should eq(true)

      # Clean up
      FileUtils.rm_rf(session_dir.to_s)
    end

    it "returns false for empty session_id" do
      exchange = GalaxyLedger::Exchange::LastExchange.new(
        user_message: "Test",
        full_content: "Response",
        assistant_messages: [] of GalaxyLedger::Exchange::AssistantMessage
      )

      result = GalaxyLedger::Exchange.write("", exchange)
      result.should eq(false)
    end
  end

  describe ".exists?" do
    it "returns true when file exists" do
      session_id = "exists-exchange-#{Random.rand(100000)}"
      session_dir = GalaxyLedger.session_dir(session_id)
      Dir.mkdir_p(session_dir)

      exchange_file = session_dir / GalaxyLedger::LEDGER_LAST_EXCHANGE_FILENAME
      File.write(exchange_file, "{}")

      GalaxyLedger::Exchange.exists?(session_id).should eq(true)

      # Clean up
      FileUtils.rm_rf(session_dir.to_s)
    end

    it "returns false when session doesn't exist" do
      session_id = "not-exists-exchange-#{Random.rand(100000)}"
      FileUtils.rm_rf(GalaxyLedger.session_dir(session_id).to_s)

      GalaxyLedger::Exchange.exists?(session_id).should eq(false)
    end

    it "returns false for empty session_id" do
      GalaxyLedger::Exchange.exists?("").should eq(false)
    end
  end
end
