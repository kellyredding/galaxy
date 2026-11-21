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

  it "recovers a row whose notification never came, after a later one was printed" do
    cursors = [] of Int64
    server = FakeWatchServer.new([
      # Row 5 is written before row 7, but only 7's notification arrives.
      ->(c : UNIXSocket) { c.puts ack; c.puts line(7, "turn:completed"); nil },
      ->(c : UNIXSocket) { c.puts ack; c.puts line(9, "turn:completed"); nil },
    ])
    backfill = ->(cursor : Int64) do
      cursors << cursor
      (cursors.size == 1 ? [] of Galaxy::WatchLine : [watch_line(5), watch_line(7, "turn:completed")]).as(WatchLines)
    end
    output = IO::Memory.new

    client_for(server, output, backfill: backfill, within: 400.milliseconds).run(3_i64)

    cursors.first(2).should eq([3, 3])
    lines_of(output).map(&.["event_id"].as_i64).should eq([7, 5, 9])
  ensure
    server.try(&.close)
  end

  it "moves its resume point only by what a read returned, skipping late notifications a read covered" do
    cursors = [] of Int64
    server = FakeWatchServer.new([
      ->(c : UNIXSocket) {
        c.puts ack
        c.puts line(2, "turn:initiated") # arrives after the read that covered it
        c.puts line(6, "turn:completed")
        nil
      },
      ->(c : UNIXSocket) { c.puts ack; nil },
    ])
    backfill = ->(cursor : Int64) do
      cursors << cursor
      page = case cursor
             when 0 then [watch_line(2), watch_line(4)]
             when 4 then [watch_line(6, "turn:completed"), watch_line(8)]
             else        [] of Galaxy::WatchLine
             end
      page.as(WatchLines)
    end
    output = IO::Memory.new

    client_for(server, output, backfill: backfill, within: 400.milliseconds).run(0_i64)

    cursors.first(2).should eq([0, 4])
    lines_of(output).map(&.["event_id"].as_i64).should eq([2, 4, 6, 8])
  ensure
    server.try(&.close)
  end

  it "reads from below the first live event when the newest row could not be told" do
    cursors = [] of Int64
    server = FakeWatchServer.new([
      ->(c : UNIXSocket) { c.puts ack; c.puts line(10, "turn:completed"); nil },
      ->(c : UNIXSocket) { c.puts ack; nil },
    ])
    backfill = ->(cursor : Int64) do
      cursors << cursor
      [watch_line(10, "turn:completed"), watch_line(11)].as(WatchLines)
    end
    output = IO::Memory.new

    client_for(server, output, backfill: backfill, latest: -> { nil.as(Int64?) }, within: 300.milliseconds).run

    cursors.first.should eq(9)
    lines_of(output).map(&.["event_id"].as_i64).should eq([10, 11])
  ensure
    server.try(&.close)
  end

  it "waits on the same rule: a reconnect still finds the row whose notification was lost" do
    server = FakeWatchServer.new([
      ->(c : UNIXSocket) { c.puts ack; c.puts line(7, "turn:initiated"); nil },
      ->(c : UNIXSocket) { c.puts ack; sleep 1.second; nil },
    ])
    reads = 0
    backfill = ->(_cursor : Int64) do
      reads += 1
      (reads == 1 ? [] of Galaxy::WatchLine : [watch_line(5, "turn:completed"), watch_line(7)]).as(WatchLines)
    end
    output = IO::Memory.new

    outcome = client_for(server, output, backfill: backfill, filter: "turn:completed", stop_on_first: true, within: 2.seconds).run(3_i64)

    outcome.should eq(Galaxy::WatchClient::Outcome::Matched)
    lines_of(output).map(&.["event_id"].as_i64).should eq([5])
  ensure
    server.try(&.close)
  end

  it "passes through the detail of an event with no row to read" do
    server = FakeWatchServer.new([
      ->(c : UNIXSocket) {
        c.puts ack
        c.puts %({"v":1,"event_id":null,"type":"session.input:failed","session_id":"abc","occurred_at":"x","detail":{"input_id":"lead-7"}})
        nil
      },
    ])
    output = IO::Memory.new

    client_for(server, output, within: 200.milliseconds).run(0_i64)

    lines_of(output).first["detail"]["input_id"].as_s.should eq("lead-7")
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

  it "stops, rather than reconnecting, once its output's reader is gone" do
    server = FakeWatchServer.new([
      ->(c : UNIXSocket) { c.puts ack; c.puts line(1, "turn:completed"); sleep 1.second; nil },
      ->(c : UNIXSocket) { c.puts ack; nil },
    ])
    reader, writer = IO.pipe
    reader.close

    outcome = client_for(server, writer, within: 2.seconds).run(0_i64)

    outcome.should eq(Galaxy::WatchClient::Outcome::OutputClosed)
    server.subscriptions.size.should eq(1)
  ensure
    server.try(&.close)
    writer.try(&.close) rescue nil
  end

  it "retries when the connection closes before Galaxy answers the subscribe" do
    server = FakeWatchServer.new([
      ->(_c : UNIXSocket) { nil },
      ->(c : UNIXSocket) { c.puts ack; c.puts line(3, "turn:completed"); nil },
    ])
    output = IO::Memory.new

    outcome = client_for(server, output, filter: "turn:completed", stop_on_first: true, within: 2.seconds).run(0_i64)

    outcome.should eq(Galaxy::WatchClient::Outcome::Matched)
    server.subscriptions.size.should eq(2)
  ensure
    server.try(&.close)
  end

  it "says so when the backfill cannot be read" do
    server = FakeWatchServer.new([->(c : UNIXSocket) { c.puts ack; nil }])
    log = IO::Memory.new

    client_for(server, IO::Memory.new, backfill: ->(_c : Int64) { nil.as(WatchLines) }, within: 150.milliseconds, log: log).run(7_i64)

    log.to_s.should contain("could not read the timeline after event 7")
  ensure
    server.try(&.close)
  end

  it "pages through a backfill larger than one call returns" do
    cursors = [] of Int64
    server = FakeWatchServer.new([->(c : UNIXSocket) { c.puts ack; nil }])
    backfill = ->(cursor : Int64) do
      cursors << cursor
      page = cursor == 0 ? (1_i64..Galaxy::WatchClient::BACKFILL_PAGE.to_i64).map { |i| watch_line(i) } : [watch_line(cursor + 1)]
      page.as(WatchLines)
    end
    output = IO::Memory.new

    client_for(server, output, backfill: backfill, within: 500.milliseconds).run(0_i64)

    cursors.first(2).should eq([0, Galaxy::WatchClient::BACKFILL_PAGE])
    lines_of(output).size.should eq(Galaxy::WatchClient::BACKFILL_PAGE + 1)
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
