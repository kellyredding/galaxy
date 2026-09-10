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

  # What separates a queued message that becomes its own turn from one
  # that never will. Nothing at submit time can tell them apart — only
  # these records, written afterwards, can.
  describe ".queue_state" do
    it "is queued for a message still waiting" do
      with_queue_transcript([{"enqueue", "still waiting"}]) do |t|
        GalaxyLedger::Hooks::TranscriptScanner
          .queue_state(t, "still waiting")
          .should eq(
            GalaxyLedger::Hooks::TranscriptScanner::QueueState::Queued
          )
      end
    end

    # A dequeue names no content, so the enqueue stands as the last
    # word — which is what makes the queued case survive the drain.
    it "is queued after the queue drains into a turn" do
      with_queue_transcript([
        {"enqueue", "picked up"},
        {"dequeue", ""},
      ]) do |t|
        GalaxyLedger::Hooks::TranscriptScanner
          .queue_state(t, "picked up")
          .should eq(
            GalaxyLedger::Hooks::TranscriptScanner::QueueState::Queued
          )
      end
    end

    it "is gone for a message folded into the running turn" do
      with_queue_transcript([
        {"enqueue", "absorbed"},
        {"remove", "absorbed"},
      ]) do |t|
        GalaxyLedger::Hooks::TranscriptScanner
          .queue_state(t, "absorbed")
          .should eq(
            GalaxyLedger::Hooks::TranscriptScanner::QueueState::Gone
          )
      end
    end

    it "is gone when the whole queue was discarded" do
      with_queue_transcript([
        {"enqueue", "cleared"},
        {"popAll", "cleared"},
      ]) do |t|
        GalaxyLedger::Hooks::TranscriptScanner
          .queue_state(t, "cleared")
          .should eq(
            GalaxyLedger::Hooks::TranscriptScanner::QueueState::Gone
          )
      end
    end

    # popAll empties the queue, and a message that was never in it is
    # not something this transcript can speak to either way.
    it "stays unknown when popAll clears a queue it was not in" do
      with_queue_transcript([{"popAll", "someone else's"}]) do |t|
        GalaxyLedger::Hooks::TranscriptScanner
          .queue_state(t, "never queued here")
          .should eq(
            GalaxyLedger::Hooks::TranscriptScanner::QueueState::Unknown
          )
      end
    end

    it "is unknown for a transcript that never mentions it" do
      with_queue_transcript([{"enqueue", "another message"}]) do |t|
        GalaxyLedger::Hooks::TranscriptScanner
          .queue_state(t, "not in here")
          .should eq(
            GalaxyLedger::Hooks::TranscriptScanner::QueueState::Unknown
          )
      end
    end

    it "is unknown with no transcript to read" do
      GalaxyLedger::Hooks::TranscriptScanner
        .queue_state(nil, "anything")
        .should eq(
          GalaxyLedger::Hooks::TranscriptScanner::QueueState::Unknown
        )

      GalaxyLedger::Hooks::TranscriptScanner
        .queue_state("/nonexistent/transcript.jsonl", "anything")
        .should eq(
          GalaxyLedger::Hooks::TranscriptScanner::QueueState::Unknown
        )
    end

    # Re-queued after being absorbed once: the later enqueue is what
    # counts, or a message sent twice could never open a turn again.
    it "follows the last word on a message queued twice" do
      with_queue_transcript([
        {"enqueue", "same text"},
        {"remove", "same text"},
        {"enqueue", "same text"},
      ]) do |t|
        GalaxyLedger::Hooks::TranscriptScanner
          .queue_state(t, "same text")
          .should eq(
            GalaxyLedger::Hooks::TranscriptScanner::QueueState::Queued
          )
      end
    end
  end
end
