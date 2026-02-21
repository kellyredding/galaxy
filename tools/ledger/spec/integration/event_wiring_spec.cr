require "../spec_helper"

describe "CLI Integration: event wiring" do
  describe "update-session-metrics publishes session.metrics event" do
    it "fires session.metrics event on the socket after updating metrics" do
      socket_path = SPEC_GALAXY_DIR / "galaxy.sock"
      received = Channel(String).new(1)

      # Start a socket server to capture the event
      server = UNIXServer.new(socket_path.to_s)
      spawn do
        client = server.accept
        line = client.gets
        received.send(line || "")
        client.close
        server.close
      end

      begin
        sleep 10.milliseconds

        session_id = "wiring-test-#{Random.rand(100000)}"
        GalaxyLedger::Database.create_session(session_id)

        metrics_json = {
          "session_id" => session_id,
          "context"    => {
            "percentage"  => 72.5,
            "tokens_used" => 145000,
            "tokens_max"  => 200000,
          },
          "cost" => {
            "usd" => 0.42,
          },
        }.to_json

        result = run_binary(
          ["update-session-metrics", "--session", session_id],
          stdin: metrics_json,
        )
        result[:status].should eq(0)

        # Read the event that was published
        select
        when line = received.receive
          parsed = JSON.parse(line)
          parsed["v"].as_i.should eq(1)
          parsed["event"].as_s.should eq("session.metrics")
          parsed["session_identifiers"].as_a.map(&.as_s).should contain(session_id)
          parsed["ts"].as_i64.should be > 0
        when timeout(3.seconds)
          fail "Timed out waiting for session.metrics event on socket"
        end
      ensure
        File.delete(socket_path.to_s) if File.exists?(socket_path.to_s)
      end
    end

    it "still succeeds when no socket is listening (no event wiring failure)" do
      session_id = "wiring-nosock-#{Random.rand(100000)}"
      GalaxyLedger::Database.create_session(session_id)

      metrics_json = {
        "session_id" => session_id,
        "context"    => {
          "percentage" => 30.0,
        },
      }.to_json

      result = run_binary(
        ["update-session-metrics", "--session", session_id],
        stdin: metrics_json,
      )
      result[:status].should eq(0)
    end
  end
end
