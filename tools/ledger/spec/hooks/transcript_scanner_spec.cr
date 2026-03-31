require "../spec_helper"

describe GalaxyLedger::Hooks::TranscriptScanner do
  test_session_id = "transcript-test-session"

  describe ".follow_up_messages" do
    it "extracts enqueue entries after the given timestamp" do
      transcript = File.tempfile("transcript", ".jsonl")
      transcript.puts(
        %|{"type":"queue-operation","operation":"enqueue",| \
        %|"timestamp":"2026-03-30T10:00:05Z",| \
        %|"sessionId":"#{test_session_id}",| \
        %|"content":"also check the tests"}|,
      )
      transcript.puts(
        %|{"type":"queue-operation","operation":"enqueue",| \
        %|"timestamp":"2026-03-30T10:00:08Z",| \
        %|"sessionId":"#{test_session_id}",| \
        %|"content":"and the docs too"}|,
      )
      transcript.close

      messages =
        GalaxyLedger::Hooks::TranscriptScanner
          .follow_up_messages(
            transcript.path,
            "2026-03-30T10:00:00Z",
            test_session_id,
          )

      messages.size.should eq(2)
      messages[0].content.should eq("also check the tests")
      messages[0].timestamp.should eq(
        "2026-03-30T10:00:05Z",
      )
      messages[1].content.should eq("and the docs too")

      File.delete(transcript.path)
    end

    it "filters out task-notification entries" do
      transcript = File.tempfile("transcript", ".jsonl")
      transcript.puts(
        %|{"type":"queue-operation","operation":"enqueue",| \
        %|"timestamp":"2026-03-30T10:00:05Z",| \
        %|"sessionId":"#{test_session_id}",| \
        %|"content":"real user message"}|,
      )
      transcript.puts(
        %|{"type":"queue-operation","operation":"enqueue",| \
        %|"timestamp":"2026-03-30T10:00:06Z",| \
        %|"sessionId":"#{test_session_id}",| \
        %|"content":"<task-notification>\\n<task-id>abc</task-id>\\n</task-notification>"}|,
      )
      transcript.close

      messages =
        GalaxyLedger::Hooks::TranscriptScanner
          .follow_up_messages(
            transcript.path,
            "2026-03-30T10:00:00Z",
            test_session_id,
          )

      messages.size.should eq(1)
      messages[0].content.should eq("real user message")

      File.delete(transcript.path)
    end

    it "respects timestamp boundary" do
      transcript = File.tempfile("transcript", ".jsonl")
      # Before the boundary — should be excluded
      transcript.puts(
        %|{"type":"queue-operation","operation":"enqueue",| \
        %|"timestamp":"2026-03-30T09:59:59Z",| \
        %|"sessionId":"#{test_session_id}",| \
        %|"content":"too early"}|,
      )
      # Exactly at boundary — should be excluded (not >)
      transcript.puts(
        %|{"type":"queue-operation","operation":"enqueue",| \
        %|"timestamp":"2026-03-30T10:00:00Z",| \
        %|"sessionId":"#{test_session_id}",| \
        %|"content":"at boundary"}|,
      )
      # After the boundary — should be included
      transcript.puts(
        %|{"type":"queue-operation","operation":"enqueue",| \
        %|"timestamp":"2026-03-30T10:00:01Z",| \
        %|"sessionId":"#{test_session_id}",| \
        %|"content":"after boundary"}|,
      )
      transcript.close

      messages =
        GalaxyLedger::Hooks::TranscriptScanner
          .follow_up_messages(
            transcript.path,
            "2026-03-30T10:00:00Z",
            test_session_id,
          )

      messages.size.should eq(1)
      messages[0].content.should eq("after boundary")

      File.delete(transcript.path)
    end

    it "filters by session ID" do
      transcript = File.tempfile("transcript", ".jsonl")
      transcript.puts(
        %|{"type":"queue-operation","operation":"enqueue",| \
        %|"timestamp":"2026-03-30T10:00:05Z",| \
        %|"sessionId":"#{test_session_id}",| \
        %|"content":"matching session"}|,
      )
      transcript.puts(
        %|{"type":"queue-operation","operation":"enqueue",| \
        %|"timestamp":"2026-03-30T10:00:06Z",| \
        %|"sessionId":"other-session-id",| \
        %|"content":"wrong session"}|,
      )
      transcript.close

      messages =
        GalaxyLedger::Hooks::TranscriptScanner
          .follow_up_messages(
            transcript.path,
            "2026-03-30T10:00:00Z",
            test_session_id,
          )

      messages.size.should eq(1)
      messages[0].content.should eq("matching session")

      File.delete(transcript.path)
    end

    it "returns empty array for missing file" do
      messages =
        GalaxyLedger::Hooks::TranscriptScanner
          .follow_up_messages(
            "/tmp/nonexistent-transcript.jsonl",
            "2026-03-30T10:00:00Z",
            test_session_id,
          )

      messages.should be_empty
    end

    it "returns empty array for empty file" do
      transcript = File.tempfile("transcript", ".jsonl")
      transcript.close

      messages =
        GalaxyLedger::Hooks::TranscriptScanner
          .follow_up_messages(
            transcript.path,
            "2026-03-30T10:00:00Z",
            test_session_id,
          )

      messages.should be_empty

      File.delete(transcript.path)
    end

    it "skips malformed JSONL lines gracefully" do
      transcript = File.tempfile("transcript", ".jsonl")
      transcript.puts("not valid json at all")
      transcript.puts(
        %|{"type":"queue-operation","operation":"enqueue",| \
        %|"timestamp":"2026-03-30T10:00:05Z",| \
        %|"sessionId":"#{test_session_id}",| \
        %|"content":"valid entry"}|,
      )
      transcript.puts(%|{"incomplete": true|)
      transcript.close

      messages =
        GalaxyLedger::Hooks::TranscriptScanner
          .follow_up_messages(
            transcript.path,
            "2026-03-30T10:00:00Z",
            test_session_id,
          )

      messages.size.should eq(1)
      messages[0].content.should eq("valid entry")

      File.delete(transcript.path)
    end

    it "ignores non-enqueue operations" do
      transcript = File.tempfile("transcript", ".jsonl")
      transcript.puts(
        %|{"type":"queue-operation","operation":"remove",| \
        %|"timestamp":"2026-03-30T10:00:05Z",| \
        %|"sessionId":"#{test_session_id}"}|,
      )
      transcript.puts(
        %|{"type":"queue-operation","operation":"enqueue",| \
        %|"timestamp":"2026-03-30T10:00:06Z",| \
        %|"sessionId":"#{test_session_id}",| \
        %|"content":"queued message"}|,
      )
      transcript.close

      messages =
        GalaxyLedger::Hooks::TranscriptScanner
          .follow_up_messages(
            transcript.path,
            "2026-03-30T10:00:00Z",
            test_session_id,
          )

      messages.size.should eq(1)
      messages[0].content.should eq("queued message")

      File.delete(transcript.path)
    end

    it "ignores non-queue-operation entry types" do
      transcript = File.tempfile("transcript", ".jsonl")
      transcript.puts(
        %|{"type":"user","timestamp":"2026-03-30T10:00:05Z",| \
        %|"message":{"role":"user","content":"hello"}}|,
      )
      transcript.puts(
        %|{"type":"assistant","timestamp":"2026-03-30T10:00:06Z",| \
        %|"message":{"role":"assistant","content":"hi"}}|,
      )
      transcript.close

      messages =
        GalaxyLedger::Hooks::TranscriptScanner
          .follow_up_messages(
            transcript.path,
            "2026-03-30T10:00:00Z",
            test_session_id,
          )

      messages.should be_empty

      File.delete(transcript.path)
    end

    it "serializes FollowUpMessage to JSON correctly" do
      transcript = File.tempfile("transcript", ".jsonl")
      transcript.puts(
        %|{"type":"queue-operation","operation":"enqueue",| \
        %|"timestamp":"2026-03-30T10:00:05Z",| \
        %|"sessionId":"#{test_session_id}",| \
        %|"content":"test message"}|,
      )
      transcript.close

      messages =
        GalaxyLedger::Hooks::TranscriptScanner
          .follow_up_messages(
            transcript.path,
            "2026-03-30T10:00:00Z",
            test_session_id,
          )

      json_str = messages.to_json
      parsed = JSON.parse(json_str)
      parsed[0]["content"].as_s.should eq("test message")
      parsed[0]["timestamp"].as_s.should eq(
        "2026-03-30T10:00:05Z",
      )

      File.delete(transcript.path)
    end
  end
end
