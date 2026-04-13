require "./spec_helper"

describe GalaxyArtifacts::EventPublisher do
  describe ".build_envelope" do
    it "builds valid JSON with all required fields" do
      json = GalaxyArtifacts::EventPublisher
        .build_envelope(
          event: "artifact.show",
          ledger_session_id: 42_i64,
          session_identifiers: [
            "abc-123", "def-456",
          ],
        )

      parsed = JSON.parse(json)
      parsed["v"].as_i.should eq(1)
      parsed["event"].as_s.should eq(
        "artifact.show",
      )
      parsed["ledger_session_id"].as_i64.should eq(42)
      parsed["session_identifiers"].as_a
        .map(&.as_s).should eq(
        ["abc-123", "def-456"],
      )
      parsed["ts"].as_i64.should be > 0
    end

    it "includes ref when provided" do
      json = GalaxyArtifacts::EventPublisher
        .build_envelope(
          event: "artifact.show",
          ledger_session_id: 42_i64,
          session_identifiers: ["abc-123"],
          ref: "3",
        )

      parsed = JSON.parse(json)
      parsed["ref"].as_s.should eq("3")
    end

    it "omits ref when not provided" do
      json = GalaxyArtifacts::EventPublisher
        .build_envelope(
          event: "artifact.show",
          ledger_session_id: 42_i64,
          session_identifiers: ["abc-123"],
        )

      parsed = JSON.parse(json)
      parsed["ref"]?.should be_nil
    end

    it "includes detail_data as parsed JSON" do
      dd = %({"artifact_number":3})
      json = GalaxyArtifacts::EventPublisher
        .build_envelope(
          event: "artifact.show",
          ledger_session_id: 42_i64,
          session_identifiers: ["abc-123"],
          detail_data: dd,
        )

      parsed = JSON.parse(json)
      detail = parsed["detail_data"]
      detail["artifact_number"].as_i.should eq(3)
    end

    it "omits detail_data when not provided" do
      json = GalaxyArtifacts::EventPublisher
        .build_envelope(
          event: "artifact.show",
          ledger_session_id: 42_i64,
          session_identifiers: ["abc-123"],
        )

      parsed = JSON.parse(json)
      parsed["detail_data"]?.should be_nil
    end

    it "handles empty session_identifiers array" do
      json = GalaxyArtifacts::EventPublisher
        .build_envelope(
          event: "artifact.show",
          ledger_session_id: 42_i64,
          session_identifiers: [] of String,
        )

      parsed = JSON.parse(json)
      parsed["session_identifiers"].as_a
        .should be_empty
    end

    it "sets ts to current Unix timestamp" do
      before = Time.utc.to_unix
      json = GalaxyArtifacts::EventPublisher
        .build_envelope(
          event: "artifact.show",
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
      result = GalaxyArtifacts::EventPublisher
        .send_to_socket(
          envelope: %({"v":1,"event":"test"}),
          socket_path: "/tmp/galaxy-test-nonexistent" \
                       "-#{Random.rand(100000)}.sock",
        )
      result.should be_false
    end

    it "returns false for a path that is not a socket" do
      temp_file =
        "/tmp/galaxy-test-not-a-socket" \
        "-#{Random.rand(100000)}"
      File.write(temp_file, "not a socket")
      begin
        result = GalaxyArtifacts::EventPublisher
          .send_to_socket(
            envelope: %({"v":1,"event":"test"}),
            socket_path: temp_file,
          )
        result.should be_false
      ensure
        File.delete(temp_file) \
          if File.exists?(temp_file)
      end
    end
  end

  describe "integration: publish to real socket" do
    it "delivers envelope to a listening socket" do
      socket_path =
        "/tmp/galaxy-test-socket" \
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

        result = GalaxyArtifacts::EventPublisher
          .send_to_socket(
            envelope: %({"v":1,"event":"artifact.show","ledger_session_id":42}),
            socket_path: socket_path,
          )
        result.should be_true

        line = received.receive
        parsed = JSON.parse(line)
        parsed["v"].as_i.should eq(1)
        parsed["event"].as_s.should eq(
          "artifact.show",
        )
        parsed["ledger_session_id"].as_i64
          .should eq(42)
      ensure
        File.delete(socket_path) \
          if File.exists?(socket_path)
      end
    end

    it "handles server that closes immediately" do
      socket_path =
        "/tmp/galaxy-test-socket" \
        "-#{Random.rand(100000)}.sock"

      server = UNIXServer.new(socket_path)
      spawn do
        client = server.accept
        client.close
        server.close
      end

      begin
        sleep 10.milliseconds

        GalaxyArtifacts::EventPublisher
          .send_to_socket(
            envelope: %({"v":1,"event":"test"}),
            socket_path: socket_path,
          )
      ensure
        File.delete(socket_path) \
          if File.exists?(socket_path)
      end
    end
  end
end
