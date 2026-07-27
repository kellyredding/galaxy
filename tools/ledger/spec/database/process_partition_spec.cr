require "../spec_helper"

# Daily usage is partitioned by the Claude process that reported it.
#
# Before partitioning, every process mapped to a session shared one
# cost/token baseline. A process reporting a low counter reset that shared
# baseline, and the next tick from a process with a high counter diffed
# against the reset value and re-added its entire accumulated total.
#
# These cover the multi-process situations the single-counter specs in
# database_spec.cr cannot reach.
private def tick(lid, process_key, cost, tokens)
  GalaxyLedger::Database.update_session_metrics(
    lid,
    GalaxyLedger::ContextStatus.from_json(
      %({"session_id":"#{process_key}","context":{"tokens_used":#{tokens}},"cost":{"usd":#{cost}}})
    )
  )
end

private def day_cost(today = GalaxyLedger::LedgerTime.today_str)
  daily = GalaxyLedger::Database.spend_daily(today, today)
  daily.empty? ? 0.0 : daily[0].cost
end

describe "daily usage process partitioning" do
  it "an abandoned session reporting $0 does not disturb the working process" do
    # The failure that motivated this work: a session started in a
    # terminal pane, mapped onto an existing ledger session, and closed
    # without running anything. It reports $0, does no work, and under a
    # shared baseline still reset the value the working process diffed
    # against — so the worker re-added its whole running total.
    lid = GalaxyLedger::Database.create_session("sess-partition-abandoned")

    tick(lid, "worker", 10.00, 5000)
    tick(lid, "worker", 20.00, 8000)
    tick(lid, "abandoned-boot", 0.0, 0) # boots, ticks once, never works
    tick(lid, "worker", 30.00, 11000)

    # Worker's own span is the only real spend. Under the shared baseline
    # this returned $50.00 — the $20.00 accrued before the boot, re-added.
    day_cost.should be_close(30.00, 0.001)
  end

  it "many abandoned boots still contribute nothing" do
    # Session 674 took eleven of these in one day.
    lid = GalaxyLedger::Database.create_session("sess-partition-many-boots")

    tick(lid, "worker", 5.00, 1000)
    11.times do |i|
      tick(lid, "boot-#{i}", 0.0, 0)
      tick(lid, "worker", 5.00 + i + 1, 1000 * (i + 2))
    end

    # Worker climbed $5.00 -> $16.00; the boots add nothing.
    day_cost.should be_close(16.00, 0.001)
  end

  it "two live processes interleaving accrue only their own spans" do
    lid = GalaxyLedger::Database.create_session("sess-partition-interleave")

    tick(lid, "proc-a", 84.00, 100_000)
    tick(lid, "proc-b", 0.05, 500)
    tick(lid, "proc-a", 84.10, 100_100)
    tick(lid, "proc-b", 0.10, 900)
    tick(lid, "proc-a", 84.20, 100_200)
    tick(lid, "proc-b", 0.15, 1300)
    tick(lid, "proc-a", 84.30, 100_300)

    # proc-a ends at $84.30. proc-b has no history, so it diffs against
    # the session high-water ($84.00) — its $0.05 opening is far below
    # that, so the reset branch books proc-b's own counter rather than a
    # share of proc-a's. proc-b ends at $0.15.
    #
    # Under the shared baseline this returned $336.60.
    day_cost.should be_close(84.45, 0.001)
  end

  it "a resumed process inheriting the cost counter does not double-count" do
    # Claude carries the conversation's cost counter across a resume: the
    # new process's first observation equals the old process's last. That
    # is not new spend.
    lid = GalaxyLedger::Database.create_session("sess-partition-resume")

    tick(lid, "proc-a", 20.00, 40_000)
    tick(lid, "proc-a", 50.00, 90_000)
    tick(lid, "proc-b", 50.00, 0) # resume: inherits cost, context reset
    tick(lid, "proc-b", 55.00, 30_000)

    # $50 of shared lifetime plus $5 of new spend.
    day_cost.should be_close(55.00, 0.001)
  end

  it "a fresh conversation in the same session accrues from its own zero" do
    lid = GalaxyLedger::Database.create_session("sess-partition-fresh")

    tick(lid, "proc-a", 40.00, 80_000)
    tick(lid, "proc-b", 0.50, 2_000) # brand-new conversation, not a resume
    tick(lid, "proc-b", 3.00, 9_000)

    # proc-a's $40.00 plus proc-b's own $3.00. proc-b opens at $0.50,
    # far below the session high-water of $40.00, so the reset branch
    # recognises it as a distinct counter and books proc-b's own spend
    # in full rather than treating it as inherited.
    day_cost.should be_close(43.00, 0.001)
  end

  it "each process carries its own baseline across midnight" do
    lid = GalaxyLedger::Database.create_session("sess-partition-midnight")
    today = GalaxyLedger::LedgerTime.today_str
    yesterday = (GalaxyLedger::LedgerTime.now - 1.day).to_s("%Y-%m-%d")

    # Yesterday: two processes ended at different counters.
    GalaxyLedger::Database.open do |db|
      {"proc-a" => {60.0, 120_000}, "proc-b" => {12.0, 30_000}}.each do |key, vals|
        cost, toks = vals
        db.exec(
          <<-SQL,
            INSERT INTO ledger_session_daily_usages (
              ledger_session_id, date, process_key,
              baseline_cost_usd, current_cost_usd, cumulative_cost_usd,
              baseline_tokens, current_tokens, cumulative_tokens
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          SQL
          lid, yesterday, key, cost, cost, cost, toks, toks, toks,
        )
      end
    end

    # Today each continues from its own carry-over, not each other's.
    tick(lid, "proc-a", 63.00, 125_000) # +$3.00
    tick(lid, "proc-b", 14.50, 33_000)  # +$2.50

    day_cost(today).should be_close(5.50, 0.001)
  end

  it "a new process resuming on a later day books only the new spend" do
    # A resumed process gets a new id and inherits the conversation's
    # counter. If its first tick is also the day's first tick, there is
    # no same-day row to anchor against — it must fall back to the
    # session's prior high-water, or it books the entire inherited
    # lifetime as that day's spend.
    lid = GalaxyLedger::Database.create_session("sess-partition-xday-resume")
    today = GalaxyLedger::LedgerTime.today_str
    yesterday = (GalaxyLedger::LedgerTime.now - 1.day).to_s("%Y-%m-%d")

    GalaxyLedger::Database.open do |db|
      db.exec(
        <<-SQL,
          INSERT INTO ledger_session_daily_usages (
            ledger_session_id, date, process_key,
            baseline_cost_usd, current_cost_usd, cumulative_cost_usd,
            baseline_tokens, current_tokens, cumulative_tokens
          ) VALUES (?, ?, 'proc-a', 50.0, 50.0, 50.0, 90000, 90000, 90000)
        SQL
        lid, yesterday,
      )
    end

    # New process, new day, inherits $50 and has spent $2 since.
    tick(lid, "proc-b", 52.00, 95_000)

    day_cost(today).should be_close(2.00, 0.001)
  end

  it "a legacy-keyed prior day still anchors the next day's first tick" do
    # Migration attributes pre-existing rows to 'legacy'. A session whose
    # only prior row is legacy-keyed must still find an anchor, or its
    # first tick after rollover books its whole lifetime counter.
    lid = GalaxyLedger::Database.create_session("sess-partition-legacy-rollover")
    today = GalaxyLedger::LedgerTime.today_str
    yesterday = (GalaxyLedger::LedgerTime.now - 1.day).to_s("%Y-%m-%d")

    GalaxyLedger::Database.open do |db|
      db.exec(
        <<-SQL,
          INSERT INTO ledger_session_daily_usages (
            ledger_session_id, date, process_key,
            baseline_cost_usd, current_cost_usd, cumulative_cost_usd,
            baseline_tokens, current_tokens, cumulative_tokens
          ) VALUES (?, ?, 'legacy', 40.0, 40.0, 243.77, 500000, 500000, 900000)
        SQL
        lid, yesterday,
      )
    end

    tick(lid, "realproc", 42.00, 520_000)

    day_cost(today).should be_close(2.00, 0.001)
  end

  it "keeps one-shot usage on its own partition" do
    lid = GalaxyLedger::Database.create_session("sess-partition-oneshot")

    tick(lid, "worker", 4.00, 10_000)
    GalaxyLedger::Database.record_oneshot_usage(lid, 0.25, 3_000)
    tick(lid, "worker", 6.00, 15_000)

    # $6.00 status line + $0.25 one-shot
    day_cost.should be_close(6.25, 0.001)

    GalaxyLedger::Database.open do |db|
      keys = [] of String
      db.query(
        "SELECT process_key FROM ledger_session_daily_usages WHERE ledger_session_id = ? ORDER BY process_key",
        lid,
      ) do |rs|
        rs.each { keys << rs.read(String) }
      end
      keys.should eq(["oneshot", "worker"])
    end
  end

  it "drops a tick with no session_id rather than sharing a baseline" do
    lid = GalaxyLedger::Database.create_session("sess-partition-nil-key")

    tick(lid, "worker", 10.00, 5_000)

    # No session_id — cannot be attributed, so it must not be recorded
    # against a shared placeholder key.
    GalaxyLedger::Database.update_session_metrics(
      lid,
      GalaxyLedger::ContextStatus.from_json(%({"context":{"tokens_used":0},"cost":{"usd":0.0}}))
    )

    tick(lid, "worker", 15.00, 7_000)

    day_cost.should be_close(15.00, 0.001)

    GalaxyLedger::Database.open do |db|
      count = db.query_one?(
        "SELECT COUNT(*) FROM ledger_session_daily_usages WHERE ledger_session_id = ?",
        lid, as: Int64)
      count.should eq(1_i64)
    end
  end
end
