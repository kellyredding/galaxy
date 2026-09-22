#!/usr/bin/env python3
"""End-to-end check of Galaxy's turn tracking against a real Claude Code session.

Runs `claude` in a pseudo-terminal with every ledger hook pointed at a
throwaway sandbox, and checks the paths the unit specs cannot reach because
their timing belongs to Claude Code:

  queued-at-stop    a message typed mid-turn opens its own turn at Stop
  queued-interrupt  the same across an interrupt, via Galaxy's own sequence
  batched           two notifications delivered as one turn leave no phantom
  idle-backstop     a stale turn is closed when the agent reports idle
  nested-oneshot    a `claude -p` run inside the session stays out of it

Each prints PASS, FAIL or INCONCLUSIVE. Claude Code decides some of the
timing -- whether a queued message is folded into the running turn, whether
two notifications arrive together -- and a run where it went the other way
proves nothing, so it is INCONCLUSIVE rather than a failure. Rerun it.

Usage:
  make -C tools/ledger e2e                              # installed ledger
  make -C tools/ledger e2e LEDGER=build/galaxy-ledger   # a dev build
  python3 tools/ledger/script/e2e/turn-tracking.py --help

Costs a few turns on the chosen model (haiku by default) and a few minutes.
Needs python3 and a logged-in `claude` on PATH. The sandbox and the test
session's transcript are removed afterwards unless a scenario fails or
--keep is given.

Not covered, because both need Galaxy itself: the app's Escape handler and
its own idle backstop. The interrupt scenario performs the app's sequence
from `SessionManager.recordEscapeInterrupt` instead.

Traps a pty harness has to handle, each of which fails silently:
  - Return may not submit. Galaxy rebinds it; the submit keystroke follows
    `SessionSubmit.bytes` in Galactic, and is only decoded once the session
    has pushed the kitty keyboard protocol.
  - Text must be typed, not pasted: a paste swallows the submit after it.
  - Every inherited CLAUDE* variable must go. A child of a Galaxy session
    inherits CLAUDE_CLI_SESSION_ID, and the ledger then attributes the
    child's hooks to the parent session.
  - The sandbox database must not be opened before the SessionStart hook
    creates it; an early open leaves the ledger's schema half-built.
"""

import argparse
import fcntl
import glob
import json
import os
import pty
import re
import select
import shlex
import shutil
import signal
import sqlite3
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import uuid
from collections import namedtuple
from datetime import datetime, timedelta, timezone
from pathlib import Path

HOME = Path.home()
REPO = Path(__file__).resolve().parents[4]
# Resolved, as --ledger is; start() compares the two to decide which hooks load.
INSTALLED_LEDGER = (HOME / ".claude/galaxy/bin/galaxy-ledger").resolve()
TIMELINE = Path(os.environ.get("GALAXY_TIMELINE_BIN",
                               HOME / ".claude/galaxy/bin/galaxy-timeline"))

# Galaxy's reserved machine-submit chord: kitty-encoded Enter with
# ctrl+alt+shift+super, which Galaxy binds to chat:submit.
RESERVED_SUBMIT = b"\x1b[13;16u"
RESERVED_BINDING = "ctrl+alt+shift+cmd+enter"
KITTY_PUSH = re.compile(rb"\x1b\[>\d+u")
MARK = "e2e marker"

Op = namedtuple("Op", "at op reason content")
Row = namedtuple("Row", "id at type source did msg")
Result = namedtuple("Result", "name status detail")


class Failure(Exception):
    pass


def now():
    return datetime.now(timezone.utc)


def iso_ms(t):
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + f"{t.microsecond // 1000:03d}Z"


def parse_ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def wait_for(pred, timeout, poll=0.2):
    end = time.time() + timeout
    while time.time() < end:
        value = pred()
        if value:
            return value
        time.sleep(poll)
    return None


