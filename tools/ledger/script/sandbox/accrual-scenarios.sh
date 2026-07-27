#!/usr/bin/env bash
# Sandbox verification of process-partitioned daily usage accrual.
# Drives the real compiled CLI against a throwaway database using
# fabricated statusline payloads.
set -u

SB=/tmp/gl-sandbox
CLI=~/projects/kellyredding/galaxy/tools/ledger/build/galaxy-ledger
rm -rf "$SB"; mkdir -p "$SB/config"
export GALAXY_LEDGER_DATABASE_PATH="$SB/ledger.db"
export GALAXY_LEDGER_CONFIG_DIR="$SB/config"

PASS=0; FAIL=0

start() { # start <session_id> <cwd>
  printf '{"session_id":"%s","cwd":"%s","hook_event_name":"SessionStart","source":"startup"}' "$1" "$2" \
    | $CLI on-startup >/dev/null 2>&1
}
tick() { # tick <session_id> <cost> <tokens>
  printf '{"session_id":"%s","context":{"tokens_used":%s},"cost":{"usd":%s}}' "$1" "$3" "$2" \
    | $CLI update-session-metrics --session "$1" >/dev/null 2>&1
}
tick_nokey() { # tick_nokey <resolve_via> <cost> <tokens>  -- payload carries NO session_id
  printf '{"context":{"tokens_used":%s},"cost":{"usd":%s}}' "$3" "$2" \
    | $CLI update-session-metrics --session "$1" >/dev/null 2>&1
}
oneshot() { $CLI --help >/dev/null 2>&1; } # placeholder (one-shots exercised via specs)
day() { export GALAXY_LEDGER_TODAY="$1"; }
q()   { sqlite3 "$SB/ledger.db" "$1"; }

check() { # check <label> <expected> <actual>
  local got exp
  got=$(printf '%.2f' "$3"); exp=$(printf '%.2f' "$2")
  if [ "$got" = "$exp" ]; then
    PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %-58s $%s\n' "$1" "$got"
  else
    FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %-58s expected $%s got $%s\n' "$1" "$exp" "$got"
  fi
}
checkn() { # checkn <label> <expected int> <actual int>
  if [ "$3" = "$2" ]; then
    PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %-58s %s\n' "$1" "$3"
  else
    FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %-58s expected %s got %s\n' "$1" "$2" "$3"
  fi
}
daycost() { q "SELECT COALESCE(SUM(cumulative_cost_usd+oneshot_cost_usd),0) FROM ledger_session_daily_usages WHERE date='$1';"; }
daytok()  { q "SELECT COALESCE(SUM(cumulative_tokens+oneshot_tokens),0) FROM ledger_session_daily_usages WHERE date='$1';"; }
sesscost(){ q "SELECT COALESCE(SUM(cumulative_cost_usd+oneshot_cost_usd),0) FROM ledger_session_daily_usages WHERE ledger_session_id=$1 AND date BETWEEN '$2' AND '$3';"; }
rowsfor() { q "SELECT COUNT(*) FROM ledger_session_daily_usages WHERE date='$1';"; }

echo
echo "=== A. Brand new session on a new day with a new process ==="
day 2026-03-01
start procA1 /tmp/projA
tick  procA1 0.00 100
tick  procA1 10.00 5000
day 2026-03-02
start procB1 /tmp/projB
tick  procB1 0.00 100
tick  procB1 4.00 2000
check "day 1 accrues only its own spend"   10.00 "$(daycost 2026-03-01)"
check "day 2 accrues only its own spend"    4.00 "$(daycost 2026-03-02)"

echo
echo "=== B. Carry over one session across multiple process IDs (same day) ==="
day 2026-03-05
start carryA /tmp/projC
tick  carryA 0.00 100
tick  carryA 10.00 20000
start carryB /tmp/projC
tick  carryB 10.00 0             # resume: inherits cost counter, context reset
tick  carryB 18.00 12000
check "resume does not double-count inherited counter" 18.00 "$(daycost 2026-03-05)"

