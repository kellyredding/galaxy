require "../spec_helper"

# Reconcile decides one thing: is the process that owns this agent still
# alive? Every example here is a different way of answering that, because the
# two wrong answers cost very differently. A missed sweep leaves a count too
# high, which the next sweep or a manual abandon still fixes. A false sweep
# marks a live agent abandoned, and `stop_agent` will not move a terminal row
# back — the agent finishes and is recorded as abandoned forever.
#
# So every example below biases the same way: when ownership cannot be
# established, the row is kept.
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

    # The pid is live, but it belongs to something else — the OS
    # recycled the number after the session exited. Same live
    # process as the example above, judged against a different
    # name, so the refusal can only come from the name check.
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
    it "resolves the session's current pid" do
      GalaxyAgents::Database.start_agent(
        1_i64, "agent-a", "Explore",
      )
      build_ledger_db([{1_i64, 4242_i64}])

      rows = GalaxyAgents::Database
        .running_with_owner_pids
      rows.size.should eq(1)
      rows[0].agent_id.should eq("agent-a")
      rows[0].owner_pid.should eq(4242_i64)
    end

    # THE REGRESSION. An earlier version resolved ownership from
    # `ledger_session_pids`, taking the registration nearest the
    # agent's start, on the theory that a resumed session would
    # otherwise be judged by a newer process than the one that ran
    # the agent.
    #
    # That table is not a handover log. It accumulates every pid
    # that ever resolved to the session, including the short-lived
    # ones behind hook invocations — a real session held fifteen,
    # arriving in bursts twenty seconds apart, every one dead while
    # the session ran on under a pid registered long before them.
    # Judging by the newest registration therefore picked a corpse
    # and swept a live agent forty-three seconds into its run.
    #
    # Ownership comes from `current_claude_pid` and nothing else.
    it "keeps an owner alive behind later dead registrations" do
      with_live_process do |owner|
        gone_a = dead_pid
        gone_b = dead_pid

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

        # The owner registered first, then ephemeral hook pids
        # registered and died — all BEFORE the agent started.
        # That ordering is the trap: the newest registration at or
        # before `started_at` is a corpse, while the owner that is
        # actually running the agent registered earlier still.
        build_ledger_db(
          [{1_i64, owner}],
          [
            {1_i64, owner, "2026-01-01 09:00:00"},
            {1_i64, gone_a, "2026-01-01 10:00:00"},
            {1_i64, gone_b, "2026-01-01 10:00:20"},
          ],
        )

        rows = GalaxyAgents::Database
          .running_with_owner_pids
        rows[0].owner_pid.should eq(owner)

        sweepable = rows.reject do |row|
          GalaxyAgents::ProcessLiveness.claude_alive?(
            row.owner_pid,
            expected: SPEC_LIVE_PROCESS_COMMAND,
          )
        end
        sweepable.should be_empty
      end
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
        build_ledger_db([{1_i64, pid}])

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
      build_ledger_db([{1_i64, gone}])

      sweepable = GalaxyAgents::Database
        .running_with_owner_pids
        .reject do |row|
          GalaxyAgents::ProcessLiveness
            .claude_alive?(row.owner_pid)
        end

      sweepable.size.should eq(1)
      sweepable[0].agent_id.should eq("agent-a")
    end

    it "sweeps an agent whose session left no ledger row" do
      GalaxyAgents::Database.start_agent(
        7_i64, "agent-a", "Explore",
      )
      build_ledger_db([] of Tuple(Int64, Int64?))

      sweepable = GalaxyAgents::Database
        .running_with_owner_pids
        .reject do |row|
          GalaxyAgents::ProcessLiveness
            .claude_alive?(row.owner_pid)
        end

      sweepable.size.should eq(1)
    end

    # The case ownership structurally cannot see. The session is
    # alive and healthy — only the agent died, and the only place
    # that fact exists is the agent's own transcript.
    it "closes a declared death though the owner is alive" do
      with_live_process do |owner|
        GalaxyAgents::Database.start_agent(
          1_i64, "died-1", "Explore",
        )
        build_ledger_db([{1_i64, owner}])
        write_transcript("died-1", [error_record])

        row = GalaxyAgents::Database
          .running_with_owner_pids.first
        GalaxyAgents::ProcessLiveness.claude_alive?(
          row.owner_pid,
          expected: SPEC_LIVE_PROCESS_COMMAND,
        ).should be_true

        GalaxyAgents::AgentOutcome
          .error_death("died-1").should_not be_nil
      end
    end

    it "leaves a healthy agent with a clean transcript alone" do
      with_live_process do |owner|
        GalaxyAgents::Database.start_agent(
          1_i64, "healthy-1", "Explore",
        )
        build_ledger_db([{1_i64, owner}])
        write_transcript("healthy-1", [clean_record])

        GalaxyAgents::AgentOutcome
          .error_death("healthy-1").should be_nil
      end
    end

    # No transcript is not evidence of anything.
    it "leaves a healthy agent with no transcript alone" do
      with_live_process do |owner|
        GalaxyAgents::Database.start_agent(
          1_i64, "notranscript-1", "Explore",
        )
        build_ledger_db([{1_i64, owner}])

        GalaxyAgents::AgentOutcome
          .error_death("notranscript-1").should be_nil
      end
    end

    it "abandons a swept row through the shared write" do
      gone = dead_pid
      GalaxyAgents::Database.start_agent(
        1_i64, "agent-a", "Explore",
      )
      build_ledger_db([{1_i64, gone}])

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
