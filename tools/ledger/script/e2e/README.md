# Ledger end-to-end harness

`turn-tracking.py` drives a real Claude Code session through a
pseudo-terminal, with every ledger hook pointed at a throwaway sandbox, and
checks turn tracking where the timing belongs to Claude Code.

It exists alongside the Crystal specs rather than inside them. The specs
fabricate transcripts and hook payloads; whether a queued message becomes its
own turn, is folded into the running one, or arrives together with another is
Claude Code's decision, and only a live session shows what it actually does.
It is also the canary for Claude Code changing the transcript's
`queue-operation` records, which turn tracking reads and which are not
documented.

## Running

```bash
make e2e                                   # the installed ledger
make e2e LEDGER=build/galaxy-ledger        # a dev build, before `make install`
python3 script/e2e/turn-tracking.py --only batched,idle-backstop
python3 script/e2e/turn-tracking.py --help
```

Needs python3 and a logged-in `claude` on PATH. Costs a few turns on haiku
(`--model` to change it) and a few minutes, most of it waiting out Claude
Code's one-minute idle threshold — which is why it is on neither `check` nor
`check-all`.

The session starts in the repo root, and Claude Code must already trust that
folder: an untrusted one holds the session at the trust dialog before any hook
runs, and setup fails naming it. Accept the dialog once in an interactive
`claude` there, or start the session in a folder Claude Code does trust with
`--cwd` (`make e2e CWD=DIR`). Observed on Claude Code 2.1.269: the dialog
appeared for the repo root although a folder above it was trusted.

Run it after changing turn tracking — `on_user_prompt_submit`, `on_stop`,
`on_message_display`, `on_idle`, `TurnState`, `TranscriptScanner` — and after
upgrading Claude Code.

## Scenarios

- `queued-at-stop` — a message typed during a pure-text turn. If Claude Code
  holds it for a turn of its own, that turn must open when the Stop hook runs,
  recorded after the previous turn's end; if Claude Code folds it into the
  running turn, nothing may open
- `queued-interrupt` — a message queued before an Escape must open its own
  turn, using the same sequence as `SessionManager.recordEscapeInterrupt`;
  reports how far ahead of Claude Code's pickup the keystroke time was taken
- `batched` — two background tasks timed to finish on the same instant, whose
  notifications Claude Code delivers as one turn; the second must not open a
  turn of its own
- `idle-backstop` — a stale turn planted in the sandbox must be closed as
  `turn:abandoned` when the idle notification's hook runs

## Isolation

Each run gets a fresh sandbox under the system temp directory. `GALAXY_DIR`,
both database paths and the ledger config point into it, and the config
switches off extraction and name suggestion so the hooks make no Claude calls
of their own. Every inherited `CLAUDE*` variable is removed: a child of a
Galaxy session would otherwise inherit `CLAUDE_CLI_SESSION_ID`, and the ledger
would attribute the child's hooks to the parent session.

With `LEDGER` set, the session loads the installed hooks rewritten to that
binary and skips user settings, so the installed hooks do not run as well. The
run fails if the transcript shows any other binary ran the Stop hook.

The ledger's databases, config and turn state all live in the sandbox. Outside
it, Claude Code keeps its usual per-session files under `~/.claude`, and in the
default run any other hooks in your user settings run as usual. A clean run
deletes the sandbox and the session's transcript.

## Reading the result

Each scenario prints PASS, FAIL or INCONCLUSIVE. INCONCLUSIVE means Claude
Code took the other branch — delivered the notifications separately, or
finished before the interrupt landed — so the case under test never happened;
rerun it.

A FAIL keeps the sandbox and the transcript and prints both paths. The
transcript's `queue-operation` records and the sandbox timeline together show
what happened:

```bash
sqlite3 <sandbox>/galaxy/data/timeline.db \
  "SELECT id, occurred_at, event_type, source, duration_identifier
     FROM events WHERE event_type LIKE 'turn:%' ORDER BY id;"
```

## Not covered

Galaxy's own Escape handler and the app's idle backstop both live in the app,
so no harness outside it reaches them. Check them by hand: queue a message
mid-turn, press Escape, and look for `turn:initiated | galaxy-app/interrupt`
carrying the queued text.

## Writing a scenario of your own

The script's header lists the traps a pty harness has to handle. Each fails
silently — a prompt that is typed but never submitted, hooks attributed to the
wrong session — so build on `Session` rather than a fresh pty.
