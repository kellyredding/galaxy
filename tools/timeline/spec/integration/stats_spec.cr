require "../spec_helper"

describe "CLI stats command", tags: "integration" do
  it "returns JSON stats for a session" do
    run_binary([
      "record", "--ledger-session-id", "1",
      "--event-type", "session:started",
      "--source", "test",
    ])
    run_binary([
      "record", "--ledger-session-id", "1",
      "--event-type", "context:cleared",
      "--source", "test",
    ])

    result = run_binary(["stats", "--ledger-session-id", "1"])

    result[:status].should eq(0)
    parsed = JSON.parse(result[:output])
    parsed["count"].as_i.should eq(2)
  end

  it "returns zero for empty session" do
    result = run_binary(["stats", "--ledger-session-id", "1"])

    result[:status].should eq(0)
    parsed = JSON.parse(result[:output])
    parsed["count"].as_i.should eq(0)
  end

  it "errors when no session identifier is provided" do
    result = run_binary(["stats"])

    result[:status].should_not eq(0)
    result[:error].should contain("--pid")
  end
end
