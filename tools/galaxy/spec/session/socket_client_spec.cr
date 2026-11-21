require "../spec_helper"
require "socket"

private def serving(&script : UNIXSocket ->) : {UNIXServer, String}
  path = "/tmp/gxs-#{Random.rand(1_000_000)}.sock"
  server = UNIXServer.new(path)
  spawn do
    if client = server.accept?
      client.gets
      script.call(client) rescue nil
      client.close rescue nil
    end
  end
  {server, path}
end

private def detail : Hash(String, JSON::Any)
  {"id" => JSON::Any.new("abc")}
end

describe Galaxy::SocketClient do
  it "returns the reply object" do
    server, path = serving { |c| c.puts %({"ok":true,"id":"abc"}) }
    Galaxy::SocketClient.request("session.status", detail, path: path)["id"].as_s.should eq("abc")
  ensure
    server.try(&.close)
  end

  it "tells nothing listening apart from a slow answer and a missing one" do
    expect_raises(Galaxy::SocketClient::NotRunning) do
      Galaxy::SocketClient.request("session.status", detail, path: "/tmp/gxs-missing-#{Random.rand(1_000_000)}.sock")
    end

    slow, slow_path = serving { |_c| sleep 1.second }
    expect_raises(Galaxy::SocketClient::TimedOut) do
      Galaxy::SocketClient.request("session.send", detail, read_timeout: 100.milliseconds, path: slow_path)
    end

    silent, silent_path = serving { |_c| nil }
    expect_raises(Galaxy::SocketClient::NoReply) do
      Galaxy::SocketClient.request("session.status", detail, path: silent_path)
    end
  ensure
    slow.try(&.close)
    silent.try(&.close)
  end

  it "answers nil from request? whenever Galaxy did not answer" do
    Galaxy::SocketClient.request?("session.status", detail, path: "/tmp/gxs-missing-#{Random.rand(1_000_000)}.sock").should be_nil
  end
end
