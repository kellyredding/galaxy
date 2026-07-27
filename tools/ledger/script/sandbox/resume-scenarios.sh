#!/usr/bin/env bash
# Resume scenarios for real sessions, replayed against a THROWAWAY database.
set -u
SB=/tmp/gl-resume
CLI=~/projects/kellyredding/galaxy/tools/ledger/build/galaxy-ledger
rm -rf "$SB"; mkdir -p "$SB/config"
# exports at top level - never inside a function called via $(...)
export GALAXY_LEDGER_DATABASE_PATH="$SB/ledger.db"
export GALAXY_LEDGER_CONFIG_DIR="$SB/config"
echo "sandbox DB: $GALAXY_LEDGER_DATABASE_PATH"
PASS=0; FAIL=0
q(){ sqlite3 "$SB/ledger.db" "$1"; }
day(){ export GALAXY_LEDGER_TODAY="$1"; }
t(){ # t <resolver_key> <process_key> <cost> <tokens>
  printf '{"session_id":"%s","context":{"tokens_used":%s},"cost":{"usd":%s}}' "$2" "$4" "$3" \
     | $CLI update-session-metrics --session "$1" >/dev/null 2>&1; }
mkrow(){ # mkrow <lid> <date> <key> <counter> <accrued> <curtok> <acctok>
  q "INSERT INTO ledger_session_daily_usages (ledger_session_id,date,process_key,
       baseline_cost_usd,current_cost_usd,cumulative_cost_usd,
       baseline_tokens,current_tokens,cumulative_tokens)
     VALUES ($1,'$2','$3',$4,$4,$5,$6,$6,$7);"; }
