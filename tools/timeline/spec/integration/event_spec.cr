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

    it "outputs event ID as JSON with --json flag" do
      result = run_binary([
        "record",
        "--ledger-session-id", "1",
        "--event-type", "session:started",
        "--source", "test-source",
        "--json",
      ])

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      parsed["id"].as_i.should be > 0
    end

    it "outputs only JSON with --json (no human text)" do
      result = run_binary([
        "record",
        "--ledger-session-id", "1",
        "--event-type", "session:started",
        "--source", "test-source",
        "--json",
      ])

      result[:status].should eq(0)
      # Should NOT contain human-readable format
      result[:output].should_not contain("recorded")
      result[:output].should_not contain("type:")
      # Should be valid JSON with only an id field
      parsed = JSON.parse(result[:output])
      parsed["id"].as_i.should be > 0
    end

    it "outputs human-readable format without --json" do
      result = run_binary([
        "record",
        "--ledger-session-id", "1",
        "--event-type", "session:started",
        "--source", "test-source",
      ])

      result[:status].should eq(0)
      result[:output].should contain("recorded")
      result[:output].should contain("session:started")
      result[:output].should contain("test-source")
      # Should NOT be JSON format
      result[:output].should_not start_with("{")
    end

    it "outputs event ID as JSON with --json and detail-data" do
      result = run_binary([
        "record",
        "--ledger-session-id", "1",
        "--event-type", "context:cleared",
        "--source", "test-source",
        "--detail-data", %({"cwd":"/tmp"}),
        "--json",
      ])

      result[:status].should eq(0)
      parsed = JSON.parse(result[:output])
      event_id = parsed["id"].as_i

      # Verify the event was actually recorded with detail_data
      show_result = run_binary([
        "show", event_id.to_s, "--json",
      ])
      show_parsed = JSON.parse(show_result[:output])
      show_parsed["event_type"].as_s.should eq("context:cleared")
      show_parsed["detail_data"].as_s.should eq(%({"cwd":"/tmp"}))
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

    it "updates detail_data via --detail-data-stdin" do
      run_binary([
        "record", "--ledger-session-id", "1",
        "--event-type", "session:started",
        "--source", "test",
      ])

      # Get the event ID
      list_result = run_binary([
        "list", "--ledger-session-id", "1", "--json",
      ])
      event_id = JSON.parse(
        list_result[:output],
      )["events"].as_a[0]["id"].as_i.to_s

      stdin_data = %({"enriched":"via-stdin","count":42})
      result = run_binary(
        ["update", event_id, "--detail-data-stdin"],
        stdin: stdin_data,
      )

      result[:status].should eq(0)
      result[:output].should contain("updated")

      # Verify the update
      show_result = run_binary(["show", event_id, "--json"])
      parsed = JSON.parse(show_result[:output])
      detail = JSON.parse(parsed["detail_data"].as_s)
      detail["enriched"].as_s.should eq("via-stdin")
      detail["count"].as_i.should eq(42)
    end

    it "prefers --detail-data-stdin over --detail-data" do
      run_binary([
        "record", "--ledger-session-id", "1",
        "--event-type", "session:started",
        "--source", "test",
      ])

      list_result = run_binary([
        "list", "--ledger-session-id", "1", "--json",
      ])
      event_id = JSON.parse(
        list_result[:output],
      )["events"].as_a[0]["id"].as_i.to_s

      result = run_binary(
        [
          "update", event_id,
          "--detail-data", %({"from":"arg"}),
          "--detail-data-stdin",
        ],
        stdin: %({"from":"stdin"}),
      )

      result[:status].should eq(0)

      show_result = run_binary(["show", event_id, "--json"])
      parsed = JSON.parse(show_result[:output])
      detail = JSON.parse(parsed["detail_data"].as_s)
      detail["from"].as_s.should eq("stdin")
    end

    it "handles empty stdin with --detail-data-stdin" do
      run_binary([
        "record", "--ledger-session-id", "1",
        "--event-type", "session:started",
        "--source", "test",
        "--detail-data", %({"original":"data"}),
      ])

      list_result = run_binary([
        "list", "--ledger-session-id", "1", "--json",
      ])
      event_id = JSON.parse(
        list_result[:output],
      )["events"].as_a[0]["id"].as_i.to_s

      # Empty stdin — detail_data becomes nil (not set from
      # stdin), update still succeeds
      result = run_binary(
        ["update", event_id, "--detail-data-stdin"],
        stdin: "   ",
      )

      result[:status].should eq(0)
      result[:output].should contain("updated")
    end

    it "handles large payload via --detail-data-stdin" do
      run_binary([
        "record", "--ledger-session-id", "1",
        "--event-type", "context:cleared",
        "--source", "test",
      ])

      list_result = run_binary([
        "list", "--ledger-session-id", "1", "--json",
      ])
      event_id = JSON.parse(
        list_result[:output],
      )["events"].as_a[0]["id"].as_i.to_s

      # Simulate a large handoff payload (~10KB)
      large_content = "x" * 10_000
      payload = {
        handoff_content: large_content,
        decisions_count: 5,
      }.to_json

      result = run_binary(
        ["update", event_id, "--detail-data-stdin"],
        stdin: payload,
      )

      result[:status].should eq(0)

      # Verify the large payload was stored correctly
      show_result = run_binary(["show", event_id, "--json"])
      parsed = JSON.parse(show_result[:output])
      detail = JSON.parse(parsed["detail_data"].as_s)
      detail["handoff_content"].as_s.size.should eq(10_000)
      detail["decisions_count"].as_i.should eq(5)
    end

    it "supports Option C two-phase enrichment workflow" do
      # Phase 1: record with --json to get event ID (synchronous)
      record_result = run_binary([
        "record", "--json",
        "--ledger-session-id", "1",
        "--event-type", "context:cleared",
        "--source", "galaxy-ledger/hooks/on_clear",
        "--detail-data",
        %({"source":"user","cwd":"/tmp","git_branch":"main"}),
      ])

      record_result[:status].should eq(0)
      event_id = JSON.parse(
        record_result[:output],
      )["id"].as_i.to_s

      # Phase 2: enrich via --detail-data-stdin (fire-and-forget)
      enriched = {
        source:                 "user",
        cwd:                    "/tmp",
        git_branch:             "main",
        decisions_count:        3,
        learnings_count:        2,
        files_edited_count:     8,
        files_read_count:       15,
        exchanges_count:        5,
        snapshot_count:         1,
        snapshot_total_chars:   2500,
        artifact_count:         0,
        handoff_system_message: "Handoff │ 3 decisions",
        handoff_content:        "## Session Context Handoff\n\n...",
      }.to_json

      update_result = run_binary(
        ["update", event_id, "--detail-data-stdin"],
        stdin: enriched,
      )
      update_result[:status].should eq(0)

      # Verify: the enriched data replaced the initial data
      show_result = run_binary(["show", event_id, "--json"])
      show_parsed = JSON.parse(show_result[:output])
      show_parsed["event_type"].as_s.should eq("context:cleared")
      show_parsed["source"].as_s.should eq(
        "galaxy-ledger/hooks/on_clear",
      )

      detail = JSON.parse(show_parsed["detail_data"].as_s)
      detail["source"].as_s.should eq("user")
      detail["decisions_count"].as_i.should eq(3)
      detail["learnings_count"].as_i.should eq(2)
      detail["files_edited_count"].as_i.should eq(8)
      detail["files_read_count"].as_i.should eq(15)
      detail["exchanges_count"].as_i.should eq(5)
      detail["snapshot_count"].as_i.should eq(1)
      detail["artifact_count"].as_i.should eq(0)
      detail["handoff_system_message"].as_s.should contain(
        "Handoff",
      )
      detail["handoff_content"].as_s.should contain(
        "Session Context Handoff",
      )
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