def read_json(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return None


def submit_order():
    """The submit keystroke Galaxy would use, then the other one.

    Mirrors `SessionSubmit.bytes`: a carriage return when Return submits
    (Claude Code's default), otherwise the reserved chord. The other stays as
    a fallback, because a session launched without user settings may not load
    the bindings this file describes.
    """
    bindings = {}
    for block in (read_json(HOME / ".claude/keybindings.json") or {}).get("bindings", []):
        if block.get("context") == "Chat":
            bindings.update(block.get("bindings") or {})
    if bindings.get("enter", "chat:submit") != "chat:submit" \
            and bindings.get(RESERVED_BINDING) == "chat:submit":
        return [RESERVED_SUBMIT, b"\r"]
    return [b"\r", RESERVED_SUBMIT]


class Session:
    def __init__(self, sandbox, ledger, model, cwd):
        self.sandbox = sandbox
        self.galaxy_dir = sandbox / "galaxy"
        self.db_ledger = self.galaxy_dir / "data/ledger.db"
        self.db_timeline = self.galaxy_dir / "data/timeline.db"
        self.ledger = ledger
        self.model = model
        self.cwd = Path(cwd).expanduser().resolve()
        self.sid = str(uuid.uuid4())
        self.state_path = self.galaxy_dir / f"ledger/turn-state/{self.sid}.json"
        self.pending_path = self.galaxy_dir / f"ledger/turn-pending/{self.sid}.json"
        self.submit_bytes = submit_order()
        self.screen = bytearray()
        self.lock = threading.Lock()
        self.alive = True
        self.ready = False
        self.pid = self.fd = None
        self.env = self._environment()
        self._prepare_sandbox()

    # --- setup ---------------------------------------------------------

    def _environment(self):
        env = {k: v for k, v in os.environ.items() if not k.startswith("CLAUDE")}
        env.update(
            GALAXY_DIR=str(self.galaxy_dir),
            GALAXY_LEDGER_CONFIG_DIR=str(self.galaxy_dir / "ledger"),
            GALAXY_LEDGER_DATABASE_PATH=str(self.db_ledger),
            GALAXY_TIMELINE_DATABASE_PATH=str(self.db_timeline),
            GALAXY_TIMELINE_BIN=str(TIMELINE),
            TERM="xterm-256color",
        )
        return env

    def _prepare_sandbox(self):
        (self.galaxy_dir / "data").mkdir(parents=True, exist_ok=True)
        (self.galaxy_dir / "ledger").mkdir(parents=True, exist_ok=True)
        # The ledger's own defaults, with the jobs that call Claude switched off.
        printed = subprocess.run([str(self.ledger), "config"], env=self.env,
                                 capture_output=True, text=True).stdout
        config = json.loads(printed)
        config["extraction"]["on_stop"] = False
        config["extraction"]["on_guideline_read"] = False
        config["suggested_name"]["enabled"] = False
        (self.galaxy_dir / "ledger/config.json").write_text(json.dumps(config, indent=2))
        (self.galaxy_dir / "config.json").write_text(json.dumps(
            {"_schema_version": "0.0.1",
             "backups": {"enabled": False, "retention_days": 3, "path": ""}}))

    def _dev_settings(self):
        """The installed hooks, with the ledger binary swapped for self.ledger."""
        installed = read_json(HOME / ".claude/settings.json") or {}
        hooks = installed.get("hooks")
        if not hooks:
            raise Failure("no hooks in ~/.claude/settings.json to copy; "
                          "run `make install` once so they exist")
        text = json.dumps(hooks).replace("~/.claude/galaxy/bin/galaxy-ledger", str(self.ledger))
        path = self.sandbox / "settings.json"
        path.write_text(json.dumps({"hooks": json.loads(text),
                                    "skipDangerousModePermissionPrompt": True}, indent=2))
        return path

    def start(self):
        claude = shutil.which("claude")
        if not claude:
            raise Failure("`claude` is not on PATH")
        argv = [claude, "--session-id", self.sid, "--model", self.model,
                "--dangerously-skip-permissions"]
        if self.ledger != INSTALLED_LEDGER:
            argv += ["--settings", str(self._dev_settings()),
                     "--setting-sources", "project,local"]
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            try:
                os.chdir(self.cwd)
                os.execve(claude, argv, self.env)
            finally:
                os._exit(127)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 160, 0, 0))
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        while self.alive:
            try:
                ready, _, _ = select.select([self.fd], [], [], 0.25)
                if not ready:
                    continue
                data = os.read(self.fd, 65536)
            except OSError:
                break
            if not data:
                break
            with self.lock:
                self.screen.extend(data)
                del self.screen[:-200_000]
            # Queries a TUI may wait on. The kitty keyboard query goes
            # unanswered, which keeps "\x1b" meaning a bare Escape.
            if b"\x1b[6n" in data:
                os.write(self.fd, b"\x1b[1;1R")
            if b"\x1b[c" in data:
                os.write(self.fd, b"\x1b[?62;22c")
        self.alive = False

    def wait_ready(self):
        def state():
            with self.lock:
                screen = bytes(self.screen)
            if (b"SessionStart" in screen or b"Ledger active" in screen) \
                    and KITTY_PUSH.search(screen):
                return "ready"
            if re.search(r"trust(thefilesin)?thisfolder", re.sub(r"\s", "", self.text()).lower()):
                return "untrusted"
            return None
        reached = wait_for(state, 60)
        if reached == "untrusted":
            raise Failure(f"Claude Code is asking whether to trust {self.cwd}. Accept that once "
                          "in an interactive `claude` there, or pass --cwd (CWD= for make) "
                          "naming a folder it already trusts")
        if not reached:
            raise Failure("the session never showed its SessionStart hook and "
                          "kitty keyboard push; last screen:\n" + self.tail())
        if not wait_for(self.lsid, 20):
            raise Failure("the session never registered in the sandbox ledger")
        self.ready = True
        time.sleep(2)

    def stop(self):
        # Before ready, keystrokes go to whatever dialog is holding the session.
        if self.ready:
            try:
                os.write(self.fd, b"\x15/exit")
                time.sleep(0.15)
                os.write(self.fd, self.submit_bytes[0])
                time.sleep(1.5)
            except (OSError, TypeError):
                pass
        self.alive = False
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.kill(self.pid, sig)
                time.sleep(0.5)
            except (OSError, TypeError):
                break
        try:
            os.waitpid(self.pid, os.WNOHANG)
        except (OSError, TypeError):
            pass

    def text(self):
        with self.lock:
            raw = bytes(self.screen).decode("utf-8", "replace")
        return re.sub(r"\x1b\[[0-9;?<>=]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)", "", raw)

    def tail(self, lines=15):
        rows = [r.rstrip() for r in self.text().replace("\r", "\n").split("\n") if r.strip()]
        return "\n".join("    | " + r[:140] for r in rows[-lines:])

    # --- input ---------------------------------------------------------

    def type_line(self, text):
        """Type a prompt and submit it, confirming Claude Code took it."""
        os.write(self.fd, b"\x15")
        time.sleep(0.2)
        os.write(self.fd, text.encode())
        for keystroke in self.submit_bytes:
            time.sleep(0.15)
            os.write(self.fd, keystroke)
            if wait_for(lambda: self.delivered(text), 4):
                return
        raise Failure(f"Claude Code never accepted {text[:40]!r}; last screen:\n" + self.tail())

    def interrupt_like_galaxy(self):
        """`SessionManager.recordEscapeInterrupt`, in its order.

        Take the time first, clear the turn state, start recording the
        interrupt and let Escape through at once; open the queued turn only
        once the interrupt is written.
        """
        ended_at = now()
        state = read_json(self.state_path)
        if not state:
            os.write(self.fd, b"\x1b")
            return ended_at, None
        self.state_path.unlink()
        record = subprocess.Popen(
            [str(TIMELINE), "record", "--ledger-session-id", str(self.lsid()),
             "--event-type", "turn:interrupted", "--source", "galaxy-app",
             "--duration-identifier", "turn--" + state["uuid"],
             "--detail-data", json.dumps({"user_message": state["user_message"]})],
            env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        os.write(self.fd, b"\x1b")
        record.wait()
        subprocess.run(
            [str(self.ledger), "open-queued-turn", "--session", self.sid,
             "--transcript-path", str(self.transcript() or ""),
             "--ended-at", iso_ms(ended_at), "--source", "galaxy-app/interrupt"],
            env=self.env, capture_output=True)
        return ended_at, state

    # --- probes --------------------------------------------------------

    def q(self, db, sql, args=()):
        # Read-only, and never before the file exists: an open that creates
        # the database leaves the ledger's own migration of it half-done.
        if not db.exists():
            return []
        try:
            con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=2)
            try:
                return con.execute(sql, args).fetchall()
            finally:
                con.close()
        except sqlite3.Error:
            return []

    def lsid(self):
        rows = self.q(self.db_ledger, "select ledger_session_id from "
                      "ledger_session_identifiers where session_identifier=?", (self.sid,))
        return rows[0][0] if rows else None

    def transcript(self):
        hits = glob.glob(str(HOME / ".claude/projects/*" / f"{self.sid}.jsonl"))
        return Path(hits[0]) if hits else None

    def records(self):
        path = self.transcript()
        if not path:
            return []
        out = []
        for line in path.read_text(errors="replace").splitlines():
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
        return out

    def queue_ops(self, since):
        ops = [Op(parse_ts(r["timestamp"]), r.get("operation"), r.get("reason"),
                  r.get("content") or "")
               for r in self.records()
               if r.get("type") == "queue-operation" and r.get("timestamp")]
        return sorted((o for o in ops if o.at >= since), key=lambda o: o.at)

    def stops(self):
        return [r for r in self.records() if r.get("subtype") == "stop_hook_summary"]

    def delivered(self, text):
        for r in self.records():
            if r.get("type") == "queue-operation" and r.get("operation") == "enqueue" \
                    and (r.get("content") or "").startswith(text):
                return True
            if r.get("type") == "user":
                msg = r.get("message")
                content = msg.get("content") if isinstance(msg, dict) else None
                texts = [content] if isinstance(content, str) else \
                    [b.get("text", "") for b in content or [] if isinstance(b, dict)]
                if any(text in t for t in texts):
                    return True
        return False

    def fate(self, text, since):
        """What Claude Code did with a queued prompt: (fate, when)."""
        ops = self.queue_ops(since)
        enqueued = [o for o in ops if o.op == "enqueue" and o.content.startswith(text)]
        if not enqueued:
            return "never-queued", None
        after = [o for o in ops if o.at >= enqueued[-1].at and o is not enqueued[-1]]
        for o in after:
            if o.op == "remove" and o.content.startswith(text):
                return "absorbed", o.at
            if o.op == "popAll":
                return "cleared", o.at
            if o.op == "dequeue":
                return "dequeued", o.at
        return "waiting", None

    def timeline_max(self):
        rows = self.q(self.db_timeline, "select coalesce(max(id), 0) from events")
        return rows[0][0] if rows else 0

    def timeline_since(self, after_id):
        return [Row(*r[:5], (r[5] or "").replace("\n", " "))
                for r in self.q(self.db_timeline,
                                "select id, occurred_at, event_type, source, "
                                "duration_identifier, json_extract(detail_data, '$.user_message') "
                                "from events where id > ? and event_type like 'turn:%' "
                                "order by id", (after_id,))]

    def leftovers(self):
        return [p.name.split(".")[0] for p in (self.state_path, self.pending_path) if p.exists()]

    def tool_results(self):
        """Every tool result's text, in transcript order."""
        out = []
        for r in self.records():
            msg = r.get("message") if r.get("type") == "user" else None
            content = msg.get("content") if isinstance(msg, dict) else None
            for block in content if isinstance(content, list) else []:
                if not isinstance(block, dict) or block.get("type") != "tool_result":
                    continue
                inner = block.get("content")
                out.append(inner if isinstance(inner, str) else " ".join(
                    b.get("text", "") for b in inner or [] if isinstance(b, dict)))
        return out

    def oneshot_command(self, word):
        """A `claude -p` for the session to run, placed as a plugin hook's is.

        CLAUDE_CLI_SESSION_ID is passed on purpose. This harness strips it from
        the session, but a Claude Persona or Galaxy session carries it and every
        child inherits it -- which is what lets a nested one-shot pass itself
        off as a resume of the session running it.
        """
        argv = ["claude", "-p", "--model", self.model]
        if self.ledger != INSTALLED_LEDGER:
            argv += ["--settings", str(self.sandbox / "settings.json"),
                     "--setting-sources", "project,local"]
        argv.append(f"Reply with only the word {word}.")
        return f"CLAUDE_CLI_SESSION_ID={self.sid} " + " ".join(shlex.quote(a) for a in argv)


