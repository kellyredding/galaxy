require "../spec_helper"

describe Galaxy::WatchLine do
  it "serialises with a null event_id kept, not dropped" do
    line = Galaxy::WatchLine.new(nil, "session.idle", "abc", "2026-11-20T19:39:20Z")
    JSON.parse(line.to_json).as_h.should eq({
      "v"           => JSON::Any.new(1_i64),
      "event_id"    => JSON::Any.new(nil),
      "type"        => JSON::Any.new("session.idle"),
      "session_id"  => JSON::Any.new("abc"),
      "occurred_at" => JSON::Any.new("2026-11-20T19:39:20Z"),
    })
  end

  it "parses a line off the socket, and ignores anything else" do
    raw = %({"v":1,"event_id":171809,"type":"turn:completed","session_id":"abc","occurred_at":"2026-11-20T19:39:20Z"})
    line = Galaxy::WatchLine.parse?(raw).not_nil!
    line.event_id.should eq(171809)
    line.type.should eq("turn:completed")
    Galaxy::WatchLine.parse?("garbage").should be_nil
    Galaxy::WatchLine.parse?(%({"v":1})).should be_nil
  end

  it "builds a line from a timeline row" do
    row = JSON.parse(%({"id":12,"event_type":"lock:revoked","occurred_at":"2026-11-20 19:39:20"}))
    line = Galaxy::WatchLine.from_timeline(row, "abc").not_nil!
    line.event_id.should eq(12)
    line.type.should eq("lock:revoked")
    line.occurred_at.should eq("2026-11-20T19:39:20Z")
  end

  it "leaves a timestamp that is not the stored format alone" do
    Galaxy::WatchLine.iso8601("2026-11-20T19:39:20Z").should eq("2026-11-20T19:39:20Z")
  end
end

describe Galaxy::EventFilter do
  it "matches everything when empty" do
    Galaxy::EventFilter.new(nil).match?("anything").should be_true
    Galaxy::EventFilter.new(" , ").match?("anything").should be_true
  end

  it "matches exact types and trailing-star prefixes" do
    filter = Galaxy::EventFilter.new("turn:completed, lock:*,session.*")
    filter.match?("turn:completed").should be_true
    filter.match?("turn:initiated").should be_false
    filter.match?("lock:revoked").should be_true
    filter.match?("session.idle").should be_true
    filter.match?("session:ended").should be_false
  end
end
