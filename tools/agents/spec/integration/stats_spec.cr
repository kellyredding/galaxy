require "../spec_helper"

describe "CLI stats command", tags: "integration" do
  it "returns JSON stats for a session" do
    run_binary([
      "start", "--ledger-session-id", "1",
      "--agent-id", "s1", "--agent-type", "Explore",
    ])
    run_binary([
      "start", "--ledger-session-id", "1",
      "--agent-id", "s2", "--agent-type", "Explore",
    ])
    run_binary(
      [
        "stop", "--ledger-session-id", "1",
        "--agent-id", "s2", "--last-message-stdin",
      ],
      stdin: "done",
    )

    result = run_binary([
      "stats", "--ledger-session-id", "1", "--json",
    ])

    result[:status].should eq(0)
    parsed = JSON.parse(result[:output])
    parsed["total"].as_i.should eq(2)
    parsed["running"].as_i.should eq(1)
    parsed["stopped"].as_i.should eq(1)
    parsed["failed"].as_i.should eq(0)
  end

  it "returns zeroes for empty session" do
    result = run_binary([
      "stats", "--ledger-session-id", "1", "--json",
    ])

    result[:status].should eq(0)
    parsed = JSON.parse(result[:output])
    parsed["total"].as_i.should eq(0)
    parsed["running"].as_i.should eq(0)
  end

  it "errors when no session identifier provided" do
    result = run_binary(["stats"])

    result[:status].should_not eq(0)
    result[:error].should contain("--pid")
  end
end