# --- scenarios -------------------------------------------------------------

def queued_at_stop(s):
    name = "queued-at-stop"
    since, first, stops = now(), s.timeline_max(), len(s.stops())
    s.type_line("Explain in about 600 words how a lighthouse lens works. Use no tools.")
    if not wait_for(s.state_path.exists, 30):
        return Result(name, "FAIL", "the first turn never started")
    time.sleep(1.5)
    if len(s.stops()) != stops:
        return Result(name, "INCONCLUSIVE", "the first turn ended before a message could be queued")
    queued = f"{MARK} one: reply with only the word ok."
    s.type_line(queued)
    # Claude Code either holds the message for a turn of its own or folds it
    # into the running one; wait for whichever it chose.
    wait_for(lambda: len(s.stops()) >= stops + 2
             or (s.fate(queued, since)[0] == "absorbed" and len(s.stops()) >= stops + 1), 150)
    time.sleep(2)
    fate, picked_up = s.fate(queued, since)
    rows = s.timeline_since(first)
    opened = [r for r in rows if r.type == "turn:initiated" and r.source == "galaxy-ledger/stop"]
    if fate == "absorbed":
        if opened or s.leftovers():
            return Result(name, "FAIL", "a turn was opened for a message the running turn absorbed")
        return Result(name, "PASS", "folded into the running turn; correctly opened nothing")
    if fate != "dequeued":
        return Result(name, "INCONCLUSIVE", f"the queued message was {fate}")
    hit = next((r for r in opened if r.msg.startswith(queued)), None)
    if not hit:
        return Result(name, "FAIL", "no galaxy-ledger/stop turn opened for the queued message")
    if not any(r.type == "turn:completed" and r.id < hit.id for r in rows):
        return Result(name, "FAIL", "the new turn's start was recorded before the old turn's end")
    if not any(r.type == "turn:completed" and r.did == hit.did for r in rows):
        return Result(name, "FAIL", "the queued message's turn never closed")
    if s.leftovers():
        return Result(name, "FAIL", f"left behind: {', '.join(s.leftovers())}")
    stop_done = parse_ts(s.stops()[stops]["timestamp"])
    gap = (picked_up - stop_done).total_seconds() * 1000
    return Result(name, "PASS", f"opened at Stop; picked up {gap:.0f}ms after the Stop hook finished")