echo
echo "=== C. One ledger session, many process IDs, across several days ==="
day 2026-03-10
start multiA /tmp/projD
tick  multiA 0.00 100
tick  multiA 20.00 40000
day 2026-03-11
tick  multiA 35.00 60000                  # same process past midnight
start multiB /tmp/projD
tick  multiB 35.00 0                      # resume
tick  multiB 40.00 15000
day 2026-03-12
tick  multiB 50.00 30000
start multiC /tmp/projD
tick  multiC 0.00 0                       # abandoned pane boot
tick  multiB 58.00 45000
check "day 1 of 3"                           20.00 "$(daycost 2026-03-10)"
check "day 2 of 3 (midnight carry + resume)" 20.00 "$(daycost 2026-03-11)"
check "day 3 of 3 (abandoned boot ignored)"  18.00 "$(daycost 2026-03-12)"
MID=$(q "SELECT ledger_session_id FROM ledger_session_identifiers WHERE session_identifier='multiA';")
check "3-day total == final counter"         58.00 "$(sesscost "$MID" 2026-03-10 2026-03-12)"

echo
echo "=== D. Restart storm: abandoned pane boots against a live worker ==="
day 2026-03-20
start stormW /tmp/projE
tick  stormW 0.00 100
tick  stormW 30.00 50000
for i in 1 2 3 4 5 6 7 8 9 10 11; do
  start "stormBoot$i" /tmp/projE
  tick  "stormBoot$i" 0.00 0
  tick  stormW "$((30 + i * 2)).00" $((50000 + i * 1000))
done
check "11 abandoned boots contribute nothing"  52.00 "$(daycost 2026-03-20)"
checkn "storm created 12 process rows"         12    "$(rowsfor 2026-03-20)"

echo
echo "=== E. Compaction: context drops, cost keeps climbing ==="
day 2026-03-25
start compA /tmp/projF
tick  compA 0.00 0
tick  compA 2.00 50000
tick  compA 4.00 90000
tick  compA 5.00 12000        # compaction: tokens collapse, cost monotonic
tick  compA 7.00 40000
check "cost unaffected by compaction"          7.00 "$(daycost 2026-03-25)"
checkn "tokens accrue 90k + 28k, not negative" 118000 "$(daytok 2026-03-25)"

echo
echo "=== F. Mid-day cost reset (fresh conversation, same process slot) ==="
day 2026-03-26
start resetA /tmp/projG
tick  resetA 0.00 0
tick  resetA 12.00 30000
tick  resetA 0.40 500         # counter reset within the same process key
tick  resetA 3.40 8000
check "both segments accrue (12.00 + 3.40)"   15.40 "$(daycost 2026-03-26)"

echo
echo "=== G. Two live workers both doing real work ==="
day 2026-03-27
start workA /tmp/projH
tick  workA 0.00 0
start workB /tmp/projH
tick  workB 0.00 0
tick  workA 5.00 10000
tick  workB 3.00 6000
tick  workA 9.00 18000
tick  workB 7.00 14000
check "both accrue their own spans (9 + 7)"   16.00 "$(daycost 2026-03-27)"

echo
echo "=== H. Process returns after an idle gap day ==="
day 2026-03-28
start gapA /tmp/projI
tick  gapA 0.00 0
tick  gapA 6.00 10000
day 2026-03-29                # idle: no ticks at all
day 2026-03-30
tick  gapA 9.00 16000         # returns; must diff against Mar 28, not zero
check "gap day records nothing"                0.00 "$(daycost 2026-03-29)"
check "return day accrues only the delta"      3.00 "$(daycost 2026-03-30)"

echo
echo "=== I. Tick with no session_id is dropped, not shared ==="
day 2026-03-31
start nokeyA /tmp/projJ
tick  nokeyA 0.00 0
tick  nokeyA 8.00 10000
tick_nokey nokeyA 0.00 0      # unattributable payload
tick  nokeyA 11.00 15000
check "unattributable tick does not reset baseline" 11.00 "$(daycost 2026-03-31)"
checkn "no extra row created"                        1     "$(rowsfor 2026-03-31)"

