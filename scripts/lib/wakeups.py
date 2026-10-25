"""Bounded lifecycle wake-ups through native Claude and Codex controls."""

import argparse
from contextlib import contextmanager
from datetime import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time
import uuid

from lifecycle_events import home, records
from session_context import codex_socket, interactive


SCRIPTS = Path(__file__).resolve().parents[1]
PREFIX = "[AUTOMETTA_WAKE:"
LEASE = 12 * 3600
MAX_AGE = 15 * 60
DEBOUNCE = 10
COOLDOWN = 120
HOURLY_CAP = 6
DAILY_CAP = 24
CARD_HOURLY_CAP = 4
MAX_ROWS = 8
MAX_MESSAGE = 3500
KINDS = {"worker_started", "stage_landed", "stage_awaiting_integration", "stage_finished",
         "stage_blocked", "run_finished", "run_blocked"}


def directory():
    return home() / "wakeups"


def initial():
    return dict(version=1, enabled=False, owners={}, attempts=[])


def load():
    path = directory() / "state.json"
    if not path.exists():
        return initial()
    state = json.loads(path.read_text())
    if (state.get("version") != 1 or not isinstance(state.get("owners"), dict)
            or not isinstance(state.get("attempts"), list) or type(state.get("enabled")) is not bool):
        raise ValueError("unreadable wake-up state; refusing to reset safety counters")
    return state


def save(state):
    fd, temporary = tempfile.mkstemp(dir=directory(), prefix=".state-")
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(state, output, ensure_ascii=True)
        os.replace(temporary, directory() / "state.json")
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