def queued_interrupt(s):
    name = "queued-interrupt"
    since, first, stops = now(), s.timeline_max(), len(s.stops())
    s.type_line("Explain in about 1200 words how a ship's chronometer works. Use no tools.")
    if not wait_for(s.state_path.exists, 30):
        return Result(name, "FAIL", "the turn never started")
    time.sleep(1.2)
    queued = f"{MARK} two: reply with only the word ok."
    s.type_line(queued)
    wait_for(s.pending_path.exists, 5)
    if len(s.stops()) != stops or not s.state_path.exists():
        return Result(name, "INCONCLUSIVE", "the turn ended before it could be interrupted")
    ended_at, _ = s.interrupt_like_galaxy()
    wait_for(lambda: len(s.stops()) >= stops + 1, 120)
    time.sleep(2)
    fate, picked_up = s.fate(queued, since)
    if fate != "dequeued":
        return Result(name, "INCONCLUSIVE", f"the queued message was {fate}")
    if picked_up <= ended_at:
        return Result(name, "INCONCLUSIVE", "picked up before the Escape; the turn had already ended")
    rows = s.timeline_since(first)
    interrupted = next((r for r in rows if r.type == "turn:interrupted"), None)
    hit = next((r for r in rows if r.type == "turn:initiated"
                and r.source == "galaxy-app/interrupt" and r.msg.startswith(queued)), None)
    if not interrupted or not hit:
        return Result(name, "FAIL", "no galaxy-app/interrupt turn opened for the queued message")
    if hit.id < interrupted.id:
        return Result(name, "FAIL", "the new turn's start was recorded before the interrupt")
    if not any(r.type == "turn:completed" and r.did == hit.did for r in rows):
        return Result(name, "FAIL", "the queued message's turn never closed")
    if s.leftovers():
        return Result(name, "FAIL", f"left behind: {', '.join(s.leftovers())}")
    margin = (picked_up - ended_at).total_seconds() * 1000
    return Result(name, "PASS", f"keystroke timestamp {margin:.0f}ms before the pickup")


