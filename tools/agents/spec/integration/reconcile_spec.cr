require "../spec_helper"

private def agent_transcript(agent_id : String) : String
  (SPEC_CLAUDE_CONFIG_DIR / "projects" / "-Users-someone-projects" /
    "11111111-2222-3333-4444-555555555555" / "subagents" /
    "agent-#{agent_id}.jsonl").to_s
end

# An agent whose turn ended with background work "ci" outstanding.
private def put_waiting(agent_id : String, lsid : Int64)
  run_binary([
    "start", "--ledger-session-id", lsid.to_s,
    "--agent-id", agent_id, "--agent-type", "fork",
  ])
  write_transcript(agent_id, [launch_record("ci")])
  run_binary([
    "stop", "--ledger-session-id", lsid.to_s, "--agent-id", agent_id,
    "--agent-transcript-path", agent_transcript(agent_id),
    "--last-message-stdin",
  ], stdin: "CI is still running")
end

private def reconcile_live(grace : String) : JSON::Any
  JSON.parse(run_binary(
    ["reconcile"],
    extra_env: {
      "GALAXY_AGENTS_CLAUDE_COMMAND"        => SPEC_LIVE_PROCESS_COMMAND,
      "GALAXY_AGENTS_WAITING_GRACE_SECONDS" => grace,
    },
  )[:output])
end

private def show_agent(agent_id : String, lsid : String) : JSON::Any
  JSON.parse(run_binary([
    "show", "--ledger-session-id", lsid, "--agent-id", agent_id, "--json",
  ])[:output])
