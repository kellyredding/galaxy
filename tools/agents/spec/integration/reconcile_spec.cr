require "../spec_helper"

describe "CLI reconcile command", tags: "integration" do
  before_each do
    ledger = SPEC_LEDGER_DATABASE_PATH.to_s
    File.delete(ledger) if File.exists?(ledger)
  end

  it "sweeps an agent whose owner is gone" do
    gone = dead_pid
    run_binary([
      "start", "--ledger-session-id", "1",
      "--agent-id", "r1", "--agent-type", "Explore",
    ])
    build_ledger_db(
      [{1_i64, gone}],
      [{1_i64, gone, "2026-01-01 00:00:00"}],
    )
    flush_wal

    result = run_binary(["reconcile"])
    result[:status].should eq(0)

    parsed = JSON.parse(result[:output])
    parsed["skipped"].as_bool.should be_false
    parsed["dry_run"].as_bool.should be_false
    parsed["swept"].as_a.size.should eq(1)
    parsed["swept"][0]["agent_id"].as_s.should eq("r1")

    # Counts are read after the sweep, so the session it
    # emptied must not appear at all.
    parsed["running"].as_h.has_key?("1").should be_false

    detail = run_binary([
      "show", "--ledger-session-id", "1",
      "--agent-id", "r1", "--json",
    ])
    JSON.parse(detail[:output])["status"]
      .as_s.should eq("abandoned")
  end

  it "keeps an agent whose owner is a live claude" do
    with_live_process do |pid|
      run_binary([
        "start", "--ledger-session-id", "2",
        "--agent-id", "r2", "--agent-type", "Explore",
      ])
      build_ledger_db(
        [{2_i64, pid}],
        [{2_i64, pid, "2026-01-01 00:00:00"}],
      )
      flush_wal

      # The binary judges liveness by name, so it is told
      # which name this live process actually has.
      result = run_binary(
        ["reconcile"],
        extra_env: {
          "GALAXY_AGENTS_CLAUDE_COMMAND" => SPEC_LIVE_PROCESS_COMMAND,
        },
      )
      parsed = JSON.parse(result[:output])

      parsed["swept"].as_a.should be_empty
      parsed["running"]["2"].as_i.should eq(1)
    end
  end

  it "writes nothing under --dry-run" do
    gone = dead_pid
    run_binary([
      "start", "--ledger-session-id", "3",
      "--agent-id", "r3", "--agent-type", "Explore",
    ])
    build_ledger_db(
      [{3_i64, gone}],
      [{3_i64, gone, "2026-01-01 00:00:00"}],
    )
    flush_wal

    result = run_binary(["reconcile", "--dry-run"])
    parsed = JSON.parse(result[:output])

    parsed["dry_run"].as_bool.should be_true
    parsed["swept"].as_a.size.should eq(1)

    # Reported as sweepable, but still running on disk — and
    # the counts are honestly pre-sweep, which is what dry_run
    # announces.
    parsed["running"]["3"].as_i.should eq(1)

    detail = run_binary([
      "show", "--ledger-session-id", "3",
      "--agent-id", "r3", "--json",
    ])
    JSON.parse(detail[:output])["status"]
      .as_s.should eq("running")
  end

  it "reports being disabled rather than doing nothing" do
    gone = dead_pid
    run_binary([
      "start", "--ledger-session-id", "4",
      "--agent-id", "r4", "--agent-type", "Explore",
    ])
    build_ledger_db(
      [{4_i64, gone}],
      [{4_i64, gone, "2026-01-01 00:00:00"}],
    )
    flush_wal

    result = run_binary(
      ["reconcile"],
      extra_env: {
        "GALAXY_AGENTS_SKIP_RECONCILE" => "1",
      },
    )
    result[:status].should eq(0)

    parsed = JSON.parse(result[:output])
    parsed["skipped"].as_bool.should be_true
    parsed["swept"].as_a.should be_empty

    detail = run_binary([
      "show", "--ledger-session-id", "4",
      "--agent-id", "r4", "--json",
    ])
    JSON.parse(detail[:output])["status"]
      .as_s.should eq("running")
  end

  it "succeeds with nothing to do" do
    build_ledger_db([] of Tuple(Int64, Int64?))

    result = run_binary(["reconcile"])
    result[:status].should eq(0)

    parsed = JSON.parse(result[:output])
    parsed["swept"].as_a.should be_empty
  end

  it "documents itself in its own help" do
    result = run_binary(["reconcile", "--help"])
    result[:status].should eq(0)
    result[:output].should contain("--dry-run")
    result[:output].should contain(
      "GALAXY_AGENTS_SKIP_RECONCILE",
    )
  end

  it "appears in the top-level command list" do
    result = run_binary(["--help"])
    result[:output].should contain("reconcile")
  end

  it "rejects an unknown option" do
    result = run_binary(["reconcile", "--nonsense"])
    result[:status].should eq(1)
    result[:error].should contain("Unknown option")
  end
end