check(){ local g e; g=$(printf '%.2f' "$3"); e=$(printf '%.2f' "$2")
  if [ "$g" = "$e" ]; then PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %-52s $%s\n' "$1" "$g"
  else FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %-52s expected $%s got $%s\n' "$1" "$e" "$g"; fi; }
checkn(){ if [ "$3" = "$2" ]; then PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %-52s %s\n' "$1" "$3"
  else FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %-52s expected %s got %s\n' "$1" "$2" "$3"; fi; }
dcost(){ q "SELECT COALESCE(SUM(cumulative_cost_usd),0) FROM ledger_session_daily_usages WHERE ledger_session_id=$1 AND date='$2';"; }
dtok(){  q "SELECT COALESCE(SUM(cumulative_tokens),0) FROM ledger_session_daily_usages WHERE ledger_session_id=$1 AND date='$2';"; }
newsess(){ # newsess <bootstrap_key> <cwd> -> echoes lid
  day 2026-07-20
  printf '{"session_id":"%s","cwd":"%s","hook_event_name":"SessionStart","source":"startup"}' "$1" "$2" | $CLI on-startup >/dev/null 2>&1
  q "SELECT ledger_session_id FROM ledger_session_identifiers WHERE session_identifier='$1';"; }

echo
echo "############ SESSION 684-LIKE: active today, then midnight rolls over ############"
L=$(newsess boot684 /tmp/s684)
q "DELETE FROM ledger_session_daily_usages WHERE ledger_session_id=$L;"
mkrow $L 2026-07-26 legacy     49.05 52.64 716448 716448
mkrow $L 2026-07-26 56379f62   67.87 18.43 797512 797512
echo "  state: Jul 26 = legacy \$52.64 + 56379f62 \$18.43 (counter \$67.87)"

echo
echo "--- S1a. same process keeps running past midnight, accrues \$3 / 20k tok ---"
day 2026-07-27
t boot684 56379f62 70.87 817512
check "Jul 26 untouched"                  71.07 "$(dcost $L 2026-07-26)"
check "Jul 27 books only the delta"        3.00 "$(dcost $L 2026-07-27)"
checkn "Jul 27 tokens book only the delta" 20000 "$(dtok $L 2026-07-27)"

echo
echo "--- S1b. resumed as a NEW process after midnight (inherits \$67.87) ---"
L=$(newsess boot684b /tmp/s684b)
q "DELETE FROM ledger_session_daily_usages WHERE ledger_session_id=$L;"
mkrow $L 2026-07-26 legacy     49.05 52.64 716448 716448
mkrow $L 2026-07-26 56379f62   67.87 18.43 797512 797512
day 2026-07-27
t boot684b newproc684 67.87 0            # resume: inherits counter, context reset
t boot684b newproc684 70.87 20000        # then does \$3 of work
check "Jul 26 untouched"                  71.07 "$(dcost $L 2026-07-26)"
check "Jul 27 books only the new spend"    3.00 "$(dcost $L 2026-07-27)"
checkn "Jul 27 tokens book only new work"  20000 "$(dtok $L 2026-07-27)"

echo
echo "############ SESSION 665-LIKE: stopped since Jul 24, resumed later ############"
echo "  state: Jul 22 \$55.58 / Jul 23 \$117.92 / Jul 24 \$172.41 (counter \$32.89, 487154 tok)"

echo
echo "--- S2. resumed NOW (Jul 26) — two-day gap since last activity ---"
L=$(newsess boot665 /tmp/s665)
q "DELETE FROM ledger_session_daily_usages WHERE ledger_session_id=$L;"
mkrow $L 2026-07-22 legacy 55.58  55.58 650400 650400
mkrow $L 2026-07-23 legacy 29.27 117.92 674102 879746
mkrow $L 2026-07-24 legacy 32.89 172.41 487154 1497603
day 2026-07-26
t boot665 resumed665 32.89 487154       # resume inherits Jul 24's counter + context
t boot665 resumed665 36.89 507154       # \$4 of new work, +20k tokens
check "Jul 24 untouched"                 172.41 "$(dcost $L 2026-07-24)"
check "Jul 25 stays empty"                 0.00 "$(dcost $L 2026-07-25)"
check "Jul 26 books only the new spend"    4.00 "$(dcost $L 2026-07-26)"
checkn "Jul 26 tokens book only new work"  20000 "$(dtok $L 2026-07-26)"

echo
echo "--- S3. resumed AFTER midnight (Jul 27) — three-day gap ---"
L=$(newsess boot665b /tmp/s665b)
q "DELETE FROM ledger_session_daily_usages WHERE ledger_session_id=$L;"
mkrow $L 2026-07-22 legacy 55.58  55.58 650400 650400
mkrow $L 2026-07-23 legacy 29.27 117.92 674102 879746
mkrow $L 2026-07-24 legacy 32.89 172.41 487154 1497603
day 2026-07-27
t boot665b resumed665b 32.89 487154
t boot665b resumed665b 36.89 507154
check "Jul 24 untouched"                 172.41 "$(dcost $L 2026-07-24)"
check "Jul 27 books only the new spend"    4.00 "$(dcost $L 2026-07-27)"
checkn "Jul 27 tokens book only new work"  20000 "$(dtok $L 2026-07-27)"

echo
echo "--- S4. same pane, but a FRESH conversation (counter starts near zero) ---"
L=$(newsess boot665c /tmp/s665c)
q "DELETE FROM ledger_session_daily_usages WHERE ledger_session_id=$L;"
mkrow $L 2026-07-24 legacy 32.89 172.41 487154 1497603
day 2026-07-27
t boot665c fresh665 0.30 1200            # brand-new conversation, not a resume
t boot665c fresh665 5.30 41200
check "Jul 24 untouched"                 172.41 "$(dcost $L 2026-07-24)"
check "fresh conversation books its own"   5.30 "$(dcost $L 2026-07-27)"
# 40000 not 41200: the opening 1200-token observation falls below the
# Jul 24 anchor, so the token branch treats it as compaction and books
# nothing, while the cost branch books its $0.30. That asymmetry is the
# original algorithm and is deliberate — in practice a real process's
# first status line render happens at boot with ~0 tokens.
checkn "opening tokens dropped as compaction (by design)" 40000 "$(dtok $L 2026-07-27)"

echo
echo "--- S5. resumed session that immediately compacts (tokens drop) ---"
L=$(newsess boot665d /tmp/s665d)
q "DELETE FROM ledger_session_daily_usages WHERE ledger_session_id=$L;"
mkrow $L 2026-07-24 legacy 32.89 172.41 487154 1497603
day 2026-07-27
t boot665d comp665 32.89 487154
t boot665d comp665 34.89 60000           # compaction: context collapses, cost still climbs
t boot665d comp665 36.89 90000
check "cost accrues through compaction"    4.00 "$(dcost $L 2026-07-27)"
checkn "tokens accrue only forward growth" 30000 "$(dtok $L 2026-07-27)"

echo
printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
