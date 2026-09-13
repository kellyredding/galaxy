require "./spec_helper"

describe GalaxyFiles::SocketClient do
  describe ".build_envelope" do
    it "carries the identity every Galaxy event carries, and the request" do
      json = GalaxyFiles::SocketClient.build_envelope(
        event: "file_set.open",
        ledger_session_id: 42_i64,
        session_identifiers: ["claude-one"],
        detail: {"name" => JSON::Any.new("auth")},
      )

      parsed = JSON.parse(json)
      parsed["v"].as_i.should eq(1)
      parsed["event"].as_s.should eq("file_set.open")
      parsed["ledger_session_id"].as_i64.should eq(42)
      parsed["session_identifiers"].as_a.map(&.as_s).should eq(["claude-one"])
      parsed["ts"].as_i64.should be > 0
      parsed["detail_data"]["name"].as_s.should eq("auth")
    end
  end

  describe ".request" do
    it "returns the reply line" do
      with_reply_server(%({"ok":true})) do |sock, channel|
        reply = GalaxyFiles::SocketClient.request(%({"v":1}), socket_path: sock)
        reply.should eq(%({"ok":true}))
        channel.receive.should eq(%({"v":1}))
      end
    end

    it "returns nil when nothing is listening" do
      GalaxyFiles::SocketClient.request(
        %({"v":1}),
        socket_path: File.join(Dir.tempdir, "gf-absent-#{Random.rand(1_000_000)}.sock"),
      ).should be_nil
    end
  end
end
