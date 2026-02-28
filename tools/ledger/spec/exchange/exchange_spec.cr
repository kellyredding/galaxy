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

    it "deserializes with decisions and learnings" do
      json = %|{
        "user_request": "Fix auth bug",
        "assistant_response": "Fixed JWT expiry check in middleware",
        "files_modified": ["app/middleware/auth.rb"],
        "key_actions": ["Patched expiry validation"],
        "decisions": [
          {
            "choice": "Fixed in middleware",
            "rationale": "Wrapper is shared across services",
            "alternatives": "Patching the JWT library"
          }
        ],
        "learnings": [
          "AuthMiddleware parses tokens twice"
        ]
      }|

      summary = GalaxyLedger::Exchange::ExchangeSummary.from_json(json)
      summary.decisions.should_not be_nil
      summary.decisions.not_nil!.size.should eq(1)
      summary.decisions.not_nil![0].choice.should eq("Fixed in middleware")
      summary.decisions.not_nil![0].rationale.should eq("Wrapper is shared across services")
      summary.decisions.not_nil![0].alternatives.should eq("Patching the JWT library")
      summary.learnings.should_not be_nil
      summary.learnings.not_nil!.should eq(["AuthMiddleware parses tokens twice"])
    end

    it "handles missing decisions and learnings (backward compat)" do
      json = %|{
        "user_request": "Test",
        "assistant_response": "Done",
        "files_modified": [],
        "key_actions": []
      }|

      summary = GalaxyLedger::Exchange::ExchangeSummary.from_json(json)
      summary.decisions.should be_nil
      summary.learnings.should be_nil
    end
  end

  describe "ExchangeDecision" do
    it "serializes to JSON" do
      decision = GalaxyLedger::Exchange::ExchangeDecision.new(
        choice: "Use Redis",
        rationale: "Need cross-process caching",
        alternatives: "In-memory cache"
      )

      json = decision.to_json
      json.should contain("Use Redis")
      json.should contain("rationale")
      json.should contain("alternatives")
    end

    it "handles nil alternatives" do
      decision = GalaxyLedger::Exchange::ExchangeDecision.new(
        choice: "Use Redis",
        rationale: "Need cross-process caching"
      )

      json = decision.to_json
      parsed = GalaxyLedger::Exchange::ExchangeDecision.from_json(json)
      parsed.choice.should eq("Use Redis")
      parsed.alternatives.should be_nil
    end
  end
end
