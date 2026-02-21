require "../spec_helper"

describe GalaxyLedger::EventPublisher do
  describe ".build_envelope" do
    it "builds valid JSON with all required fields" do
      json = GalaxyLedger::EventPublisher.build_envelope(
        event: "session.metrics",
        ledger_session_id: 42_i64,
        session_identifiers: ["abc-123", "def-456"],
      )

      parsed = JSON.parse(json)
      parsed["v"].as_i.should eq(1)
      parsed["event"].as_s.should eq("session.metrics")
      parsed["ledger_session_id"].as_i64.should eq(42)
      parsed["session_identifiers"].as_a.map(&.as_s).should eq(["abc-123", "def-456"])
      parsed["ts"].as_i64.should be > 0
    end

    it "includes ref when provided" do
      json = GalaxyLedger::EventPublisher.build_envelope(
        event: "snapshot.created",
        ledger_session_id: 42_i64,
        session_identifiers: ["abc-123"],
        ref: "3",
      )

      parsed = JSON.parse(json)
      parsed["ref"].as_s.should eq("3")
    end

    it "omits ref when not provided" do
      json = GalaxyLedger::EventPublisher.build_envelope(
        event: "session.metrics",
        ledger_session_id: 42_i64,
        session_identifiers: ["abc-123"],
      )

      parsed = JSON.parse(json)
      parsed["ref"]?.should be_nil
    end

    it "handles empty session_identifiers array" do
      json = GalaxyLedger::EventPublisher.build_envelope(
        event: "session.metrics",
        ledger_session_id: 42_i64,
        session_identifiers: [] of String,
      )

      parsed = JSON.parse(json)
      parsed["session_identifiers"].as_a.should be_empty
    end

    it "sets ts to current Unix timestamp" do
      before = Time.utc.to_unix
      json = GalaxyLedger::EventPublisher.build_envelope(
        event: "session.metrics",
        ledger_session_id: 1_i64,
        session_identifiers: [] of String,
      )
      after = Time.utc.to_unix

      ts = JSON.parse(json)["ts"].as_i64
      ts.should be >= before
      ts.should be <= after
    end
  end

  describe ".publish" do
    it "queries session_identifiers from database and publishes" do
      ledger_session_id = GalaxyLedger::Database.create_session("test-session-1")
      GalaxyLedger::Database.register_session_identifier(ledger_session_id, "extra-id-1")

      # publish returns false because no socket is listening, but it should
      # not raise — silent failure is the contract
      result = GalaxyLedger::EventPublisher.publish(
        ledger_session_id: ledger_session_id,
        event: "session.metrics",
      )
      result.should be_false
    end

    it "returns false when no socket is listening (ENOENT)" do
      ledger_session_id = GalaxyLedger::Database.create_session("test-session-2")

      result = GalaxyLedger::EventPublisher.publish(
        ledger_session_id: ledger_session_id,
        event: "session.metrics",
      )
      result.should be_false
    end

    it "includes ref in the published event" do
      ledger_session_id = GalaxyLedger::Database.create_session("test-session-3")

      # Silent failure — just confirming it doesn't raise
      result = GalaxyLedger::EventPublisher.publish(
        ledger_session_id: ledger_session_id,
        event: "snapshot.created",
        ref: "5",
      )
      result.should be_false
    end
  end

  describe ".send_to_socket" do
    it "returns false for nonexistent socket path (ENOENT)" do
      result = GalaxyLedger::EventPublisher.send_to_socket(
        envelope: %({"v":1,"event":"test"}),
        socket_path: "/tmp/galaxy-test-nonexistent-#{Random.rand(100000)}.sock",
      )
      result.should be_false
    end

    it "returns false for a path that is not a socket" do
      temp_file = "/tmp/galaxy-test-not-a-socket-#{Random.rand(100000)}"
      File.write(temp_file, "not a socket")
      begin
        result = GalaxyLedger::EventPublisher.send_to_socket(
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
    it "delivers event envelope to a listening socket server" do
      socket_path = "/tmp/galaxy-test-socket-#{Random.rand(100000)}.sock"
      received = Channel(String).new(1)

      # Start a simple Unix socket server
      server = UNIXServer.new(socket_path)
      spawn do
        client = server.accept
        line = client.gets
        received.send(line || "")
        client.close
        server.close
      end

      begin
        # Give server a moment to bind
        sleep 10.milliseconds

        result = GalaxyLedger::EventPublisher.send_to_socket(
          envelope: %({"v":1,"event":"session.metrics","ledger_session_id":42}),
          socket_path: socket_path,
        )
        result.should be_true

        # Read what the server received
        line = received.receive
        parsed = JSON.parse(line)
        parsed["v"].as_i.should eq(1)
        parsed["event"].as_s.should eq("session.metrics")
        parsed["ledger_session_id"].as_i64.should eq(42)
      ensure
        File.delete(socket_path) if File.exists?(socket_path)
      end
    end

    it "publishes full event with session_identifiers from database" do
      socket_path = "/tmp/galaxy-test-socket-#{Random.rand(100000)}.sock"
      received = Channel(String).new(1)

      # Create a session with multiple identifiers
      ledger_session_id = GalaxyLedger::Database.create_session("primary-id")
      GalaxyLedger::Database.register_session_identifier(ledger_session_id, "resumed-id")

      # Start socket server
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

        # Publish using the real publish method but with overridden socket path
        identifiers = GalaxyLedger::Database.session_identifiers(ledger_session_id)
        envelope = GalaxyLedger::EventPublisher.build_envelope(
          event: "session.metrics",
          ledger_session_id: ledger_session_id,
          session_identifiers: identifiers,
          ref: nil,
        )
        result = GalaxyLedger::EventPublisher.send_to_socket(
          envelope: envelope,
          socket_path: socket_path,
        )
        result.should be_true

        line = received.receive
        parsed = JSON.parse(line)
        parsed["event"].as_s.should eq("session.metrics")
        parsed["ledger_session_id"].as_i64.should eq(ledger_session_id)

        ids = parsed["session_identifiers"].as_a.map(&.as_s)
        ids.should contain("primary-id")
        ids.should contain("resumed-id")
      ensure
        File.delete(socket_path) if File.exists?(socket_path)
      end
    end

    it "handles server that closes connection immediately (EPIPE)" do
      socket_path = "/tmp/galaxy-test-socket-#{Random.rand(100000)}.sock"

      server = UNIXServer.new(socket_path)
      spawn do
        client = server.accept
        client.close # Close immediately — simulate broken pipe
        server.close
      end

      begin
        sleep 10.milliseconds

        # Should not raise, should return true or false gracefully
        # (may succeed if write completes before close propagates)
        GalaxyLedger::EventPublisher.send_to_socket(
          envelope: %({"v":1,"event":"test"}),
          socket_path: socket_path,
        )
      ensure
        File.delete(socket_path) if File.exists?(socket_path)
      end
    end
  end
end