echo
echo "=== J. Cross-day resume: new process id is the day's first tick ==="
# The general hole: a resumed process inherits the counter. If its first
# tick is also the day's first, there is no same-day row to anchor to.
day 2026-04-01
start xdayA /tmp/projK
tick  xdayA 0.00 0
tick  xdayA 50.00 90000
day 2026-04-02
start xdayB /tmp/projK          # resume -> new process id, inherits $50
tick  xdayB 52.00 95000         # only $2 of genuinely new spend
check "day 1 books its own spend"            50.00 "$(daycost 2026-04-01)"
check "resumed process books only the delta"  2.00 "$(daycost 2026-04-02)"

echo
echo "=== K. Migration transition: frozen legacy row, tick SAME day ==="
day 2026-04-10
start legA /tmp/projL
tick  legA 0.00 0
LEGID=$(q "SELECT ledger_session_id FROM ledger_session_identifiers WHERE session_identifier='legA';")
# simulate the migrated state: single legacy-keyed row, counter at $40
q "UPDATE ledger_session_daily_usages SET process_key='legacy', cumulative_cost_usd=243.77,
      current_cost_usd=40.00, baseline_cost_usd=40.00, current_tokens=500000, cumulative_tokens=900000
   WHERE ledger_session_id=$LEGID AND date='2026-04-10';"
tick  legA 42.00 520000
check "legacy row untouched"                243.77 "$(q "SELECT cumulative_cost_usd FROM ledger_session_daily_usages WHERE ledger_session_id=$LEGID AND process_key='legacy';")"
check "new partition books only the delta"    2.00 "$(q "SELECT cumulative_cost_usd FROM ledger_session_daily_usages WHERE ledger_session_id=$LEGID AND process_key='legA';")"
check "day total = legacy + delta"          245.77 "$(daycost 2026-04-10)"

echo
echo "=== L. Migration transition: frozen legacy row, first tick NEXT day ==="
day 2026-04-20
start legB /tmp/projM
tick  legB 0.00 0
LEGID2=$(q "SELECT ledger_session_id FROM ledger_session_identifiers WHERE session_identifier='legB';")
q "UPDATE ledger_session_daily_usages SET process_key='legacy', cumulative_cost_usd=243.77,
      current_cost_usd=40.00, baseline_cost_usd=40.00, current_tokens=500000, cumulative_tokens=900000
   WHERE ledger_session_id=$LEGID2 AND date='2026-04-20';"
day 2026-04-21                  # session was quiet all of Apr 20 after the freeze
tick  legB 42.00 520000
check "prior day keeps its total"           243.77 "$(daycost 2026-04-20)"
check "rollover day books only the delta"     2.00 "$(daycost 2026-04-21)"

echo
echo "=== M. Legacy row + a brand-new unrelated process next day ==="
# Not a resume: a genuinely fresh conversation starting from ~zero.
day 2026-04-25
start legC /tmp/projN
tick  legC 0.00 0
LEGID3=$(q "SELECT ledger_session_id FROM ledger_session_identifiers WHERE session_identifier='legC';")
q "UPDATE ledger_session_daily_usages SET process_key='legacy', cumulative_cost_usd=100.00,
      current_cost_usd=30.00, baseline_cost_usd=30.00, current_tokens=400000, cumulative_tokens=400000
   WHERE ledger_session_id=$LEGID3 AND date='2026-04-25';"
day 2026-04-26
start legD /tmp/projN           # fresh conversation, counter starts near zero
tick  legD 0.20 800
tick  legD 4.20 12000
check "fresh process books its own spend"     4.20 "$(daycost 2026-04-26)"

echo
echo "=== process rows created (proof of partitioning) ==="
q "SELECT ledger_session_id || '  ' || date || '  ' || process_key || '  \$' || printf('%.2f',cumulative_cost_usd) FROM ledger_session_daily_usages WHERE date IN ('2026-03-10','2026-03-11','2026-03-12') ORDER BY date, process_key;" | sed 's/^/  /'

echo
echo "=== spend report over the sandbox range ==="
$CLI spend 2026-03-01..2026-04-30 --no-chart --no-sparkline 2>&1 | sed 's/^/  /'

echo
printf '=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
