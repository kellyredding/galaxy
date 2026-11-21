require "../spec_helper"
require "socket"

alias WatchLines = Array(Galaxy::WatchLine)?

# Stands in for galaxy-watch.sock: each accepted connection runs the next
# script, after recording the subscribe line it was sent.
private class FakeWatchServer
  getter path : String
  getter subscriptions = [] of String

  def initialize(scripts : Array(Proc(UNIXSocket, Nil)))
    @path = "/tmp/gxw-#{Random.rand(1_000_000)}.sock"
    @server = UNIXServer.new(@path)
    server = @server
    subscriptions = @subscriptions
    spawn do
      scripts.each do |script|
        client = server.accept? || break
        subscriptions << (client.gets || "")
        script.call(client) rescue nil
        client.close rescue nil
      end
    end
  end

  def close
    @server.close rescue nil
  end
end

private def ack(id = "abc") : String
  %({"v":1,"subscribed":"#{id}"})
end

private def line(id : Int64?, type : String) : String
  Galaxy::WatchLine.new(id, type, "abc", "2026-11-20T19:39:20Z").to_json
end

private def watch_line(id : Int64, type = "turn:initiated") : Galaxy::WatchLine
  Galaxy::WatchLine.new(id, type, "abc", "2026-11-20T19:39:20Z")
end

private def no_lines : WatchLines
  ([] of Galaxy::WatchLine).as(WatchLines)
end

private def lines_of(io : IO::Memory) : Array(JSON::Any)
  io.to_s.lines.map { |l| JSON.parse(l) }
end

private def client_for(
  server : FakeWatchServer,
  output : IO,
  backfill : Galaxy::WatchClient::Backfill = ->(_c : Int64) { no_lines },
  latest : Galaxy::WatchClient::Latest = -> { 0_i64.as(Int64?) },
  filter : String? = nil,
  stop_on_first = false,
  within : Time::Span = 1.second,
  log : IO = IO::Memory.new,
) : Galaxy::WatchClient
  Galaxy::WatchClient.new(
    "abc", output, Galaxy::EventFilter.new(filter), backfill, latest,
    socket_path: server.path,
    stop_on_first: stop_on_first,
    deadline: Time.monotonic + within,
    sleeper: ->(_s : Time::Span) { sleep(5.milliseconds); nil },
    log: log,
  )
end

describe Galaxy::WatchClient do
  it "subscribes, backfills, then streams, printing each event once" do
    server = FakeWatchServer.new([
      ->(c : UNIXSocket) {
        c.puts ack
        c.puts line(6, "turn:completed") # already backfilled
        c.puts line(7, "turn:initiated")
        c.puts line(nil, "session.idle")
        nil
      },
    ])
    cursors = [] of Int64
    backfill = ->(cursor : Int64) do
      cursors << cursor
      [watch_line(5), watch_line(6, "turn:completed")].as(WatchLines)
    end
    output = IO::Memory.new

    outcome = client_for(server, output, backfill: backfill, within: 300.milliseconds).run(4_i64)

    outcome.should eq(Galaxy::WatchClient::Outcome::TimedOut)
    server.subscriptions.first.should eq(%({"v":1,"subscribe":"abc"}))
    cursors.first.should eq(4)
    lines_of(output).map { |l| l["event_id"].as_i64? }.should eq([5, 6, 7, nil])
  ensure
    server.try(&.close)
  end

  it "reconnects after the connection drops and backfills from the highest id printed" do
    cursors = [] of Int64
    server = FakeWatchServer.new([
      ->(c : UNIXSocket) { c.puts ack; c.puts line(7, "turn:completed"); nil },
      ->(c : UNIXSocket) { c.puts ack; c.puts line(9, "turn:completed"); nil },
    ])
    backfill = ->(cursor : Int64) do
      cursors << cursor
      (cursor == 7 ? [watch_line(8)] : [] of Galaxy::WatchLine).as(WatchLines)
    end
    output = IO::Memory.new

    client_for(server, output, backfill: backfill, within: 400.milliseconds).run(3_i64)

    cursors.first(2).should eq([3, 7])
    lines_of(output).map(&.["event_id"].as_i64).should eq([7, 8, 9])
  ensure
    server.try(&.close)
  end

  it "starts from the newest row when no cursor is given" do
    cursors = [] of Int64
    server = FakeWatchServer.new([->(c : UNIXSocket) { c.puts ack; nil }])
    backfill = ->(cursor : Int64) { cursors << cursor; no_lines }

    client_for(server, IO::Memory.new, backfill: backfill, latest: -> { 40_i64.as(Int64?) }, within: 150.milliseconds).run

    cursors.first.should eq(40)
  ensure
    server.try(&.close)
  end

  it "prints only the types the filter allows" do
    server = FakeWatchServer.new([
      ->(c : UNIXSocket) {
        c.puts ack
        c.puts line(1, "turn:initiated")
        c.puts line(2, "lock:revoked")
        c.puts line(nil, "session.metrics")
        nil
      },
    ])
    output = IO::Memory.new

    client_for(server, output, filter: "lock:*,turn:completed", within: 200.milliseconds).run(0_i64)

    lines_of(output).map(&.["type"].as_s).should eq(["lock:revoked"])
  ensure
    server.try(&.close)
  end

  it "stops at the first matching event when waiting" do
    server = FakeWatchServer.new([
      ->(c : UNIXSocket) {
        c.puts ack
        c.puts line(1, "turn:initiated")
        c.puts line(2, "turn:completed")
        c.puts line(3, "turn:completed")
        sleep 1.second
        nil
      },
    ])
    output = IO::Memory.new

    outcome = client_for(server, output, filter: "turn:completed", stop_on_first: true, within: 2.seconds).run(0_i64)

    outcome.should eq(Galaxy::WatchClient::Outcome::Matched)
    lines_of(output).map(&.["event_id"].as_i64).should eq([2])
  ensure
    server.try(&.close)
  end

  it "times out when nothing matching arrives" do
    server = FakeWatchServer.new([->(c : UNIXSocket) { c.puts ack; sleep 1.second; nil }])

    started = Time.monotonic
    outcome = client_for(server, IO::Memory.new, stop_on_first: true, within: 200.milliseconds).run(0_i64)

    outcome.should eq(Galaxy::WatchClient::Outcome::TimedOut)
    (Time.monotonic - started).should be < 900.milliseconds
  ensure
    server.try(&.close)
  end

  it "fails when Galaxy refuses the subscription" do
    server = FakeWatchServer.new([->(c : UNIXSocket) { c.puts %({"v":1,"error":"no driven session abc"}); nil }])
    log = IO::Memory.new

    outcome = client_for(server, IO::Memory.new, log: log).run(0_i64)

    outcome.should eq(Galaxy::WatchClient::Outcome::Failed)
    log.to_s.should contain("Error: no driven session abc")
  ensure
    server.try(&.close)
  end

  it "keeps retrying while Galaxy is unreachable, saying so once" do
    log = IO::Memory.new
    client = Galaxy::WatchClient.new(
      "abc", IO::Memory.new, Galaxy::EventFilter.new,
      ->(_c : Int64) { nil.as(WatchLines) }, -> { nil.as(Int64?) },
      socket_path: "/tmp/gxw-missing-#{Random.rand(1_000_000)}.sock",
      deadline: Time.monotonic + 150.milliseconds,
      sleeper: ->(_s : Time::Span) { sleep(5.milliseconds); nil },
      log: log,
    )

    client.run.should eq(Galaxy::WatchClient::Outcome::TimedOut)
    log.to_s.lines.size.should eq(1)
    log.to_s.should contain("not reachable")
  end
end
