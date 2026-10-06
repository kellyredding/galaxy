#!/usr/bin/env bash
# Fork scenarios: a conversation moved to a background worker under Claude
# Code's daemon, replayed through a real process tree against a THROWAWAY
# ledger. Every Galaxy path — database, config, turn state, app socket — is
# pointed into the sandbox, and the timeline is a stub that logs its calls.
#
# The tree mirrors the one measured on 2026-10-06, with /bin/bash reached
# through symlinks named as `ps -o comm=` reported them:
#
#   claude                 the session, tracked by the ledger
#   └ …/claude             the daemon it started (untracked)
#     └ claude bg-pty-host the daemon's host for one background session
#       └ claude bg-spare  the worker running the forked conversation
#
# Usage: fork-scenarios.sh [path/to/galaxy-ledger]
#   Defaults to build/galaxy-ledger. Pass the installed binary to see the
#   scenarios a build without fork support fails.
set -u
HERE=$(cd "$(dirname "$0")/../.." && pwd)
CLI=${1:-$HERE/build/galaxy-ledger}
SB=/tmp/gl-fork
rm -rf "$SB"; mkdir -p "$SB"/{config,claude,galaxy,bin,daemon,projects}

# exports at top level - never inside a function called via $(...)
export GALAXY_LEDGER_DATABASE_PATH="$SB/ledger.db"
export GALAXY_LEDGER_CONFIG_DIR="$SB/config"
export GALAXY_CLAUDE_CONFIG_DIR="$SB/claude"
export GALAXY_DIR="$SB/galaxy"
export GALAXY_TIMELINE_BIN="$SB/bin/timeline-stub"
export GALAXY_AGENTS_BIN=/usr/bin/true
export GALAXY_SNAPSHOTS_BIN=/usr/bin/true
export GALAXY_ARTIFACTS_BIN=/usr/bin/true
export GALAXY_BIN=/usr/bin/true
export GALAXY_FORK_HANDOFF_WAIT_MS=1500
export CLAUDE_CLI_SESSION_ID=""
export CLAUDECODE=""
export CLI SB
echo "binary:     $CLI"
echo "sandbox DB: $GALAXY_LEDGER_DATABASE_PATH"

# Stop and name extraction would call Claude; keep them off.
"$CLI" config set extraction.on_stop false >/dev/null
"$CLI" config set suggested_name.enabled false >/dev/null

cat > "$SB/bin/timeline-stub" <<'STUB'
#!/bin/bash
# Log the event type and, for a recorded turn, its duration id.
type=""; did=""
while [ $# -gt 0 ]; do
  case "$1" in
    --event-type) type=$2; shift ;;
    --duration-identifier) did=$2; shift ;;
    --detail-data-stdin) cat >/dev/null ;;
  esac
  shift
done
echo "$type $did" >> "$SB/timeline.log"
echo '{"id":1}'
STUB
chmod +x "$SB/bin/timeline-stub"

ln -s /bin/bash "$SB/bin/claude"
ln -s /bin/bash "$SB/daemon/claude"
ln -s /bin/bash "$SB/bin/claude bg-pty-host"
ln -s /bin/bash "$SB/bin/claude bg-spare"