end

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

  # End to end through the real binary: a declared death closes as
  # failed, carrying its reason and the time it actually died.
  it "closes a declared death as failed, with the reason" do
    with_live_process do |owner|
      run_binary([
        "start", "--ledger-session-id", "8",
        "--agent-id", "e1", "--agent-type", "Explore",
      ])
      build_ledger_db([{8_i64, owner}])
      write_transcript("e1", [error_record])
      flush_wal

      result = run_binary(
        ["reconcile"],
        extra_env: {
          "GALAXY_AGENTS_CLAUDE_COMMAND" => SPEC_LIVE_PROCESS_COMMAND,
        },
      )
      result[:status].should eq(0)

      parsed = JSON.parse(result[:output])
      parsed["failed"].as_a.size.should eq(1)
      parsed["failed"][0]["agent_id"].as_s.should eq("e1")
      parsed["failed"][0]["message"].as_s
        .should contain("Connection lost")
      # Not swept: the owner is alive, so only the transcript
      # could have closed this.
      parsed["swept"].as_a.should be_empty
      parsed["running"].as_h.has_key?("8").should be_false

      detail = JSON.parse(run_binary([
        "show", "--ledger-session-id", "8",
        "--agent-id", "e1", "--json",
      ])[:output])
      detail["status"].as_s.should eq("failed")
      detail["last_message"].as_s.should contain("API Error")
    end
  end

  it "closes a cancellation the parent recorded" do
    with_live_process do |owner|
      run_binary([
        "start", "--ledger-session-id", "20",
        "--agent-id", "c1", "--agent-type", "Explore",
      ])
      build_ledger_db([{20_i64, owner}])
      write_transcript("c1", [clean_record])
      write_parent_transcript([cancel_record("c1")])
      flush_wal

      result = run_binary(
        ["reconcile"],
        extra_env: {
          "GALAXY_AGENTS_CLAUDE_COMMAND" => SPEC_LIVE_PROCESS_COMMAND,
        },
      )
      result[:status].should eq(0)

      parsed = JSON.parse(result[:output])
      parsed["cancelled"].as_a.size.should eq(1)
      parsed["cancelled"][0]["agent_id"].as_s.should eq("c1")
      # The record's own moment, not the sweep's.
      parsed["cancelled"][0]["died_at"].as_s
        .should eq("2026-08-14 21:05:00")
      # Neither other rule fired: the owner is alive and the
      # agent declared no death.
      parsed["failed"].as_a.should be_empty
      parsed["swept"].as_a.should be_empty
      parsed["running"].as_h.has_key?("20").should be_false

      detail = JSON.parse(run_binary([
        "show", "--ledger-session-id", "20",
        "--agent-id", "c1", "--json",
      ])[:output])
      detail["status"].as_s.should eq("canceled")
      detail["completed_at"].as_s
        .should eq("2026-08-14 21:05:00")
      detail["last_message"].as_s
        .should contain("stopped by request")
    end
  end

  it "reports a cancellation under --dry-run without writing" do
    with_live_process do |owner|
      run_binary([
        "start", "--ledger-session-id", "21",
        "--agent-id", "c2", "--agent-type", "Explore",
      ])
      build_ledger_db([{21_i64, owner}])
      write_transcript("c2", [clean_record])
      write_parent_transcript([cancel_record("c2")])
      flush_wal

      result = run_binary(
        ["reconcile", "--dry-run"],
        extra_env: {
          "GALAXY_AGENTS_CLAUDE_COMMAND" => SPEC_LIVE_PROCESS_COMMAND,
        },
      )
      parsed = JSON.parse(result[:output])
      parsed["cancelled"].as_a.size.should eq(1)
      # Still counted as running, because nothing was written.
      parsed["running"]["21"].as_i.should eq(1)

      detail = JSON.parse(run_binary([
        "show", "--ledger-session-id", "21",
        "--agent-id", "c2", "--json",
      ])[:output])
      detail["status"].as_s.should eq("running")
    end
  end

  # A cancellation naming a sibling must not take this row with
  # it — the marker is matched against one agent id.
  it "leaves an agent alone when a sibling was cancelled" do
    with_live_process do |owner|
      run_binary([
        "start", "--ledger-session-id", "22",
        "--agent-id", "keep-me", "--agent-type", "Explore",
      ])
      build_ledger_db([{22_i64, owner}])
      write_transcript("keep-me", [clean_record])
      write_parent_transcript([cancel_record("some-other")])
      flush_wal

      result = run_binary(
        ["reconcile"],
        extra_env: {
          "GALAXY_AGENTS_CLAUDE_COMMAND" => SPEC_LIVE_PROCESS_COMMAND,
        },
      )
      parsed = JSON.parse(result[:output])
      parsed["cancelled"].as_a.should be_empty
      parsed["running"]["22"].as_i.should eq(1)
    end
  end

  # Both signals present. The death the agent wrote about itself
  # wins, because it can say why.
  it "prefers a declared death over a cancellation" do
    with_live_process do |owner|
      run_binary([
        "start", "--ledger-session-id", "23",
        "--agent-id", "b1", "--agent-type", "Explore",
      ])
      build_ledger_db([{23_i64, owner}])
      write_transcript("b1", [error_record])
      write_parent_transcript([cancel_record("b1")])
      flush_wal

      result = run_binary(
        ["reconcile"],
        extra_env: {
          "GALAXY_AGENTS_CLAUDE_COMMAND" => SPEC_LIVE_PROCESS_COMMAND,
        },
      )
      parsed = JSON.parse(result[:output])
      parsed["failed"].as_a.size.should eq(1)
      parsed["cancelled"].as_a.should be_empty

      detail = JSON.parse(run_binary([
        "show", "--ledger-session-id", "23",
        "--agent-id", "b1", "--json",
      ])[:output])
      detail["status"].as_s.should eq("failed")
    end
  end

  # A cancelled agent whose owner also died: the cancellation is
  # the better answer, since it knows when and the sweep does
  # not.
  it "prefers a cancellation over sweeping a dead owner" do
    run_binary([
      "start", "--ledger-session-id", "24",
      "--agent-id", "c3", "--agent-type", "Explore",
    ])
    build_ledger_db([{24_i64, dead_pid}])
    write_transcript("c3", [clean_record])
    write_parent_transcript([cancel_record("c3")])
    flush_wal

    result = run_binary(["reconcile"])
    parsed = JSON.parse(result[:output])
    parsed["cancelled"].as_a.size.should eq(1)
    parsed["swept"].as_a.should be_empty

    detail = JSON.parse(run_binary([
      "show", "--ledger-session-id", "24",
      "--agent-id", "c3", "--json",
    ])[:output])
    detail["status"].as_s.should eq("canceled")
  end

  it "leaves a healthy agent alone under --dry-run and for real" do
    with_live_process do |owner|
      run_binary([
        "start", "--ledger-session-id", "9",
        "--agent-id", "h1", "--agent-type", "Explore",
      ])
      build_ledger_db([{9_i64, owner}])
      write_transcript("h1", [clean_record])
      flush_wal

      result = run_binary(
        ["reconcile"],
        extra_env: {
          "GALAXY_AGENTS_CLAUDE_COMMAND" => SPEC_LIVE_PROCESS_COMMAND,
        },
      )
      parsed = JSON.parse(result[:output])
      parsed["failed"].as_a.should be_empty
      parsed["swept"].as_a.should be_empty
      parsed["running"]["9"].as_i.should eq(1)
    end
  end

  describe "an agent waiting on its background work" do
    before_each do
      FileUtils.rm_rf((SPEC_CLAUDE_CONFIG_DIR / "projects").to_s)
    end

    it "is finished once the work reported back and the agent stayed quiet" do
      with_live_process do |owner|
        put_waiting("wf1", 30_i64)
        build_ledger_db([{30_i64, owner}])
        write_parent_transcript([notification_record("ci")])
        flush_wal
        paused_at = show_agent("wf1", "30")["completed_at"].as_s
        sleep 1.1.seconds

        parsed = reconcile_live(grace: "0")
        parsed["finished"].as_a.map(&.["agent_id"].as_s).should eq(["wf1"])
        parsed["running"].as_h.has_key?("30").should be_false

        detail = show_agent("wf1", "30")
        detail["status"].as_s.should eq("stopped")
        # Timed from the pause, not from the sweep a second later.
        detail["completed_at"].as_s.should eq(paused_at)
      end
    end

    it "keeps waiting while the work is outstanding" do
      with_live_process do |owner|
        put_waiting("wf2", 31_i64)
        build_ledger_db([{31_i64, owner}])
        flush_wal

        parsed = reconcile_live(grace: "0")
        parsed["finished"].as_a.should be_empty
        parsed["running"]["31"].as_i.should eq(1)
        show_agent("wf2", "31")["status"].as_s.should eq("waiting")
      end
    end

    it "keeps waiting while a just-woken agent may still be starting" do
      with_live_process do |owner|
        put_waiting("wf3", 32_i64)
        build_ledger_db([{32_i64, owner}])
        File.write(agent_transcript("wf3"), notification_record("ci") + "\n", mode: "a")
        flush_wal

        parsed = reconcile_live(grace: "30")
        parsed["finished"].as_a.should be_empty
        show_agent("wf3", "32")["status"].as_s.should eq("waiting")
      end
    end

    it "is finished once it has waited longer than anything should" do
      with_live_process do |owner|
        put_waiting("wf5", 34_i64)
        build_ledger_db([{34_i64, owner}])
        flush_wal
        sleep 1.1.seconds

        parsed = JSON.parse(run_binary(
          ["reconcile"],
          extra_env: {
            "GALAXY_AGENTS_CLAUDE_COMMAND"   => SPEC_LIVE_PROCESS_COMMAND,
            "GALAXY_AGENTS_MAX_WAIT_SECONDS" => "1",
          },
        )[:output])
        parsed["finished"].as_a.map(&.["agent_id"].as_s).should eq(["wf5"])
        show_agent("wf5", "34")["status"].as_s.should eq("stopped")
      end
    end

    it "is swept when its owner is gone" do
      put_waiting("wf4", 33_i64)
      build_ledger_db([{33_i64, dead_pid}])
      flush_wal

      parsed = JSON.parse(run_binary(["reconcile"])[:output])
      parsed["swept"].as_a.map(&.["agent_id"].as_s).should eq(["wf4"])
      show_agent("wf4", "33")["status"].as_s.should eq("abandoned")
    end
  end

  it "reports a declared death under --dry-run without writing" do
    with_live_process do |owner|
      run_binary([
        "start", "--ledger-session-id", "10",
        "--agent-id", "d1", "--agent-type", "Explore",
      ])
      build_ledger_db([{10_i64, owner}])
      write_transcript("d1", [error_record])
      flush_wal

      parsed = JSON.parse(run_binary(
        ["reconcile", "--dry-run"],
        extra_env: {
          "GALAXY_AGENTS_CLAUDE_COMMAND" => SPEC_LIVE_PROCESS_COMMAND,
        },
      )[:output])
      parsed["failed"].as_a.size.should eq(1)

      detail = JSON.parse(run_binary([
        "show", "--ledger-session-id", "10",
        "--agent-id", "d1", "--json",
      ])[:output])
      detail["status"].as_s.should eq("running")
    end
  end
end