def batched(s):
    name = "batched"
    since, first, stops = now(), s.timeline_max(), len(s.stops())
    target = int(time.time()) + 20
    command = f"python3 -c 'import time; time.sleep(max(0, {target} - time.time()))'"
    s.type_line("Make two separate Bash tool calls, each with run_in_background set to "
                f"true, both running exactly: {command} . Do not wait for them or check "
                "on them. After starting both, reply with only: started.")
    if not wait_for(lambda: len(s.stops()) >= stops + 1, 60):
        return Result(name, "FAIL", "the turn that starts the tasks never finished")
    wait_for(lambda: time.time() > target + 5 and len(s.stops()) >= stops + 2
             and not s.state_path.exists(), 90)
    time.sleep(2)
    ops = s.queue_ops(since)
    notes = [o for o in ops if o.op == "enqueue" and o.content.startswith("<task-notification>")]
    together = any(
        b.at - a.at <= timedelta(milliseconds=50)
        and sum(1 for o in ops if o.op == "dequeue"
                and timedelta(0) <= o.at - b.at <= timedelta(milliseconds=50)) >= 2
        for a, b in zip(notes, notes[1:]))
    if not together:
        return Result(name, "INCONCLUSIVE", "the notifications arrived separately, so the batched case did not occur")
    rows = s.timeline_since(first)
    launched = next((r for r in rows if r.type == "turn:completed"), None)
    later = [r for r in rows if launched and r.id > launched.id]
    opens = [r for r in later if r.type == "turn:initiated"]
    phantom = [r for r in opens if r.source == "galaxy-ledger/stop"]
    if phantom:
        return Result(name, "FAIL", "a phantom turn was opened for the second notification")
    if len(opens) != 1:
        return Result(name, "FAIL", f"expected one turn for the batch, found {len(opens)}")
    if s.leftovers():
        return Result(name, "FAIL", f"left behind: {', '.join(s.leftovers())}")
    return Result(name, "PASS", "two notifications delivered in one turn; no phantom turn")


