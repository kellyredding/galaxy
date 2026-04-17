require "../spec_helper"

describe GalaxyTimeline::Database do
  describe ".record_event" do
    it "records an event and returns its ID" do
      id = GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "session:started",
        source: "galaxy-ledger/hooks/on_startup",
      )
      id.should be > 0_i64
    end

    it "records an event with detail_data" do
      id = GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "session:started",
        source: "galaxy-ledger/hooks/on_startup",
        detail_data: %({"git_branch":"main"}),
      )
      event = GalaxyTimeline::Database.get_event(id)
      event.should_not be_nil
      event.not_nil!.detail_data.should eq(%({"git_branch":"main"}))
    end

    it "records an event with custom occurred_at" do
      id = GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "session:started",
        source: "galaxy-ledger/hooks/on_startup",
        occurred_at: "2026-01-15 10:30:00",
      )
      event = GalaxyTimeline::Database.get_event(id)
      event.should_not be_nil
      event.not_nil!.occurred_at.should eq("2026-01-15 10:30:00")
    end

    it "returns 0 for invalid ledger_session_id" do
      id = GalaxyTimeline::Database.record_event(
        0_i64,
        event_type: "session:started",
        source: "galaxy-ledger/hooks/on_startup",
      )
      id.should eq(0_i64)
    end

    it "returns 0 for negative ledger_session_id" do
      id = GalaxyTimeline::Database.record_event(
        -1_i64,
        event_type: "session:started",
        source: "galaxy-ledger/hooks/on_startup",
      )
      id.should eq(0_i64)
    end

    it "returns 0 for empty event_type" do
      id = GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "",
        source: "galaxy-ledger/hooks/on_startup",
      )
      id.should eq(0_i64)
    end

    it "returns 0 for empty source" do
      id = GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "session:started",
        source: "",
      )
      id.should eq(0_i64)
    end

    it "records event with nil detail_data" do
      id = GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "session:started",
        source: "galaxy-ledger/hooks/on_startup",
      )
      event = GalaxyTimeline::Database.get_event(id)
      event.should_not be_nil
      event.not_nil!.detail_data.should be_nil
    end

    it "records an event with duration_identifier" do
      id = GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "session:started",
        source: "galaxy-ledger/hooks/on_startup",
        duration_identifier: "ledger-session-id--1",
      )
      event = GalaxyTimeline::Database.get_event(id)
      event.should_not be_nil
      event.not_nil!.duration_identifier.should eq(
        "ledger-session-id--1",
      )
    end

    it "records event with nil duration_identifier by default" do
      id = GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "context:cleared",
        source: "galaxy-ledger/hooks/on_clear",
      )
      event = GalaxyTimeline::Database.get_event(id)
      event.should_not be_nil
      event.not_nil!.duration_identifier.should be_nil
    end

    it "records event with both detail_data and duration_identifier" do
      id = GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "session:started",
        source: "galaxy-ledger/hooks/on_startup",
        detail_data: %({"cwd":"/tmp"}),
        duration_identifier: "ledger-session-id--42",
      )
      event = GalaxyTimeline::Database.get_event(id)
      event.should_not be_nil
      event.not_nil!.detail_data.should eq(%({"cwd":"/tmp"}))
      event.not_nil!.duration_identifier.should eq(
        "ledger-session-id--42",
      )
    end

    it "records event with occurred_at and duration_identifier" do
      id = GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "session:started",
        source: "galaxy-ledger/hooks/on_startup",
        occurred_at: "2026-01-15 10:30:00",
        duration_identifier: "ledger-session-id--5",
      )
      event = GalaxyTimeline::Database.get_event(id)
      event.should_not be_nil
      event.not_nil!.occurred_at.should eq("2026-01-15 10:30:00")
      event.not_nil!.duration_identifier.should eq(
        "ledger-session-id--5",
      )
    end
  end

  describe ".list_events" do
    it "lists events ordered by occurred_at" do
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "session:started",
        source: "galaxy-ledger/hooks/on_startup",
        occurred_at: "2026-01-15 10:00:00",
      )
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "context:cleared",
        source: "galaxy-ledger/hooks/on_clear",
        occurred_at: "2026-01-15 11:00:00",
      )
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "snapshot:created",
        source: "galaxy-snapshots/cli",
        occurred_at: "2026-01-15 10:30:00",
      )

      events = GalaxyTimeline::Database.list_events(1_i64)
      events.size.should eq(3)
      events[0].event_type.should eq("session:started")
      events[1].event_type.should eq("snapshot:created")
      events[2].event_type.should eq("context:cleared")
    end

    it "filters by event_type" do
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "session:started",
        source: "galaxy-ledger/hooks/on_startup",
      )
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "context:cleared",
        source: "galaxy-ledger/hooks/on_clear",
      )

      events = GalaxyTimeline::Database.list_events(
        1_i64, event_type: "session:started")
      events.size.should eq(1)
      events[0].event_type.should eq("session:started")
    end

    it "returns empty for invalid session" do
      events = GalaxyTimeline::Database.list_events(0_i64)
      events.should be_empty
    end

    it "scopes to ledger_session_id" do
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "session:started",
        source: "galaxy-ledger/hooks/on_startup",
      )
      GalaxyTimeline::Database.record_event(
        2_i64,
        event_type: "session:started",
        source: "galaxy-ledger/hooks/on_startup",
      )

      events = GalaxyTimeline::Database.list_events(1_i64)
      events.size.should eq(1)
    end

    it "includes duration_identifier in listed events" do
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "session:started",
        source: "galaxy-ledger/hooks/on_startup",
        duration_identifier: "ledger-session-id--1",
      )
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "context:cleared",
        source: "galaxy-ledger/hooks/on_clear",
      )

      events = GalaxyTimeline::Database.list_events(1_i64)
      events.size.should eq(2)
      events[0].duration_identifier.should eq(
        "ledger-session-id--1",
      )
      events[1].duration_identifier.should be_nil
    end

    it "respects limit" do
      5.times do |i|
        GalaxyTimeline::Database.record_event(
          1_i64,
          event_type: "test:event",
          source: "test",
          occurred_at: "2026-01-15 10:0#{i}:00",
        )
      end

      events = GalaxyTimeline::Database.list_events(1_i64, limit: 3)
      events.size.should eq(3)
    end

    it "filters by multiple event_types" do
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "turn:completed",
        source: "test",
      )
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "turn:failed",
        source: "test",
      )
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "session:started",
        source: "test",
      )

      events = GalaxyTimeline::Database.list_events(
        1_i64,
        event_types: ["turn:completed", "turn:failed"],
      )
      events.size.should eq(2)
      types = events.map(&.event_type)
      types.should contain("turn:completed")
      types.should contain("turn:failed")
    end

    it "event_types takes precedence over event_type" do
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "turn:completed",
        source: "test",
      )
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "turn:failed",
        source: "test",
      )

      events = GalaxyTimeline::Database.list_events(
        1_i64,
        event_type: "turn:completed",
        event_types: ["turn:failed"],
      )
      events.size.should eq(1)
      events[0].event_type.should eq("turn:failed")
    end

    it "ignores empty event_types array" do
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "turn:completed",
        source: "test",
      )
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "session:started",
        source: "test",
      )

      events = GalaxyTimeline::Database.list_events(
        1_i64,
        event_types: [] of String,
      )
      events.size.should eq(2)
    end

    it "returns results in reverse order" do
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "turn:completed",
        source: "test",
        occurred_at: "2026-01-15 10:00:00",
      )
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "turn:completed",
        source: "test",
        occurred_at: "2026-01-15 11:00:00",
      )

      events = GalaxyTimeline::Database.list_events(
        1_i64, reverse: true)
      events[0].occurred_at.should eq(
        "2026-01-15 11:00:00",
      )
      events[1].occurred_at.should eq(
        "2026-01-15 10:00:00",
      )
    end

    it "combines reverse with limit" do
      5.times do |i|
        GalaxyTimeline::Database.record_event(
          1_i64,
          event_type: "turn:completed",
          source: "test",
          occurred_at: "2026-01-15 10:0#{i}:00",
        )
      end

      events = GalaxyTimeline::Database.list_events(
        1_i64, limit: 2, reverse: true)
      events.size.should eq(2)
      # Most recent first
      events[0].occurred_at.should eq(
        "2026-01-15 10:04:00",
      )
      events[1].occurred_at.should eq(
        "2026-01-15 10:03:00",
      )
    end

    it "combines event_types with reverse and limit" do
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "turn:completed",
        source: "test",
        occurred_at: "2026-01-15 10:00:00",
      )
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "session:started",
        source: "test",
        occurred_at: "2026-01-15 10:01:00",
      )
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "turn:failed",
        source: "test",
        occurred_at: "2026-01-15 10:02:00",
      )

      events = GalaxyTimeline::Database.list_events(
        1_i64,
        event_types: [
          "turn:completed", "turn:failed",
        ],
        limit: 5,
        reverse: true,
      )
      events.size.should eq(2)
      events[0].event_type.should eq("turn:failed")
      events[1].event_type.should eq("turn:completed")
    end

    it "filters by duration_identifier" do
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "turn:initiated",
        source: "test",
        duration_identifier: "turn--abc-1",
      )
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "turn:completed",
        source: "test",
        duration_identifier: "turn--abc-1",
      )
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "turn:initiated",
        source: "test",
        duration_identifier: "turn--abc-2",
      )

      events = GalaxyTimeline::Database.list_events(
        1_i64,
        duration_identifier: "turn--abc-1",
      )
      events.size.should eq(2)
      events.map(&.event_type).should eq([
        "turn:initiated", "turn:completed",
      ])
    end

    it "filters by since_time (inclusive lower bound)" do
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "turn:completed",
        source: "test",
        occurred_at: "2026-01-15 09:59:59",
      )
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "turn:completed",
        source: "test",
        occurred_at: "2026-01-15 10:00:00",
      )
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "turn:completed",
        source: "test",
        occurred_at: "2026-01-15 11:00:00",
      )

      events = GalaxyTimeline::Database.list_events(
        1_i64,
        since_time: "2026-01-15 10:00:00",
      )
      events.size.should eq(2)
      events[0].occurred_at.should eq(
        "2026-01-15 10:00:00",
      )
      events[1].occurred_at.should eq(
        "2026-01-15 11:00:00",
      )
    end

    it "filters by until_time (inclusive upper bound)" do
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "turn:completed",
        source: "test",
        occurred_at: "2026-01-15 09:00:00",
      )
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "turn:completed",
        source: "test",
        occurred_at: "2026-01-15 10:00:00",
      )
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "turn:completed",
        source: "test",
        occurred_at: "2026-01-15 10:00:01",
      )

      events = GalaxyTimeline::Database.list_events(
        1_i64,
        until_time: "2026-01-15 10:00:00",
      )
      events.size.should eq(2)
      events[0].occurred_at.should eq(
        "2026-01-15 09:00:00",
      )
      events[1].occurred_at.should eq(
        "2026-01-15 10:00:00",
      )
    end

    it "filters by since_time + until_time range" do
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "turn:completed",
        source: "test",
        occurred_at: "2026-01-15 09:00:00",
      )
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "turn:completed",
        source: "test",
        occurred_at: "2026-01-15 10:00:00",
      )
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "turn:completed",
        source: "test",
        occurred_at: "2026-01-15 10:30:00",
      )
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "turn:completed",
        source: "test",
        occurred_at: "2026-01-15 11:00:00",
      )

      events = GalaxyTimeline::Database.list_events(
        1_i64,
        since_time: "2026-01-15 10:00:00",
        until_time: "2026-01-15 10:30:00",
      )
      events.size.should eq(2)
      events[0].occurred_at.should eq(
        "2026-01-15 10:00:00",
      )
      events[1].occurred_at.should eq(
        "2026-01-15 10:30:00",
      )
    end

    it "combines duration_identifier with event_type, " \
       "reverse, and limit" do
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "turn:initiated",
        source: "test",
        occurred_at: "2026-01-15 10:00:00",
        duration_identifier: "turn--xyz",
      )
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "turn:completed",
        source: "test",
        occurred_at: "2026-01-15 10:00:05",
        duration_identifier: "turn--xyz",
      )
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "turn:completed",
        source: "test",
        occurred_at: "2026-01-15 10:00:10",
        duration_identifier: "turn--other",
      )

      events = GalaxyTimeline::Database.list_events(
        1_i64,
        event_type: "turn:completed",
        duration_identifier: "turn--xyz",
        reverse: true,
        limit: 10,
      )
      events.size.should eq(1)
      events[0].event_type.should eq("turn:completed")
      events[0].duration_identifier.should eq("turn--xyz")
    end
  end

  describe ".get_event" do
    it "returns the event by ID" do
      id = GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "session:started",
        source: "galaxy-ledger/hooks/on_startup",
      )
      event = GalaxyTimeline::Database.get_event(id)
      event.should_not be_nil
      event.not_nil!.event_type.should eq("session:started")
      event.not_nil!.source.should eq("galaxy-ledger/hooks/on_startup")
    end

    it "includes duration_identifier" do
      id = GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "session:started",
        source: "galaxy-ledger/hooks/on_startup",
        duration_identifier: "ledger-session-id--10",
      )
      event = GalaxyTimeline::Database.get_event(id)
      event.should_not be_nil
      event.not_nil!.duration_identifier.should eq(
        "ledger-session-id--10",
      )
    end

    it "returns nil for nonexistent ID" do
      event = GalaxyTimeline::Database.get_event(99999_i64)
      event.should be_nil
    end

    it "returns nil for zero ID" do
      event = GalaxyTimeline::Database.get_event(0_i64)
      event.should be_nil
    end

    it "returns nil for negative ID" do
      event = GalaxyTimeline::Database.get_event(-1_i64)
      event.should be_nil
    end
  end

  describe ".update_event" do
    it "replaces detail_data" do
      id = GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "session:started",
        source: "galaxy-ledger/hooks/on_startup",
        detail_data: %({"old":"data"}),
      )
      result = GalaxyTimeline::Database.update_event(id, %({"new":"data"}))
      result.should be_true

      event = GalaxyTimeline::Database.get_event(id)
      event.not_nil!.detail_data.should eq(%({"new":"data"}))
    end

    it "sets detail_data to nil" do
      id = GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "session:started",
        source: "galaxy-ledger/hooks/on_startup",
        detail_data: %({"old":"data"}),
      )
      result = GalaxyTimeline::Database.update_event(id, nil)
      result.should be_true

      event = GalaxyTimeline::Database.get_event(id)
      event.not_nil!.detail_data.should be_nil
    end

    it "updates updated_at timestamp" do
      id = GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "session:started",
        source: "galaxy-ledger/hooks/on_startup",
      )
      event_before = GalaxyTimeline::Database.get_event(id)

      # Small delay to ensure timestamp differs
      sleep 1.1.seconds

      GalaxyTimeline::Database.update_event(id, %({"updated":true}))
      event_after = GalaxyTimeline::Database.get_event(id)

      event_after.not_nil!.updated_at.should_not eq(
        event_before.not_nil!.updated_at,
      )
    end

    it "returns false for nonexistent ID" do
      result = GalaxyTimeline::Database.update_event(99999_i64, %({"x":1}))
      result.should be_false
    end

    it "returns false for zero ID" do
      result = GalaxyTimeline::Database.update_event(0_i64, %({"x":1}))
      result.should be_false
    end
  end

  describe ".delete_event" do
    it "deletes an event" do
      id = GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "session:started",
        source: "galaxy-ledger/hooks/on_startup",
      )
      result = GalaxyTimeline::Database.delete_event(id)
      result.should be_true

      GalaxyTimeline::Database.get_event(id).should be_nil
    end

    it "returns false for nonexistent ID" do
      result = GalaxyTimeline::Database.delete_event(99999_i64)
      result.should be_false
    end

    it "returns false for zero ID" do
      result = GalaxyTimeline::Database.delete_event(0_i64)
      result.should be_false
    end
  end

  describe ".session_event_count" do
    it "counts events for a session" do
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "session:started",
        source: "galaxy-ledger/hooks/on_startup",
      )
      GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "context:cleared",
        source: "galaxy-ledger/hooks/on_clear",
      )
      GalaxyTimeline::Database.record_event(
        2_i64,
        event_type: "session:started",
        source: "galaxy-ledger/hooks/on_startup",
      )

      GalaxyTimeline::Database.session_event_count(1_i64).should eq(2)
      GalaxyTimeline::Database.session_event_count(2_i64).should eq(1)
    end

    it "returns 0 for empty session" do
      GalaxyTimeline::Database.session_event_count(999_i64).should eq(0)
    end

    it "returns 0 for invalid session" do
      GalaxyTimeline::Database.session_event_count(0_i64).should eq(0)
    end
  end
end
