require "../spec_helper"

describe "CLI stats command", tags: "integration" do
  it "returns JSON stats for a session" do
    source1 = create_test_file("stats-a.csv", "hello")
    source2 = create_test_file("stats-b.csv", "world!!")

    run_binary([
      "save", "--ledger-session-id", "1",
      "--source-path", source1, "--title", "A",
      "--artifact-type", "csv", "--mime-type", "text/csv",
    ])
    run_binary([
      "save", "--ledger-session-id", "1",
      "--source-path", source2, "--title", "B",
      "--artifact-type", "csv", "--mime-type", "text/csv",
    ])

    result = run_binary(["stats", "--ledger-session-id", "1", "--json"])

    result[:status].should eq(0)
    parsed = JSON.parse(result[:output])
    parsed["count"].as_i.should eq(2)
  end

  it "returns zero for empty session" do
    result = run_binary(["stats", "--ledger-session-id", "1", "--json"])

    result[:status].should eq(0)
    parsed = JSON.parse(result[:output])
    parsed["count"].as_i.should eq(0)
  end

  it "accepts --ledger-session-id without --json" do
    source = create_test_file("stats-c.csv", "content")

    run_binary([
      "save", "--ledger-session-id", "1",
      "--source-path", source, "--title", "Stats",
      "--artifact-type", "csv", "--mime-type", "text/csv",
    ])

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
