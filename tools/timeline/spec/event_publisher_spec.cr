require "./spec_helper"

describe GalaxyTimeline::EventPublisher do
  describe ".build_envelope" do
    it "builds valid JSON with all required fields" do
      json = GalaxyTimeline::EventPublisher.build_envelope(
        event: "timeline.turn:completed",
        ledger_session_id: 42_i64,
        session_identifiers: ["abc-123", "def-456"],
      )

      parsed = JSON.parse(json)
      parsed["v"].as_i.should eq(1)
      parsed["event"].as_s.should eq(
        "timeline.turn:completed",
      )
      parsed["ledger_session_id"].as_i64.should eq(42)
      parsed["session_identifiers"].as_a
        .map(&.as_s).should eq(
        ["abc-123", "def-456"],
      )
      parsed["ts"].as_i64.should be > 0
    end

    it "includes ref when provided" do
      json = GalaxyTimeline::EventPublisher.build_envelope(
        event: "timeline.artifact:created",
        ledger_session_id: 42_i64,
        session_identifiers: ["abc-123"],
        ref: "7",
      )

      parsed = JSON.parse(json)
      parsed["ref"].as_s.should eq("7")
    end

    it "omits ref when not provided" do
      json = GalaxyTimeline::EventPublisher.build_envelope(
        event: "timeline.turn:completed",
        ledger_session_id: 42_i64,
        session_identifiers: ["abc-123"],
      )

      parsed = JSON.parse(json)
      parsed["ref"]?.should be_nil
    end

    it "handles empty session_identifiers array" do
      json = GalaxyTimeline::EventPublisher.build_envelope(
        event: "timeline.turn:failed",
        ledger_session_id: 42_i64,
        session_identifiers: [] of String,
      )

      parsed = JSON.parse(json)
      parsed["session_identifiers"].as_a.should be_empty
    end

    it "sets ts to current Unix timestamp" do
      before = Time.utc.to_unix
      json = GalaxyTimeline::EventPublisher.build_envelope(
        event: "timeline.turn:completed",
        ledger_session_id: 1_i64,
        session_identifiers: [] of String,
      )
      after = Time.utc.to_unix

      ts = JSON.parse(json)["ts"].as_i64
      ts.should be >= before
      ts.should be <= after
    end
  end

  describe ".send_to_socket" do
    it "returns false for nonexistent socket path" do
      result = GalaxyTimeline::EventPublisher
        .send_to_socket(
          envelope: %({"v":1,"event":"test"}),
          socket_path: "/tmp/galaxy-test-nonexistent" \
                       "-#{Random.rand(100000)}.sock",
        )
      result.should be_false
    end

    it "returns false for a path that is not a socket" do
      temp_file = "/tmp/galaxy-test-not-a-socket" \
                  "-#{Random.rand(100000)}"
      File.write(temp_file, "not a socket")
      begin
        result = GalaxyTimeline::EventPublisher
          .send_to_socket(
            envelope: %({"v":1,"event":"test"}),
            socket_path: temp_file,
          )
        result.should be_false
      ensure
        File.delete(temp_file) if File.exists?(temp_file)
      end
    end
  end

  describe "integration: publish to real socket" do
    it "delivers envelope to a listening socket server" do
      socket_path = "/tmp/galaxy-test-socket" \
                    "-#{Random.rand(100000)}.sock"
      received = Channel(String).new(1)

      server = UNIXServer.new(socket_path)
      spawn do
        client = server.accept
        line = client.gets
        received.send(line || "")
        client.close
        server.close
      end

      begin
        sleep 10.milliseconds

        result = GalaxyTimeline::EventPublisher
          .send_to_socket(
            envelope: %({"v":1,"event":"timeline.turn:completed","ledger_session_id":42}),
            socket_path: socket_path,
          )
        result.should be_true

        line = received.receive
        parsed = JSON.parse(line)
        parsed["v"].as_i.should eq(1)
        parsed["event"].as_s.should eq(
          "timeline.turn:completed",
        )
        parsed["ledger_session_id"].as_i64.should eq(42)
      ensure
        File.delete(socket_path) \
          if File.exists?(socket_path)
      end
    end

    it "handles server that closes immediately" do
      socket_path = "/tmp/galaxy-test-socket" \
                    "-#{Random.rand(100000)}.sock"

      server = UNIXServer.new(socket_path)
      spawn do
        client = server.accept
        client.close
        server.close
      end

      begin
        sleep 10.milliseconds

        GalaxyTimeline::EventPublisher.send_to_socket(
          envelope: %({"v":1,"event":"test"}),
          socket_path: socket_path,
        )
      ensure
        File.delete(socket_path) \
          if File.exists?(socket_path)
      end
    end
  end

  describe "event type propagation" do
    it "publishes event name matching the recorded type" do
      # Record an event via Database — this simulates
      # what handle_record does before calling publish
      id = GalaxyTimeline::Database.record_event(
        1_i64,
        event_type: "turn:completed",
        source: "galaxy-ledger",
      )
      id.should be > 0

      # Verify the event name that would be published
      # follows the timeline.{event_type} pattern
      event_name = "timeline.turn:completed"
      envelope = GalaxyTimeline::EventPublisher
        .build_envelope(
          event: event_name,
          ledger_session_id: 1_i64,
          session_identifiers: ["test-session"],
          ref: id.to_s,
        )

      parsed = JSON.parse(envelope)
      parsed["event"].as_s.should eq(
        "timeline.turn:completed",
      )
      parsed["ref"].as_s.should eq(id.to_s)
    end

    it "propagates different event types correctly" do
      types = [
        "turn:completed",
        "turn:failed",
        "turn:interrupted",
        "turn:continued",
        "artifact:created",
        "snapshot:reviewed",
      ]

      types.each do |event_type|
        envelope = GalaxyTimeline::EventPublisher
          .build_envelope(
            event: "timeline.#{event_type}",
            ledger_session_id: 1_i64,
            session_identifiers: [] of String,
          )

        parsed = JSON.parse(envelope)
        parsed["event"].as_s.should eq(
          "timeline.#{event_type}",
        )
      end
    end
  end
end
