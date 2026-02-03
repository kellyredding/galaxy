require "../spec_helper"

describe GalaxyLedger::Transcript do
  describe "TranscriptEntry" do
    it "deserializes from JSONL entry" do
      json = %|{
        "uuid": "entry-123",
        "parentUuid": "parent-456",
        "sessionId": "session-789",
        "timestamp": "2026-02-01T10:00:00Z",
        "type": "user",
        "message": {
          "role": "user",
          "content": "Hello world"
        },
        "cwd": "/home/user/project",
        "isSidechain": false,
        "userType": "external",
        "version": "1.0"
      }|

      entry = GalaxyLedger::Transcript::TranscriptEntry.from_json(json)
      entry.uuid.should eq("entry-123")
      entry.parent_uuid.should eq("parent-456")
      entry.session_id.should eq("session-789")
      entry.type.should eq("user")
      entry.message.should_not be_nil
      entry.message.not_nil!.role.should eq("user")
      entry.message.not_nil!.content.should eq("Hello world")
    end

    it "handles missing optional fields" do
      json = %|{
        "type": "assistant",
        "message": {
          "role": "assistant",
          "content": "Response"
        }
      }|

      entry = GalaxyLedger::Transcript::TranscriptEntry.from_json(json)
      entry.type.should eq("assistant")
      entry.uuid.should be_nil
      entry.cwd.should be_nil
      entry.is_sidechain.should be_nil
    end
  end

  describe ".parse" do
    it "parses JSONL file" do
      # Create temp file with JSONL content
      temp_file = File.tempfile("transcript", ".jsonl")
      temp_file.print(%|{"type": "user", "message": {"role": "user", "content": "Hello"}}\n|)
      temp_file.print(%|{"type": "assistant", "message": {"role": "assistant", "content": "Hi there"}}\n|)
      temp_file.close

      entries = GalaxyLedger::Transcript.parse(temp_file.path)
      entries.size.should eq(2)
      entries[0].type.should eq("user")
      entries[0].message.not_nil!.content.should eq("Hello")
      entries[1].type.should eq("assistant")
      entries[1].message.not_nil!.content.should eq("Hi there")

      # Clean up
      File.delete(temp_file.path)
    end

    it "returns empty array for non-existent file" do
      entries = GalaxyLedger::Transcript.parse("/nonexistent/path/file.jsonl")
      entries.should be_empty
    end

    it "returns empty array for empty file" do
      temp_file = File.tempfile("empty-transcript", ".jsonl")
      temp_file.close

      entries = GalaxyLedger::Transcript.parse(temp_file.path)
      entries.should be_empty

      # Clean up
      File.delete(temp_file.path)
    end

    it "skips malformed lines" do
      temp_file = File.tempfile("mixed-transcript", ".jsonl")
      temp_file.print(%|{"type": "user", "message": {"role": "user", "content": "Good line"}}\n|)
      temp_file.print("not valid json {{{\n")
      temp_file.print(%|{"type": "assistant", "message": {"role": "assistant", "content": "Another good"}}\n|)
      temp_file.close

      entries = GalaxyLedger::Transcript.parse(temp_file.path)
      entries.size.should eq(2)

      # Clean up
      File.delete(temp_file.path)
    end

    it "skips empty lines" do
      temp_file = File.tempfile("with-blanks", ".jsonl")
      temp_file.print(%|{"type": "user", "message": {"role": "user", "content": "First"}}\n|)
      temp_file.print("\n")
      temp_file.print("   \n")
      temp_file.print(%|{"type": "assistant", "message": {"role": "assistant", "content": "Second"}}\n|)
      temp_file.close

      entries = GalaxyLedger::Transcript.parse(temp_file.path)
      entries.size.should eq(2)

      # Clean up
      File.delete(temp_file.path)
    end
  end

  describe ".extract_last_exchange" do
    it "extracts last user message and subsequent assistant messages" do
      entries = [
        create_entry("user", "First question"),
        create_entry("assistant", "First answer"),
        create_entry("user", "Second question"),
        create_entry("assistant", "Second answer part 1"),
        create_entry("assistant", "Second answer part 2"),
      ]

      extracted = GalaxyLedger::Transcript.extract_last_exchange(entries)
      extracted.should_not be_nil
      extracted.not_nil!.user_message.should eq("Second question")
      extracted.not_nil!.assistant_entries.size.should eq(2)
      extracted.not_nil!.assistant_entries[0].content.should eq("Second answer part 1")
      extracted.not_nil!.assistant_entries[1].content.should eq("Second answer part 2")
    end

    it "handles single user message with one assistant response" do
      entries = [
        create_entry("user", "Only question"),
        create_entry("assistant", "Only answer"),
      ]

      extracted = GalaxyLedger::Transcript.extract_last_exchange(entries)
      extracted.should_not be_nil
      extracted.not_nil!.user_message.should eq("Only question")
      extracted.not_nil!.assistant_entries.size.should eq(1)
    end

    it "handles user message without assistant response" do
      entries = [
        create_entry("user", "First question"),
        create_entry("assistant", "First answer"),
        create_entry("user", "Second question with no response yet"),
      ]

      extracted = GalaxyLedger::Transcript.extract_last_exchange(entries)
      extracted.should_not be_nil
      extracted.not_nil!.user_message.should eq("Second question with no response yet")
      extracted.not_nil!.assistant_entries.should be_empty
    end

    it "returns nil for empty entries" do
      entries = [] of GalaxyLedger::Transcript::TranscriptEntry
      extracted = GalaxyLedger::Transcript.extract_last_exchange(entries)
      extracted.should be_nil
    end

    it "returns nil when no user messages exist" do
      entries = [
        create_entry("assistant", "Some assistant message"),
        create_entry("assistant", "Another assistant message"),
      ]

      extracted = GalaxyLedger::Transcript.extract_last_exchange(entries)
      extracted.should be_nil
    end

    it "skips entries without message content" do
      entries = [
        create_entry("user", "Question"),
        create_entry_no_message("tool"), # Tool events don't have message
        create_entry("assistant", "Answer"),
      ]

      extracted = GalaxyLedger::Transcript.extract_last_exchange(entries)
      extracted.should_not be_nil
      extracted.not_nil!.assistant_entries.size.should eq(1)
    end

    it "preserves timestamps" do
      entries = [
        create_entry("user", "Question", "2026-02-01T10:00:00Z"),
        create_entry("assistant", "Answer", "2026-02-01T10:01:00Z"),
      ]

      extracted = GalaxyLedger::Transcript.extract_last_exchange(entries)
      extracted.should_not be_nil
      extracted.not_nil!.user_timestamp.should eq("2026-02-01T10:00:00Z")
      extracted.not_nil!.assistant_entries[0].timestamp.should eq("2026-02-01T10:01:00Z")
    end
  end

  describe ".to_last_exchange" do
    it "converts ExtractedExchange to LastExchange format" do
      extracted = GalaxyLedger::Transcript::ExtractedExchange.new(
        user_message: "Test question",
        user_timestamp: "2026-02-01T10:00:00Z",
        assistant_entries: [
          GalaxyLedger::Transcript::AssistantEntry.new(
            content: "First part",
            timestamp: "2026-02-01T10:01:00Z",
            tool_uses: ["Edit: file.rb"]
          ),
          GalaxyLedger::Transcript::AssistantEntry.new(
            content: "Second part",
            timestamp: "2026-02-01T10:02:00Z"
          ),
        ]
      )

      last_exchange = GalaxyLedger::Transcript.to_last_exchange(extracted)
      last_exchange.user_message.should eq("Test question")
      last_exchange.user_timestamp.should eq("2026-02-01T10:00:00Z")
      last_exchange.full_content.should eq("First part\n\nSecond part")
      last_exchange.assistant_messages.size.should eq(2)
      last_exchange.summary.should be_nil # Summary is generated in Phase 6
    end

    it "handles empty assistant entries" do
      extracted = GalaxyLedger::Transcript::ExtractedExchange.new(
        user_message: "Question with no response",
        assistant_entries: [] of GalaxyLedger::Transcript::AssistantEntry
      )

      last_exchange = GalaxyLedger::Transcript.to_last_exchange(extracted)
      last_exchange.user_message.should eq("Question with no response")
      last_exchange.full_content.should eq("")
      last_exchange.assistant_messages.should be_empty
    end
  end

  describe "ExtractedExchange" do
    it "reports has_assistant_response? correctly" do
      with_response = GalaxyLedger::Transcript::ExtractedExchange.new(
        user_message: "Question",
        assistant_entries: [
          GalaxyLedger::Transcript::AssistantEntry.new(content: "Answer"),
        ]
      )
      with_response.has_assistant_response?.should eq(true)

      without_response = GalaxyLedger::Transcript::ExtractedExchange.new(
        user_message: "Question",
        assistant_entries: [] of GalaxyLedger::Transcript::AssistantEntry
      )
      without_response.has_assistant_response?.should eq(false)
    end

    it "combines content correctly" do
      extracted = GalaxyLedger::Transcript::ExtractedExchange.new(
        user_message: "Question",
        assistant_entries: [
          GalaxyLedger::Transcript::AssistantEntry.new(content: "Part 1"),
          GalaxyLedger::Transcript::AssistantEntry.new(content: "Part 2"),
          GalaxyLedger::Transcript::AssistantEntry.new(content: "Part 3"),
        ]
      )
      extracted.combined_content.should eq("Part 1\n\nPart 2\n\nPart 3")
    end
  end
end

# Helper to create transcript entries for testing
private def create_entry(type : String, content : String, timestamp : String? = nil) : GalaxyLedger::Transcript::TranscriptEntry
  json = %|{
    "type": "#{type}",
    "timestamp": #{timestamp ? "\"#{timestamp}\"" : "null"},
    "message": {
      "role": "#{type == "user" ? "user" : "assistant"}",
      "content": "#{content}"
    }
  }|
  GalaxyLedger::Transcript::TranscriptEntry.from_json(json)
end

private def create_entry_no_message(type : String) : GalaxyLedger::Transcript::TranscriptEntry
  json = %|{"type": "#{type}"}|
  GalaxyLedger::Transcript::TranscriptEntry.from_json(json)
end