PASS=0; FAIL=0
q(){ sqlite3 "$SB/ledger.db" "$1"; }
checkn(){ if [ "$3" = "$2" ]; then PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %-58s %s\n' "$1" "$3"
  else FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %-58s expected %s got %s\n' "$1" "$2" "$3"; fi; }
lid_of(){ q "SELECT ledger_session_id FROM ledger_session_identifiers WHERE session_identifier='$1';"; }
current_of(){ q "SELECT current_session_identifier FROM ledger_sessions WHERE id=$1;"; }
count(){ grep -c "^$1" "$SB/timeline.log" 2>/dev/null || true; }
# A here-string, not a pipe: the hook must be the calling shell's own child,
# since the ledger knows a session by its hooks' parent pid.
hook(){ "$CLI" "$1" <<< "$2" >/dev/null 2>>"$SB/stderr.log"; }

# A launch id the ledger knows the session by, the id /clear moved it to,
# and the fork's. The parent transcript is named for the current id.
LAUNCH=launch-0001; PARENT=parent-0001; FORK=fork-0001
TP="$SB/projects/$PARENT.jsonl"; TF="$SB/projects/$FORK.jsonl"
printf '{"type":"assistant","sessionId":"%s","session_id":"%s"}\n' "$PARENT" "$LAUNCH" > "$TP"
printf '{"type":"attachment","sessionId":"%s","session_id":"%s"}\n' "$FORK" "$LAUNCH" > "$TF"
export LAUNCH PARENT FORK TP TF

# Each level is a script, so the shell that runs it stays alive as its
# child's parent, as Claude Code stays alive as its hooks' parent.
cat > "$SB/outer.sh" <<'EOS'
source "$SB/lib.sh"
hook on-startup "{\"session_id\":\"$LAUNCH\",\"cwd\":\"/tmp\",\"source\":\"startup\"}"
hook on-clear   "{\"session_id\":\"$PARENT\",\"source\":\"clear\",\"transcript_path\":\"$TP\"}"
hook on-user-prompt-submit "{\"session_id\":\"$PARENT\",\"prompt\":\"ok go\"}"
hook on-stop    "{\"session_id\":\"$PARENT\",\"transcript_path\":\"$TP\",\"last_assistant_message\":\"done\"}"
echo "$$" > "$SB/outer.pid"
[ "${SCENARIO}" = parallel ] || \
  printf '{"type":"continued-in","sessionId":"%s","continuedInSessionId":"%s"}\n' "$PARENT" "$FORK" >> "$TP"
"$SB/daemon/claude" "$SB/daemon.sh"
[ "${SCENARIO}" = parallel ] && \
  hook on-user-prompt-submit "{\"session_id\":\"$PARENT\",\"prompt\":\"still me\"}" && \
  hook on-stop "{\"session_id\":\"$PARENT\",\"transcript_path\":\"$TP\",\"last_assistant_message\":\"yes\"}"
hook on-session-end "{\"session_id\":\"$PARENT\",\"cwd\":\"/tmp\",\"reason\":\"other\"}"
true
EOS
cat > "$SB/daemon.sh" <<'EOS'
"$SB/bin/claude bg-pty-host" "$SB/host.sh"
true
EOS
cat > "$SB/host.sh" <<'EOS'
"$SB/bin/claude bg-spare" "$SB/worker.sh"
true
EOS
cat > "$SB/worker.sh" <<'EOS'
source "$SB/lib.sh"
echo "$$" > "$SB/worker.pid"
hook on-fork "{\"session_id\":\"$FORK\",\"source\":\"fork\",\"transcript_path\":\"$TF\"}"
hook on-user-prompt-submit "{\"session_id\":\"$FORK\",\"prompt\":\"next\"}"
hook on-stop "{\"session_id\":\"$FORK\",\"transcript_path\":\"$TF\",\"last_assistant_message\":\"ok\"}"
# A claude -p run by the agent inside the worker.
"$SB/bin/claude" -c "\"\$CLI\" on-startup <<< '{\"session_id\":\"nested-0001\",\"cwd\":\"/tmp\",\"source\":\"startup\"}' >/dev/null 2>&1; true"
true
EOS
cat > "$SB/lib.sh" <<EOS
$(declare -f hook)
EOS

run_tree(){ # run_tree <scenario>
  : > "$SB/timeline.log"; : > "$SB/stderr.log"
  rm -f "$SB/ledger.db"* "$SB/outer.pid" "$SB/worker.pid"
  rm -rf "$SB/galaxy/ledger"
  printf '{"type":"assistant","sessionId":"%s","session_id":"%s"}\n' "$PARENT" "$LAUNCH" > "$TP"
  SCENARIO=$1 "$SB/bin/claude" "$SB/outer.sh"
}

echo
echo "--- F1. hand-off: the worker replaced its parent ---"
run_tree handoff
L=$(lid_of "$LAUNCH"); WPID=$(cat "$SB/worker.pid")
checkn "parent session exists"                         "1"      "$([ -n "$L" ] && echo 1)"
checkn "fork id joins the session"                   "$L"     "$(lid_of "$FORK")"
checkn "fork id is current"                            "$FORK"  "$(current_of "$L")"
checkn "worker pid is current"                         "$WPID"  "$(q "SELECT current_claude_pid FROM ledger_sessions WHERE id=$L;")"
checkn "session:forked recorded"                       "1"      "$(count session:forked)"
checkn "worker's turn opened"                          "2"      "$(count turn:initiated)"
checkn "worker's turn closed"                          "2"      "$(count turn:completed)"
checkn "claude -p inside the worker stays out"         ""       "$(lid_of nested-0001)"
checkn "left-behind client does not end the session"   "0"      "$(count session:ended)"
checkn "one ledger session in all"                     "1"      "$(q 'SELECT COUNT(*) FROM ledger_sessions;')"

echo
echo "--- F2. parallel: the parent kept running, no hand-off ---"
run_tree parallel
L=$(lid_of "$LAUNCH")
checkn "fork not registered"                           ""       "$(lid_of "$FORK")"
checkn "parent id stays current"                       "$PARENT" "$(current_of "$L")"
checkn "no session:forked"                             "0"      "$(count session:forked)"
checkn "parent's later turn still recorded"            "2"      "$(count turn:completed)"
checkn "parent's own exit ends the session"            "1"      "$(count session:ended)"
checkn "refusal reported on stderr"                    "1"      "$(grep -c 'not adopted' "$SB/stderr.log")"

printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
