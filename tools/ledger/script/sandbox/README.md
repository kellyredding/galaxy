# Ledger sandbox harnesses

End-to-end accrual checks that drive the real `galaxy-ledger` binary
against a throwaway database, asserting exact dollar and token values
after each simulated statusline tick.

These exist alongside the Crystal specs rather than inside them. The
specs cover `record_daily_usage` in isolation; these drive whole
sequences of ticks across process boundaries and day rollovers, which
is where the accrual bugs actually lived. Several defects reached the
live database despite a green spec suite and were only caught here.

## Running

```bash
make sandbox                        # every harness
./script/sandbox/accrual-scenarios.sh
./script/sandbox/resume-scenarios.sh
./script/sandbox/fork-scenarios.sh
./script/sandbox/fork-scenarios.sh ~/.claude/galaxy/bin/galaxy-ledger
```

Each script builds nothing — it uses `build/galaxy-ledger`, so run
`make dev` (or `make build`) first if the source has changed.
`fork-scenarios.sh` takes another binary as its argument; pointing it at
the installed one shows what a build without fork support gets wrong.

## Isolation

Both scripts `rm -rf` their sandbox directory under `/tmp` and export
`GALAXY_LEDGER_DATABASE_PATH` and `GALAXY_LEDGER_CONFIG_DIR` at the top
level before any tick. The live database is never opened.

Export the variables at the **top level of the script**, never inside a
`$(...)` substitution — a subshell export does not propagate, and ticks
then silently land in the live database.

## Writing a new scenario

Assert the exact expected value, not merely the absence of
over-counting. A harness whose command silently no-ops reads `$0.00`
everywhere, and assertions phrased as "did not grow too much" pass
against a completely broken run. Both of these harnesses briefly had
that bug.

Group scenarios by the situation being modelled and label each with a
short prefix, so a failure names the case:

- `accrual-scenarios.sh` — concurrent processes, counter resets,
  compaction, boot storms, day gaps, cross-day rollover, and rows
  attributed to `legacy` by the process-partition migration
- `resume-scenarios.sh` — resuming a session after an idle gap, before
  and after local midnight, and resume followed by immediate compaction
- `fork-scenarios.sh` — a conversation moved to a background worker under
  Claude Code's daemon, through a real process tree: the hand-off, a fork
  that leaves its parent running, a `claude -p` inside the worker, and the
  left-behind client exiting. It asserts on hooks and turn events, not
  money, and also isolates the turn-state directory and the app socket

## Interpreting a failure

A red line prints the scenario label, the expected value, and the
observed value. The sandbox database is left in place after the run,
so query it directly to see the full row history:

```bash
sqlite3 /tmp/gl-sandbox/ledger.db \
  "SELECT date, process_key, cumulative_cost_usd, cumulative_tokens
     FROM ledger_session_daily_usages ORDER BY date, process_key;"
```