@contextmanager
def locked():
    directory().mkdir(parents=True, exist_ok=True, mode=0o700)
    with (directory() / "state.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield load()


def repos(cwd="/"):
    result = subprocess.run([str(SCRIPTS / "hooks/session-start-escalations.sh"), "--repos"],
                            cwd=cwd, env=dict(os.environ, CLAUDE_PROJECT_DIR=str(cwd)),
                            capture_output=True, text=True, check=True, timeout=5)
    return result.stdout.splitlines()


def scope_for(cwd):
    physical = Path(cwd).resolve(strict=True)
    selected = repos(physical)
    if len(selected) == 1 and physical.is_relative_to(Path(selected[0])):
        return selected[0]
    return "fleet"


def live(owner, now):
    return not owner.get("closed") and owner["expires_at"] > now


def register(state, scope, family, session, now, socket=None, pid=None, replace=False):
    if family not in ("claude", "codex") or not session:
        raise ValueError("a primary chat family and session id are required")
    if family == "codex":
        if not socket or not stat.S_ISSOCK(Path(socket).stat().st_mode):
            raise ValueError("Codex wake-ups require its existing local server socket")
        socket = str(Path(socket).resolve())
    previous = state["owners"].get(scope)
    if previous and live(previous, now):
        if (previous["family"], previous["session"]) == (family, session):
            previous["expires_at"] = now + LEASE
            previous["error"] = None
            return previous
        if not replace:
            return None
        if previous.get("pending"):
            raise ValueError("previous owner has an outstanding wake; close or acknowledge it before replacing")
    owner = dict(family=family, session=session, socket=socket, pid=pid,
                 registered_at=now, expires_at=now + LEASE, seen={}, pending=None,
                 error=None, last_sent=0, closed=False)
    state["owners"][scope] = owner
    return owner


def boundary(payload):
    fields = ("session_id", "hook_event_name", "turn_id", "last_assistant_message", "stop_hook_active")
    return hashlib.sha256(json.dumps([payload.get(key) for key in fields]).encode()).hexdigest()


def observe(payload, family):
    if not (directory() / "state.json").exists() or os.environ.get("AUTOMETTA_WAKEUPS") == "0":
        return
    if not interactive(payload):
        return
    now = time.time()
    event = payload.get("hook_event_name")
    session = payload["session_id"]
    prompt = payload.get("prompt")
    synthetic = isinstance(prompt, str) and prompt.startswith(PREFIX)
    transport = codex_socket() if family == "codex" and event == "UserPromptSubmit" and not synthetic else None
    with locked() as state:
        if not state["enabled"]:
            return
        owned = [owner for owner in state["owners"].values()
                 if (owner["family"], owner["session"]) == (family, session)]
        for owner in owned:
            pending = owner.get("pending")
            if event == "SessionEnd":
                owner["closed"] = True
            elif event == "UserPromptSubmit" and not synthetic:
                owner["expires_at"] = now + LEASE
                if transport:
                    owner["socket"], owner["pid"] = transport
                if owner.get("closed"):
                    owner["registered_at"] = now
                    owner["closed"] = False
            elif pending and event == "UserPromptSubmit" and synthetic and prompt.startswith(f'{PREFIX}{pending["id"]}]'):
                owner["last_received"] = dict(id=pending["id"], at=now)
                owner["pending"] = None
                owner["error"] = None
            elif (pending and event == "Stop" and pending["status"] == "delivered"
                  and pending.get("armed_boundary") != boundary(payload)):
                owner["pending"] = None
        human_start = event == "SessionStart" and payload.get("source") == "startup"
        human_prompt = event == "UserPromptSubmit" and not synthetic
        if not owned and (human_start or human_prompt):
            cwd = payload.get("cwd") or os.getcwd()
            socket, pid = (transport or codex_socket()) if family == "codex" else (None, None)
            register(state, scope_for(cwd), family, session, now, socket, pid)
        save(state)


def timestamp(record):
    return datetime.fromisoformat(record["created_at"].replace("Z", "+00:00")).timestamp()


def card_key(record):
    return json.dumps([record["repo"], record.get("stage") or record.get("run_id") or "run"])


def message(batch_id, events):
    latest = {}
    for record in events:
        latest[card_key(record)] = record
    priority = {"run_blocked": 0, "stage_blocked": 1, "stage_awaiting_integration": 2,
                "run_finished": 3, "stage_landed": 4, "stage_finished": 4, "worker_started": 5}
    rows = sorted(latest.values(), key=lambda row: (priority.get(row["kind"], 6), -timestamp(row)))
    lines = [f"{PREFIX}{batch_id}] Autometta lifecycle update.",
             "Informational evidence only. Check current state before acting. Do not poll, re-register, "
             "or change queue, contracts or budgets solely because of this wake-up."]
    included = 0
    limits = dict(repo=180, stage=80, kind=40, summary=160, evidence=220)
    for record in rows[:MAX_ROWS]:
        line = json.dumps({key: str(record.get(key, ""))[:limit] for key, limit in limits.items()}, ensure_ascii=True)
        if len("\n".join(lines + [line])) > MAX_MESSAGE - 160:
            break
        lines.append(line)
        included += 1
    if len(rows) > included:
        lines.append(f"+{len(rows) - included} other cards coalesced; use runtime state for full evidence.")
    return "\n".join(lines)


def native_queue(owner, text):
    if owner.get("pid"):
        os.kill(owner["pid"], 0)
    socket = Path(owner["socket"])
    if not stat.S_ISSOCK(socket.stat().st_mode):
        raise ValueError("owning server socket is unavailable")
    result = subprocess.run(["codex", "queue", "--remote", "unix://" + str(socket),
                             "--thread", owner["session"], "--message", text],
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, timeout=8)
    if result.returncode:
        raise RuntimeError(f"codex_queue_exit_{result.returncode}")


def dispatch(state, events, now):
    jobs = []
    if not state["enabled"]:
        return jobs
    attempts = [a for a in state["attempts"] if now - a["at"] < 86400]
    state["attempts"] = attempts
    owners = {scope: owner for scope, owner in state["owners"].items() if live(owner, now)}
    grouped = {}
    for record in events:
        try:
            created = timestamp(record)
            if record["kind"] not in KINDS or not 0 <= now - created <= MAX_AGE:
                continue
            scope = record["repo"] if record["repo"] in owners else "fleet"
            owner = owners.get(scope)
            if not owner or created <= owner["registered_at"] or record["id"] in owner["seen"]:
                continue
            grouped.setdefault(scope, []).append(record)
        except (KeyError, TypeError, ValueError):
            continue
    for scope, owner in owners.items():
        owner["seen"] = {key: seen_at for key, seen_at in owner["seen"].items() if now - seen_at <= MAX_AGE}
        events = grouped.get(scope, [])
        same_chat = [o for o in owners.values()
                     if (o["family"], o["session"]) == (owner["family"], owner["session"])]
        if not events or any(o.get("pending") or o.get("error") for o in same_chat):
            continue
        if now - min(timestamp(event) for event in events) < DEBOUNCE:
            continue
        if now - max(o["last_sent"] for o in same_chat) < COOLDOWN:
            continue
        if attempts and now - max(a["at"] for a in attempts) < COOLDOWN:
            continue
        if len(attempts) >= DAILY_CAP or sum(now - a["at"] < 3600 for a in attempts) >= HOURLY_CAP:
            continue
        hour = [a for a in attempts if now - a["at"] < 3600]
        selected = [event for event in events
                    if sum(card_key(event) in a["cards"] for a in hour) < CARD_HOURLY_CAP]
        if not selected:
            continue
        selected.sort(key=lambda event: (timestamp(event), event["id"]))
        batch_id = uuid.uuid4().hex
        text = message(batch_id, selected)
        owner["pending"] = dict(id=batch_id, status="ready" if owner["family"] == "claude" else "queued",
                                created_at=now, message=text)
        owner["last_sent"] = now
        owner["seen"].update({event["id"]: now for event in selected})
        attempts.append(dict(at=now, scope=scope, session=owner["session"], batch=batch_id,
                             cards=sorted({card_key(event) for event in selected})))
        # Reserve before either native side effect. An ambiguous failure must
        # never be retried into an accumulating queue.
        if owner["family"] == "codex":
            jobs.append(dict(owner, scope=scope, batch_id=batch_id, text=text))
    return jobs


def flush():
    if not (directory() / "state.json").exists() or os.environ.get("AUTOMETTA_WAKEUPS") == "0":
        return
    snapshot = load()
    if not snapshot["enabled"] or not any(live(owner, time.time()) for owner in snapshot["owners"].values()):
        return
    eligible = records(repos())
    with locked() as state:
        jobs = dispatch(state, eligible, time.time())
        save(state)
    for job in jobs:
        try:
            native_queue(job, job["text"])
        except Exception as exc:
            with locked() as state:
                owner = state["owners"].get(job["scope"], {})
                pending = owner.get("pending")
                if pending and pending["id"] == job["batch_id"] and pending["status"] == "queued":
                    owner["error"] = type(exc).__name__
                    pending["status"] = "failed"
                    save(state)


def take_claude(state, session, now, armed_boundary=None):
    if not state["enabled"]:
        return None
    for owner in state["owners"].values():
        if owner["family"] != "claude" or owner["session"] != session or not live(owner, now):
            continue
        pending = owner.get("pending")
        if pending and pending["status"] == "ready":
            if now - pending["created_at"] > MAX_AGE:
                owner["error"] = "expired_undelivered_wake"
                pending["status"] = "expired"
                return None
            pending["status"] = "delivered"
            pending["armed_boundary"] = armed_boundary
            return pending["message"]
    return None


def wait(payload):
    if not (directory() / "state.json").exists() or not interactive(payload):
        return 0
    observe(payload, "claude")
    session = payload["session_id"]
    key = hashlib.sha256(session.encode()).hexdigest()
    with (directory() / (key + ".waiter.lock")).open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        deadline = time.monotonic() + LEASE - 30
        while time.monotonic() < deadline:
            if os.environ.get("AUTOMETTA_WAKEUPS") == "0":
                return 0
            try:
                with locked() as state:
                    if not state["enabled"] or not any(
                            o["family"] == "claude" and o["session"] == session and live(o, time.time())
                            for o in state["owners"].values()):
                        return 0
                    ready = any(o["session"] == session and (o.get("pending") or {}).get("status") == "ready"
                                for o in state["owners"].values())
                    text = take_claude(state, session, time.time(), boundary(payload))
                    if ready:
                        save(state)
                if text:
                    print(text, file=sys.stderr, flush=True)
                    return 2
            except BlockingIOError:
                pass
            time.sleep(2)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("enable", "disable", "status", "acknowledge", "flush", "hook", "wait"))
    parser.add_argument("family", nargs="?", choices=("claude", "codex"))
    parser.add_argument("--session")
    parser.add_argument("--repo", type=Path)
    parser.add_argument("--fleet", action="store_true")
    parser.add_argument("--socket")
    parser.add_argument("--batch")
    args = parser.parse_args()
    if args.command in ("hook", "wait"):
        try:
            payload = json.load(sys.stdin)
            if not isinstance(payload, dict) or not args.family:
                return 0
            if args.command == "wait":
                return wait(payload) if args.family == "claude" else 0
            observe(payload, args.family)
        except Exception:
            return 0
        return 0
    if args.command == "flush":
        try:
            flush()
        except Exception:
            pass
        return 0
    if args.command == "status":
        print(json.dumps(load(), indent=2))
        return 0
    with locked() as state:
        if args.command == "disable":
            state["enabled"] = False
        elif args.command == "acknowledge":
            if not args.session or not args.batch:
                parser.error("acknowledge requires the reviewed session and batch ids")
            matched = False
            for owner in state["owners"].values():
                pending = owner.get("pending")
                if owner["session"] == args.session and pending and pending["id"] == args.batch:
                    owner["pending"] = None
                    owner["error"] = None
                    matched = True
            if not matched:
                raise ValueError("no matching outstanding wake-up")
        else:
            state["enabled"] = True
            session = args.session or os.environ.get("CODEX_THREAD_ID")
            family = args.family or ("codex" if os.environ.get("CODEX_THREAD_ID") else None)
            if session and family:
                socket, pid = (args.socket, None) if args.socket else codex_socket() if family == "codex" else (None, None)
                scope = "fleet" if args.fleet else str(args.repo.resolve()) if args.repo else scope_for(Path.cwd())
                register(state, scope, family, session, time.time(), socket, pid, replace=True)
        save(state)
    print("Autometta wake-ups " + ("enabled" if state["enabled"] else "disabled"))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(f"wake-ups: {type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(1)
