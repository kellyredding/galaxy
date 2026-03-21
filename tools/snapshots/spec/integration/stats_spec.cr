require "../spec_helper"

describe "CLI stats command", tags: "integration" do
  it "returns JSON stats for a session" do
    GalaxySnapshots::Database.save_snapshot(1_i64, "A", "hello")
    GalaxySnapshots::Database.save_snapshot(1_i64, "B", "world!!")
    flush_wal

    result = run_binary(["stats", "--ledger-session-id", "1", "--json"])

    result[:status].should eq(0)
    parsed = JSON.parse(result[:output])
    parsed["count"].as_i.should eq(2)
    parsed["total_chars"].as_i.should eq(12)
  end

  it "returns zeros for empty session" do
    result = run_binary(["stats", "--ledger-session-id", "1", "--json"])

    result[:status].should eq(0)
    parsed = JSON.parse(result[:output])
    parsed["count"].as_i.should eq(0)
    parsed["total_chars"].as_i.should eq(0)
  end

  it "accepts --ledger-session-id without --json" do
    GalaxySnapshots::Database.save_snapshot(1_i64, "Stats", "content")
    flush_wal

    result = run_binary(["stats", "--ledger-session-id", "1"])

    result[:status].should eq(0)
    parsed = JSON.parse(result[:output])
    parsed["count"].as_i.should eq(1)
  end

  it "errors when no session identifier is provided" do
    result = run_binary(["stats"])

    result[:status].should_not eq(0)
    result[:error].should contain("--pid")
  end
end
