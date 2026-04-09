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

  # ---------------------------------------------------------------------------
  # extract_recent_exchanges
  # ---------------------------------------------------------------------------
  describe ".extract_recent_exchanges" do
    it "returns empty for empty entries" do
      result = GalaxyLedger::Transcript.extract_recent_exchanges([] of GalaxyLedger::Transcript::TranscriptEntry)
      result.size.should eq(0)
    end

    it "returns last N exchanges in chronological order" do
      entries = [
        create_entry("user", "First question"),
        create_entry("assistant", "First answer"),
        create_entry("user", "Second question"),
        create_entry("assistant", "Second answer"),
        create_entry("user", "Third question"),
        create_entry("assistant", "Third answer"),
      ]

      result = GalaxyLedger::Transcript.extract_recent_exchanges(entries, limit: 2)
      result.size.should eq(2)
      result[0].user_message.should eq("Second question")
      result[1].user_message.should eq("Third question")
    end

    it "returns all exchanges when fewer than limit" do
      entries = [
        create_entry("user", "Only question"),
        create_entry("assistant", "Only answer"),
      ]

      result = GalaxyLedger::Transcript.extract_recent_exchanges(entries, limit: 5)
      result.size.should eq(1)
      result[0].user_message.should eq("Only question")
    end

    it "skips command entries" do
      entries = [
        create_entry("user", "Real question"),
        create_entry("assistant", "Real answer"),
        create_entry("user", "<command-name>/clear</command-name>"),
        create_entry("user", "After clear question"),
        create_entry("assistant", "After clear answer"),
      ]

      result = GalaxyLedger::Transcript.extract_recent_exchanges(entries, limit: 5)
      result.size.should eq(2)
      result[0].user_message.should eq("Real question")
      result[1].user_message.should eq("After clear question")
    end

    it "skips local-command entries" do
      entries = [
        create_entry("user", "<local-command>something</local-command>"),
        create_entry("user", "Real question"),
        create_entry("assistant", "Real answer"),
      ]

      result = GalaxyLedger::Transcript.extract_recent_exchanges(entries, limit: 5)
      result.size.should eq(1)
      result[0].user_message.should eq("Real question")
    end

    it "collects assistant responses for each user message" do
      entries = [
        create_entry("user", "Question"),
        create_entry("assistant", "Part 1"),
        create_entry("assistant", "Part 2"),
      ]

      result = GalaxyLedger::Transcript.extract_recent_exchanges(entries, limit: 5)
      result.size.should eq(1)
      result[0].assistant_entries.size.should eq(2)
      result[0].assistant_entries[0].content.should eq("Part 1")
      result[0].assistant_entries[1].content.should eq("Part 2")
    end

    it "stops collecting assistant entries at next real user message" do
      entries = [
        create_entry("user", "First question"),
        create_entry("assistant", "First answer"),
        create_entry("user", "Second question"),
        create_entry("assistant", "Second answer"),
      ]

      result = GalaxyLedger::Transcript.extract_recent_exchanges(entries, limit: 5)
      result.size.should eq(2)
      result[0].assistant_entries.size.should eq(1)
      result[0].assistant_entries[0].content.should eq("First answer")
      result[1].assistant_entries.size.should eq(1)
      result[1].assistant_entries[0].content.should eq("Second answer")
    end

    it "collects assistant text through interleaved tool_use/tool_result entries" do
      entries = [
        create_entry("user", "Help me add dark mode"),
        create_entry_with_blocks("assistant", [{"type" => "tool_use"}]),
        create_entry_with_blocks("user", [{"type" => "tool_result", "content" => "output"}]),
        create_entry_with_blocks("assistant", [{"type" => "tool_use"}]),
        create_entry_with_blocks("user", [{"type" => "tool_result", "content" => "file content"}]),
        create_entry_with_blocks("assistant", [{"type" => "text", "text" => "I added dark mode support."}]),
      ]

      result = GalaxyLedger::Transcript.extract_recent_exchanges(entries, limit: 5)
      result.size.should eq(1)
      result[0].user_message.should eq("Help me add dark mode")
      result[0].assistant_entries.size.should eq(1)
      result[0].assistant_entries[0].content.should eq("I added dark mode support.")
    end

    it "handles multiple exchanges each with tool_use/tool_result interleaving" do
      entries = [
        # Exchange 1: user question → tool use → tool result → text response
        create_entry("user", "Fix the auth bug"),
        create_entry_with_blocks("assistant", [{"type" => "tool_use"}]),
        create_entry_with_blocks("user", [{"type" => "tool_result", "content" => "code"}]),
        create_entry_with_blocks("assistant", [{"type" => "text", "text" => "Fixed the auth bug."}]),
        # Exchange 2: user question → tool use → tool result → text response
        create_entry("user", "Now add specs"),
        create_entry_with_blocks("assistant", [{"type" => "tool_use"}]),
        create_entry_with_blocks("user", [{"type" => "tool_result", "content" => "ok"}]),
        create_entry_with_blocks("assistant", [{"type" => "text", "text" => "Added specs for the fix."}]),
      ]

      result = GalaxyLedger::Transcript.extract_recent_exchanges(entries, limit: 5)
      result.size.should eq(2)
      result[0].user_message.should eq("Fix the auth bug")
      result[0].assistant_entries.size.should eq(1)
      result[0].assistant_entries[0].content.should eq("Fixed the auth bug.")
      result[1].user_message.should eq("Now add specs")
      result[1].assistant_entries.size.should eq(1)
      result[1].assistant_entries[0].content.should eq("Added specs for the fix.")
    end

    it "skips command entries between tool interactions" do
      entries = [
        create_entry("user", "Do something"),
        create_entry_with_blocks("assistant", [{"type" => "tool_use"}]),
        create_entry_with_blocks("user", [{"type" => "tool_result", "content" => "ok"}]),
        create_entry_with_blocks("assistant", [{"type" => "text", "text" => "Done."}]),
        # Command entries should not be picked as exchanges
        create_entry("user", "<command-name>/clear</command-name>"),
        create_entry("user", "After clear"),
        create_entry_with_blocks("assistant", [{"type" => "text", "text" => "Resumed."}]),
      ]

      result = GalaxyLedger::Transcript.extract_recent_exchanges(entries, limit: 5)
      result.size.should eq(2)
      result[0].user_message.should eq("Do something")
      result[0].assistant_entries[0].content.should eq("Done.")
      result[1].user_message.should eq("After clear")
      result[1].assistant_entries[0].content.should eq("Resumed.")
    end

    it "respects limit parameter" do
      entries = [
        create_entry("user", "Q1"),
        create_entry("assistant", "A1"),
        create_entry("user", "Q2"),
        create_entry("assistant", "A2"),
        create_entry("user", "Q3"),
        create_entry("assistant", "A3"),
        create_entry("user", "Q4"),
        create_entry("assistant", "A4"),
      ]

      result = GalaxyLedger::Transcript.extract_recent_exchanges(entries, limit: 3)
      result.size.should eq(3)
      result[0].user_message.should eq("Q2")
      result[1].user_message.should eq("Q3")
      result[2].user_message.should eq("Q4")
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

# Create a transcript entry with array-type content blocks (tool_use, tool_result, text).
# Mirrors the real transcript format where content is an array of typed blocks.
private def create_entry_with_blocks(
  type : String,
  blocks : Array(Hash(String, String)),
  timestamp : String? = nil,
) : GalaxyLedger::Transcript::TranscriptEntry
  role = type == "user" ? "user" : "assistant"
  blocks_json = blocks.map do |block|
    parts = block.map { |k, v| %("#{k}": "#{v}") }
    "{#{parts.join(", ")}}"
  end.join(", ")

  json = %|{
    "type": "#{type}",
    "timestamp": #{timestamp ? "\"#{timestamp}\"" : "null"},
    "message": {
      "role": "#{role}",
      "content": [#{blocks_json}]
    }
  }|
  GalaxyLedger::Transcript::TranscriptEntry.from_json(json)
end
