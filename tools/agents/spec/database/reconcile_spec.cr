require "../spec_helper"

# Reconcile decides one thing: is the process that owned this
# agent still alive? Every example here is a different way of
# answering that, because every wrong answer is expensive —
# a false sweep marks a live agent abandoned permanently, and a
# missed sweep leaves the count inflated until the session is
# dismissed.
describe "reconcile" do
  before_each do
    db_path = GalaxyAgents::Database.database_path
    File.delete(db_path) if File.exists?(db_path)

    ledger = SPEC_LEDGER_DATABASE_PATH.to_s
    File.delete(ledger) if File.exists?(ledger)
  end

  describe GalaxyAgents::ProcessLiveness do
    it "reads a live process as alive" do
      with_live_process do |pid|
        GalaxyAgents::ProcessLiveness
          .exists?(pid).should be_true
      end
    end

    it "reads a reaped pid as gone" do
      GalaxyAgents::ProcessLiveness
        .exists?(dead_pid).should be_false
    end

    # A process we may not signal is still a process. Reading
    # EPERM as death would sweep agents owned by another user.
    it "counts an unsignallable process as existing" do
      GalaxyAgents::ProcessLiveness
        .exists?(1_i64).should be_true
    end

    it "reads the command name of a live process" do
      with_live_process do |pid|
        GalaxyAgents::ProcessLiveness
          .command_name(pid)
          .should eq(SPEC_LIVE_PROCESS_COMMAND)
      end
    end

    it "accepts a live process with the expected name" do
      with_live_process do |pid|
        GalaxyAgents::ProcessLiveness.claude_alive?(
          pid, expected: SPEC_LIVE_PROCESS_COMMAND).should be_true
      end
    end

    # The pid is live, but it belongs to something else — the
    # OS recycled the number after the session exited. This is
    # the same live process as the example above, judged against
    # a different name, so the refusal can only come from the
    # name check itself.
    it "refuses a live pid held by another command" do
      with_live_process do |pid|
        GalaxyAgents::ProcessLiveness.claude_alive?(
          pid, expected: "claude").should be_false
      end
    end

    it "refuses a live pid running some unrelated command" do
      GalaxyAgents::ProcessLiveness
        .claude_alive?(1_i64, expected: "claude")
        .should be_false
    end

    # Names are only readable while the process is. A reaped pid
    # short-circuits at the existence check, which is why the
    # unreadable-name fallback never sees it.
    it "cannot read a name for a reaped pid" do
      GalaxyAgents::ProcessLiveness
        .command_name(dead_pid).should be_nil
    end

    it "honours the command-name override" do
      with_live_process do |pid|
        ENV["GALAXY_AGENTS_CLAUDE_COMMAND"] =
          SPEC_LIVE_PROCESS_COMMAND
        begin
          GalaxyAgents::ProcessLiveness
            .claude_alive?(pid).should be_true
        ensure
          ENV.delete("GALAXY_AGENTS_CLAUDE_COMMAND")
        end
      end
    end

    it "treats a nil or non-positive pid as gone" do
      GalaxyAgents::ProcessLiveness
        .claude_alive?(nil).should be_false
      GalaxyAgents::ProcessLiveness
        .claude_alive?(0_i64).should be_false
    end
  end

  describe ".running_with_owner_pids" do
    it "resolves the pid registered at agent start" do
      GalaxyAgents::Database.start_agent(
        1_i64, "agent-a", "Explore",
      )
      build_ledger_db(
        [{1_i64, 4242_i64}],
        [{1_i64, 4242_i64, "2026-01-01 00:00:00"}],
      )

      rows = GalaxyAgents::Database
        .running_with_owner_pids
      rows.size.should eq(1)
      rows[0].agent_id.should eq("agent-a")
      rows[0].owner_pid.should eq(4242_i64)
    end

    # The regression that matters most. 87% of recorded agents
    # belong to sessions resumed since they started. Judging by
    # the session's CURRENT pid checks a process that never ran
    # the agent — and when that newer process is alive, the
    # stranded row is kept forever.
    it "ignores a newer pid registered after the agent" do
      GalaxyAgents::Database.start_agent(
        1_i64, "agent-a", "Explore",
      )
      GalaxyAgents::Database.open do |db|
        db.exec(
          "UPDATE agents SET started_at = ? " \
          "WHERE agent_id = ?",
          "2026-01-01 12:00:00", "agent-a",
        )
      end

      build_ledger_db(
        [{1_i64, 9999_i64}],
        [
          {1_i64, 1111_i64, "2026-01-01 09:00:00"},
          {1_i64, 9999_i64, "2026-01-01 18:00:00"},
        ],
      )

      rows = GalaxyAgents::Database
        .running_with_owner_pids
      rows.size.should eq(1)
      rows[0].owner_pid.should eq(1111_i64)
    end

    it "falls back to the current pid with no history" do
      GalaxyAgents::Database.start_agent(
        1_i64, "agent-a", "Explore",
      )
      build_ledger_db([{1_i64, 7777_i64}])

      rows = GalaxyAgents::Database
        .running_with_owner_pids
      rows[0].owner_pid.should eq(7777_i64)
    end

    it "yields a nil owner when the session is unknown" do
      GalaxyAgents::Database.start_agent(
        42_i64, "agent-a", "Explore",
      )
      build_ledger_db([] of Tuple(Int64, Int64?))

      rows = GalaxyAgents::Database
        .running_with_owner_pids
      rows.size.should eq(1)
      rows[0].owner_pid.should be_nil
    end

    it "ignores rows that already reached a terminal state" do
      GalaxyAgents::Database.start_agent(
        1_i64, "agent-a", "Explore",
      )
      GalaxyAgents::Database.stop_agent(
        1_i64, "agent-a", "stopped",
        last_message: "done",
      )
      build_ledger_db([{1_i64, 4242_i64}])

      GalaxyAgents::Database
        .running_with_owner_pids.should be_empty
    end
  end

  describe ".running_counts_by_session" do
    it "counts only running rows, keyed by session" do
      GalaxyAgents::Database.start_agent(
        1_i64, "a1", "Explore",
      )
      GalaxyAgents::Database.start_agent(
        1_i64, "a2", "Explore",
      )
      GalaxyAgents::Database.start_agent(
        2_i64, "b1", "Explore",
      )
      GalaxyAgents::Database.stop_agent(
        2_i64, "b1", "stopped", last_message: "done")

      counts = GalaxyAgents::Database
        .running_counts_by_session
      counts[1_i64].should eq(2)
      counts.has_key?(2_i64).should be_false
    end
  end

  # End-to-end: the decision reconcile actually makes, over the
  # same query and liveness check the CLI uses.
  describe "sweep decisions" do
    it "keeps an agent whose owner is a live claude" do
      with_live_process do |pid|
        GalaxyAgents::Database.start_agent(
          1_i64, "agent-a", "Explore",
        )
        build_ledger_db(
          [{1_i64, pid}],
          [{1_i64, pid, "2026-01-01 00:00:00"}],
        )

        sweepable = GalaxyAgents::Database
          .running_with_owner_pids
          .reject do |row|
            GalaxyAgents::ProcessLiveness.claude_alive?(
              row.owner_pid,
              expected: SPEC_LIVE_PROCESS_COMMAND,
            )
          end

        sweepable.should be_empty
      end
    end

    it "sweeps an agent whose owner exited" do
      gone = dead_pid
      GalaxyAgents::Database.start_agent(
        1_i64, "agent-a", "Explore",
      )
      build_ledger_db(
        [{1_i64, gone}],
        [{1_i64, gone, "2026-01-01 00:00:00"}],
      )

      sweepable = GalaxyAgents::Database
        .running_with_owner_pids
        .reject do |row|
          GalaxyAgents::ProcessLiveness
            .claude_alive?(row.owner_pid)
        end

      sweepable.size.should eq(1)
      sweepable[0].agent_id.should eq("agent-a")
    end

    # The resume case, end to end: the agent's own process is
    # gone, the session has since come back under a live pid,
    # and the row must still be swept.
    it "sweeps despite a live pid registered later" do
      with_live_process do |live|
        gone = dead_pid
        GalaxyAgents::Database.start_agent(
          1_i64, "agent-a", "Explore",
        )
        GalaxyAgents::Database.open do |db|
          db.exec(
            "UPDATE agents SET started_at = ? " \
            "WHERE agent_id = ?",
            "2026-01-01 12:00:00", "agent-a",
          )
        end
        build_ledger_db(
          [{1_i64, live}],
          [
            {1_i64, gone, "2026-01-01 09:00:00"},
            {1_i64, live, "2026-01-01 18:00:00"},
          ],
        )

        sweepable = GalaxyAgents::Database
          .running_with_owner_pids
          .reject do |row|
            GalaxyAgents::ProcessLiveness.claude_alive?(
              row.owner_pid,
              expected: SPEC_LIVE_PROCESS_COMMAND,
            )
          end

        sweepable.size.should eq(1)
      end
    end

    it "abandons a swept row through the shared write" do
      gone = dead_pid
      GalaxyAgents::Database.start_agent(
        1_i64, "agent-a", "Explore",
      )
      build_ledger_db(
        [{1_i64, gone}],
        [{1_i64, gone, "2026-01-01 00:00:00"}],
      )

      GalaxyAgents::Database.abandon_agent(
        1_i64, "agent-a",
      ).should_not be_nil

      agent = GalaxyAgents::Database.get_agent(
        1_i64, "agent-a",
      ).not_nil!
      agent.status.should eq("abandoned")

      GalaxyAgents::Database
        .running_counts_by_session
        .has_key?(1_i64).should be_false
    end
  end
end
