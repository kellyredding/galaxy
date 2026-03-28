require "../spec_helper"

describe "CLI event commands", tags: "integration" do
  describe "record" do
    it "records an event via CLI" do
      result = run_binary([
        "record",
        "--ledger-session-id", "1",
        "--event-type", "session:started",
        "--source", "manual-test",
      ])

      result[:status].should eq(0)
      result[:output].should contain("recorded")
      result[:output].should contain("session:started")
      result[:output].should contain("manual-test")
    end

    it "records an event with detail-data" do
      result = run_binary([
        "record",
        "--ledger-session-id", "1",
        "--event-type", "session:started",
        "--source", "manual-test",
        "--detail-data", %({"git_branch":"main"}),
      ])

      result[:status].should eq(0)
      result[:output].should contain("recorded")
    end

    it "records an event with occurred-at" do
      result = run_binary([
        "record",
        "--ledger-session-id", "1",
        "--event-type", "session:started",
        "--source", "manual-test",
        "--occurred-at", "2026-01-15 10:30:00",
      ])

      result[:status].should eq(0)
      result[:output].should contain("recorded")
    end

    it "errors when no session identifier provided" do
      result = run_binary([
        "record",
        "--event-type", "session:started",
        "--source", "manual-test",
      ])

      result[:status].should_not eq(0)
      result[:error].should contain("--pid or --ledger-session-id is required")
    end

    it "errors when event-type is missing" do
      result = run_binary([
        "record",
        "--ledger-session-id", "1",
        "--source", "manual-test",
      ])

      result[:status].should_not eq(0)
      result[:error].should contain("--event-type is required")
    end

    it "errors when source is missing" do
      result = run_binary([
        "record",
        "--ledger-session-id", "1",
        "--event-type", "session:started",
      ])

      result[:status].should_not eq(0)
      result[:error].should contain("--source is required")
    end

    it "errors with invalid ledger-session-id" do
      result = run_binary([
        "record",
        "--ledger-session-id", "not-a-number",
        "--event-type", "session:started",
        "--source", "test",
      ])

      result[:status].should_not eq(0)
      result[:error].should contain("invalid")
    end
  end

  describe "list" do
    it "lists events in human-readable format" do
      run_binary([
        "record", "--ledger-session-id", "1",
        "--event-type", "session:started",
        "--source", "test-source",
      ])
      run_binary([
        "record", "--ledger-session-id", "1",
        "--event-type", "context:cleared",
        "--source", "test-source-2",
      ])

      result = run_binary(["list", "--ledger-session-id", "1"])

      result[:status].should eq(0)
      result[:output].should contain("2 total")
      result[:output].should contain("session:started")
      result[:output].should contain("context:cleared")
    end

    it "lists events in JSON format" do
      run_binary([
        "record", "--ledger-session-id", "1",
        "--event-type", "session:started",
        "--source", "test-source",
      ])

      result = run_binary(["list", "--ledger-session-id", "1", "--json"])

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      events = parsed["events"].as_a
      events.size.should eq(1)
      events[0]["event_type"].as_s.should eq("session:started")
      events[0]["source"].as_s.should eq("test-source")
    end

    it "filters by event-type" do
      run_binary([
        "record", "--ledger-session-id", "1",
        "--event-type", "session:started",
        "--source", "test",
      ])
      run_binary([
        "record", "--ledger-session-id", "1",
        "--event-type", "context:cleared",
        "--source", "test",
      ])

      result = run_binary([
        "list", "--ledger-session-id", "1",
        "--event-type", "session:started", "--json",
      ])

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["events"].as_a.size.should eq(1)
    end

    it "shows empty message when no events" do
      result = run_binary(["list", "--ledger-session-id", "1"])

      result[:status].should eq(0)
      result[:output].should contain("No events")
    end

    it "returns empty JSON array when no events with --json" do
      result = run_binary(["list", "--ledger-session-id", "1", "--json"])

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["events"].as_a.size.should eq(0)
    end

    it "errors when no session identifier provided" do
      result = run_binary(["list"])

      result[:status].should_not eq(0)
      result[:error].should contain("--pid")
    end
  end

  describe "show" do
    it "shows event details in human-readable format" do
      run_binary([
        "record", "--ledger-session-id", "1",
        "--event-type", "session:started",
        "--source", "galaxy-ledger/hooks/on_startup",
        "--detail-data", %({"git_branch":"main"}),
      ])

      # Get the event ID from JSON list
      list_result = run_binary(["list", "--ledger-session-id", "1", "--json"])
      event_id = JSON.parse(list_result[:output])["events"].as_a[0]["id"].as_i.to_s

      result = run_binary(["show", event_id])

      result[:status].should eq(0)
      result[:output].should contain("Event ##{event_id}")
      result[:output].should contain("session:started")
      result[:output].should contain("galaxy-ledger/hooks/on_startup")
      result[:output].should contain("git_branch")
    end

    it "shows event details in JSON format" do
      run_binary([
        "record", "--ledger-session-id", "1",
        "--event-type", "session:started",
        "--source", "test-source",
      ])

      # Get the event ID from JSON list
      list_result = run_binary(["list", "--ledger-session-id", "1", "--json"])
      event_id = JSON.parse(list_result[:output])["events"].as_a[0]["id"].as_i.to_s

      result = run_binary(["show", event_id, "--json"])

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["id"].as_i.to_s.should eq(event_id)
      parsed["event_type"].as_s.should eq("session:started")
      parsed["source"].as_s.should eq("test-source")
      parsed["ledger_session_id"].as_i.should eq(1)
    end

    it "errors when event not found" do
      result = run_binary(["show", "99999"])

      result[:status].should_not eq(0)
      result[:error].should contain("not found")
    end

    it "errors when no ID provided" do
      result = run_binary(["show"])

      result[:status].should_not eq(0)
      result[:error].should contain("event ID is required")
    end
  end

  describe "update" do
    it "updates detail_data on an event" do
      run_binary([
        "record", "--ledger-session-id", "1",
        "--event-type", "session:started",
        "--source", "test",
      ])

      # Get the event ID from JSON list
      list_result = run_binary(["list", "--ledger-session-id", "1", "--json"])
      event_id = JSON.parse(list_result[:output])["events"].as_a[0]["id"].as_i.to_s

      result = run_binary([
        "update", event_id,
        "--detail-data", %({"updated":"value"}),
      ])

      result[:status].should eq(0)
      result[:output].should contain("Event ##{event_id} updated")

      # Verify the update
      show_result = run_binary(["show", event_id, "--json"])
      parsed = JSON.parse(show_result[:output])
      parsed["detail_data"].as_s.should eq(%({"updated":"value"}))
    end

    it "errors when event not found" do
      result = run_binary(["update", "99999", "--detail-data", "{}"])

      result[:status].should_not eq(0)
      result[:error].should contain("not found")
    end

    it "errors when no ID provided" do
      result = run_binary(["update", "--detail-data", "{}"])

      result[:status].should_not eq(0)
    end
  end

  describe "delete" do
    it "deletes an event" do
      run_binary([
        "record", "--ledger-session-id", "1",
        "--event-type", "session:started",
        "--source", "test",
      ])

      # Get the event ID from JSON list
      list_result = run_binary(["list", "--ledger-session-id", "1", "--json"])
      event_id = JSON.parse(list_result[:output])["events"].as_a[0]["id"].as_i.to_s

      result = run_binary(["delete", event_id])

      result[:status].should eq(0)
      result[:output].should contain("Event ##{event_id} deleted")

      # Verify it's gone
      list_result2 = run_binary(["list", "--ledger-session-id", "1"])
      list_result2[:output].should contain("No events")
    end

    it "errors when event not found" do
      result = run_binary(["delete", "99999"])

      result[:status].should_not eq(0)
      result[:error].should contain("not found")
    end

    it "errors when no ID provided" do
      result = run_binary(["delete"])

      result[:status].should_not eq(0)
      result[:error].should contain("event ID is required")
    end
  end
end