def idle_backstop(s):
    name = "idle-backstop"
    wait_for(lambda: not s.state_path.exists(), 60)
    first = s.timeline_max()
    stale = str(uuid.uuid4())
    s.state_path.parent.mkdir(parents=True, exist_ok=True)
    s.state_path.write_text(json.dumps({
        "uuid": stale, "user_message": "planted stale turn",
        "initiated_at": (now() - timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ")}))
    planted = time.time()
    # The idle notification comes a minute after the last turn ended.
    if not wait_for(lambda: not s.state_path.exists(), 100):
        s.state_path.unlink(missing_ok=True)
        return Result(name, "FAIL", "the stale turn was still open 100s after the session went idle")
    closed_after = time.time() - planted
    time.sleep(1)
    if not any(r.type == "turn:abandoned" and r.source == "galaxy-ledger/idle"
               and r.did == "turn--" + stale for r in s.timeline_since(first)):
        return Result(name, "FAIL", "the turn was removed but no turn:abandoned was recorded")
    return Result(name, "PASS", f"stale turn closed {closed_after:.0f}s after it was planted")


def nested_oneshot(s):
    name = "nested-oneshot"
    word = "PELICAN"
    wait_for(lambda: not s.state_path.exists(), 60)
    first, stops = s.timeline_max(), len(s.stops())
    count = "select count(*) from {}"
    ids_before = s.q(s.db_ledger, count.format("ledger_session_identifiers"))
    pids_before = s.q(s.db_ledger, count.format("ledger_session_pids"))
    s.type_line("Run this exact command with the Bash tool, then reply with only the "
                f"word it printed: {s.oneshot_command(word)}")
    if not wait_for(lambda: len(s.stops()) >= stops + 1, 120):
        return Result(name, "FAIL", "the turn running the one-shot never finished")
    wait_for(lambda: not s.state_path.exists(), 15)
    time.sleep(2)
    if not any(word in r for r in s.tool_results()):
        return Result(name, "INCONCLUSIVE", "the nested claude never answered, so the case did not occur")
    events = s.q(s.db_timeline, "select event_type, source from events "
                 "where id > ? order by id", (first,))
    strays = [e for e, _ in events if e in ("session:started", "session:ended", "turn:abandoned")]
    if strays:
        return Result(name, "FAIL", f"the one-shot reached the session: {', '.join(strays)}")
    turns = [e for e, _ in events if e.startswith("turn:")]
    if turns != ["turn:initiated", "turn:completed"]:
        return Result(name, "FAIL", f"expected the one turn to open and close, found {turns}")
    if s.q(s.db_ledger, count.format("ledger_session_identifiers")) != ids_before \
            or s.q(s.db_ledger, count.format("ledger_session_pids")) != pids_before:
        return Result(name, "FAIL", "the one-shot's identifier or pid joined the session")
    if s.leftovers():
        return Result(name, "FAIL", f"left behind: {', '.join(s.leftovers())}")
    return Result(name, "PASS", "a claude -p run inside the session left it untouched")


SCENARIOS = {
    "queued-at-stop": queued_at_stop,
    "queued-interrupt": queued_interrupt,
    "batched": batched,
    "idle-backstop": idle_backstop,
    "nested-oneshot": nested_oneshot,
}


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--ledger", type=Path, default=INSTALLED_LEDGER,
                        help="galaxy-ledger binary the session's hooks run (default: installed)")
    parser.add_argument("--model", default="haiku")
    parser.add_argument("--only", help="comma-separated scenarios: " + ", ".join(SCENARIOS))
    parser.add_argument("--cwd", type=Path, default=REPO,
                        help="directory the session starts in; must be trusted (default: repo root)")
    parser.add_argument("--keep", action="store_true",
                        help="keep the sandbox and transcript even when everything passes")
    args = parser.parse_args()

    ledger = args.ledger.expanduser().resolve()
    names = args.only.split(",") if args.only else list(SCENARIOS)
    unknown = [n for n in names if n not in SCENARIOS]
    if unknown:
        parser.error(f"unknown scenario: {', '.join(unknown)}")
    for binary in (ledger, TIMELINE):
        if not os.access(binary, os.X_OK):
            parser.error(f"not executable: {binary}")

    sandbox = Path(tempfile.mkdtemp(prefix="galaxy-e2e-"))
    s = Session(sandbox, ledger, args.model, args.cwd)
    color = sys.stdout.isatty()
    paint = {"PASS": "32", "FAIL": "31", "INCONCLUSIVE": "33"}

    print("galaxy-ledger turn tracking, end to end")
    print(f"  session  {s.sid}\n  sandbox  {sandbox}\n  hooks    {ledger}")
    print(f"  submit   {'reserved chord' if s.submit_bytes[0] == RESERVED_SUBMIT else 'Return'}"
          f"\n  model    {args.model}\n")

    results = []
    try:
        s.start()
        s.wait_ready()
        for name in names:
            try:
                result = SCENARIOS[name](s)
            except Failure as e:
                result = Result(name, "FAIL", str(e))
            status = f"\033[{paint[result.status]}m{result.status}\033[0m" if color else result.status
            print(f"  {result.name:<17} {status:<{21 if color else 12}} {result.detail}", flush=True)
            results.append(result)
    except Failure as e:
        results.append(Result("setup", "FAIL", str(e)))
        print(f"  setup  FAIL  {e}")
    finally:
        ran = {c for r in s.stops() for c in
               [h.get("command", "") for h in (r.get("hookInfos") or []) if isinstance(h, dict)]}
        s.stop()

    stop_hooks = [c for c in ran if "on-stop" in c]
    if stop_hooks and not any(str(ledger) in c or (ledger == INSTALLED_LEDGER
                                                   and "galaxy/bin/galaxy-ledger" in c)
                              for c in stop_hooks):
        results.append(Result("hooks", "FAIL", f"the session ran {stop_hooks[0]}, not {ledger}"))
        print(f"  hooks  FAIL  the session ran {stop_hooks[0]}, not {ledger}")

    counts = {k: sum(r.status == k for r in results) for k in ("PASS", "FAIL", "INCONCLUSIVE")}
    print(f"\n  {counts['PASS']} passed, {counts['FAIL']} failed, {counts['INCONCLUSIVE']} inconclusive")

    transcript = s.transcript()
    if counts["FAIL"] or args.keep:
        print(f"  kept: {sandbox}" + (f"\n        {transcript}" if transcript else ""))
    else:
        shutil.rmtree(sandbox, ignore_errors=True)
        if transcript:
            transcript.unlink(missing_ok=True)
    sys.exit(1 if counts["FAIL"] else 0)


if __name__ == "__main__":
    main()
