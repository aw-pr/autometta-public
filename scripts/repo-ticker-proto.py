#!/usr/bin/env python3
"""repo-ticker-proto.py: prototype per-repo ticker for stage card 44.

Not wired into anything. Nothing in the loop calls it, and it writes to no
repo. Run it in a spare pane while the controller works:

    scripts/repo-ticker-proto.py ~/repos/emergence-lab

What it prototypes, in the order card 44 asks for it:

  * in-flight tokens that tick up, read from the agent's own live session
    transcript rather than from a log the agent has not written yet
  * alerts first and always visible, never scrolled off the top
  * a frame that fits the pane it is in, at whatever width and height
  * a repaint that overwrites the previous frame in one write, so the pane is
    never observed half-drawn

It is a long-lived process on purpose. That is what makes the transcript read
incremental: each refresh parses only the bytes appended since the last one,
so the cost of a frame does not grow with a transcript that reaches tens of
megabytes during one overnight run.
"""

import calendar
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from collections import deque

HOME = os.path.expanduser("~")
CLAUDE_PROJECTS = os.path.join(HOME, ".claude", "projects")
CODEX_SESSIONS = os.path.join(HOME, ".codex", "sessions")

USE_COLOUR = sys.stdout.isatty() and not os.environ.get("NO_COLOUR") \
    and not os.environ.get("NO_COLOR")


def paint(text, code):
    return "\x1b[%sm%s\x1b[0m" % (code, text) if USE_COLOUR else text


RED = lambda s: paint(s, "31")
GREEN = lambda s: paint(s, "32")
YELLOW = lambda s: paint(s, "33")
DIM = lambda s: paint(s, "2")
BOLD = lambda s: paint(s, "1")


def short_tokens(n):
    n = int(n or 0)
    if n >= 1_000_000_000:
        return "%.1fB" % (n / 1_000_000_000)
    if n >= 1_000_000:
        return "%.1fM" % (n / 1_000_000)
    if n >= 1_000:
        return "%.1fK" % (n / 1_000)
    return str(n)


def short_secs(s):
    try:
        s = int(s)
    except (TypeError, ValueError):
        return "?"
    if s < 60:
        return "%ds" % s
    if s < 3600:
        return "%dm%02ds" % (s // 60, s % 60)
    return "%dh%02dm" % (s // 3600, (s % 3600) // 60)


def parse_iso(ts):
    if not ts:
        return None
    ts = ts.strip().strip('"').strip("'")
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S.%fZ"):
        try:
            return calendar.timegm(time.strptime(ts, fmt))
        except ValueError:
            continue
    return None


# ---------------------------------------------------------------- transcripts

def agent_cwd(pid):
    """The directory the agent was launched in.

    This is what keys a Claude transcript, and card 39 gave every run its own
    worktree, so it is not the repo root. state/active-agents/<pid>.json does
    not record it, which is one of the gaps card 44 names; lsof answers it
    without changing the registry, which is what makes this a prototype.
    """
    try:
        out = os.popen("lsof -a -p %d -d cwd -Fn 2>/dev/null" % int(pid)).read()
    except (OSError, ValueError):
        return None
    for line in out.splitlines():
        if line.startswith("n/"):
            return line[1:]
    return None


def claude_transcript(cwd, started_at):
    """Newest transcript in the project directory keyed by this cwd."""
    if not cwd:
        return None
    slug = re.sub(r"[^A-Za-z0-9]", "-", cwd)
    d = os.path.join(CLAUDE_PROJECTS, slug)
    best, best_mtime = None, 0
    try:
        names = os.listdir(d)
    except OSError:
        return None
    for n in names:
        if not n.endswith(".jsonl"):
            continue
        p = os.path.join(d, n)
        try:
            m = os.path.getmtime(p)
        except OSError:
            continue
        # A worktree is reused across dispatches, so the directory holds the
        # previous agent's transcript too. Only files touched since this agent
        # started can be this agent's.
        if started_at and m < started_at - 120:
            continue
        if m > best_mtime:
            best, best_mtime = p, m
    return best


_codex_index = {"scanned_at": 0.0, "by_cwd": {}}


def codex_transcript(cwd, started_at):
    """Rollout whose session_meta cwd matches, started closest after the agent.

    Codex rollouts are not keyed by path, so the cwd lives inside the file.
    The index is rebuilt at most once a minute; reading first lines of every
    recent rollout on every frame would blow the refresh budget.
    """
    if not cwd:
        return None
    now = time.time()
    if now - _codex_index["scanned_at"] > 60:
        by_cwd = {}
        cutoff = now - 3 * 86400
        for root, _dirs, files in os.walk(CODEX_SESSIONS):
            for n in files:
                if not n.startswith("rollout-") or not n.endswith(".jsonl"):
                    continue
                p = os.path.join(root, n)
                try:
                    if os.path.getmtime(p) < cutoff:
                        continue
                    with open(p, errors="replace") as fh:
                        head = fh.readline()
                    meta = json.loads(head).get("payload") or {}
                except (OSError, ValueError):
                    continue
                c = meta.get("cwd")
                if c:
                    by_cwd.setdefault(c, []).append(p)
        _codex_index["by_cwd"] = by_cwd
        _codex_index["scanned_at"] = now
    candidates = _codex_index["by_cwd"].get(cwd) or []
    best, best_mtime = None, 0
    for p in candidates:
        try:
            m = os.path.getmtime(p)
        except OSError:
            continue
        if started_at and m < started_at - 120:
            continue
        if m > best_mtime:
            best, best_mtime = p, m
    return best


class TranscriptReader:
    """Incremental token total for one transcript file.

    Claude records per-message usage, so the total is a running sum. Codex
    records a cumulative total_token_usage, so the total is the last one seen.
    Both are summed over every usage key present: cache reads dominate a long
    run, and dropping them understates the figure by an order of magnitude.
    """

    CLAUDE_KEYS = ("input_tokens", "output_tokens",
                   "cache_creation_input_tokens", "cache_read_input_tokens")

    def __init__(self, path, family):
        self.path = path
        self.family = family
        self.offset = 0
        self.total = 0
        self.samples = deque(maxlen=240)

    def poll(self):
        try:
            size = os.path.getsize(self.path)
        except OSError:
            return self.total
        if size < self.offset:          # rotated or replaced
            self.offset, self.total = 0, 0
        if size > self.offset:
            try:
                with open(self.path, errors="replace") as fh:
                    fh.seek(self.offset)
                    chunk = fh.read()
                    # Never consume a half-written final line.
                    cut = chunk.rfind("\n")
                    if cut == -1:
                        return self.total
                    self.offset += len(chunk[:cut + 1].encode("utf-8", "replace"))
                    self._consume(chunk[:cut + 1])
            except OSError:
                pass
        self.samples.append((time.time(), self.total))
        return self.total

    def _consume(self, text):
        for line in text.splitlines():
            if '"usage"' not in line and '"total_token_usage"' not in line:
                continue
            try:
                doc = json.loads(line)
            except ValueError:
                continue
            if self.family == "codex":
                info = doc.get("payload") or doc
                usage = info.get("total_token_usage") or \
                    (info.get("info") or {}).get("total_token_usage")
                if isinstance(usage, dict):
                    t = usage.get("total_tokens")
                    if isinstance(t, int):
                        self.total = max(self.total, t)
                continue
            usage = (doc.get("message") or {}).get("usage") or doc.get("usage")
            if isinstance(usage, dict):
                self.total += sum(usage.get(k) or 0 for k in self.CLAUDE_KEYS
                                  if isinstance(usage.get(k), int))

    def rate_per_min(self):
        """Tokens per minute over the trailing window, or None if too new."""
        if len(self.samples) < 2:
            return None
        now, latest = self.samples[-1]
        for ts, value in self.samples:
            if now - ts <= 120:
                if now - ts < 20:
                    return None
                return (latest - value) * 60.0 / (now - ts)
        return None


# ---------------------------------------------------------------- repo state

def read_state_stages(state_path):
    """state.yaml as text, the way agent-ticker.sh reads it. It is JSON in
    practice but yaml by contract, and this prototype adds no dependency."""
    stages, cur = [], {}
    try:
        with open(state_path, errors="replace") as fh:
            body = fh.read()
    except OSError:
        return stages
    try:
        doc = json.loads(body)
        for s in doc.get("stages") or []:
            stages.append((s.get("id"), s.get("status")))
        return stages
    except ValueError:
        pass
    for line in body.splitlines():
        s = line.strip()
        if s.startswith("- id:"):
            if cur:
                stages.append((cur.get("id"), cur.get("status")))
            cur = {"id": s.split(":", 1)[1].strip().strip('"')}
        elif s.startswith("status:") and cur:
            cur["status"] = s.split(":", 1)[1].strip().strip('",')
    if cur:
        stages.append((cur.get("id"), cur.get("status")))
    return stages


def _alert_statuses():
    """The alert-worthy stage statuses, read from the one definition in the
    tree (scripts/alert-statuses.sh) rather than restated here."""
    helper = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                          "alert-statuses.sh")
    out = subprocess.run(["bash", helper], capture_output=True, text=True,
                         check=True).stdout
    return frozenset(json.loads(out))


TERMINAL_BAD = _alert_statuses()


def collect_alerts(repo, stages):
    alerts = []
    budget_path = os.path.join(repo, "state", "budget.json")
    try:
        with open(budget_path) as fh:
            b = json.load(fh)
        if b.get("halted"):
            alerts.append(("halt", "budget halted: %s" %
                           (b.get("halt_reason") or "unknown")))
        cf = b.get("consecutive_failures") or 0
        if cf:
            alerts.append(("fail", "consecutive failures %s/%s" %
                           (cf, b.get("consecutive_failure_cap", 3))))
    except (OSError, ValueError):
        pass

    hb = os.path.join(repo, "state", "heartbeat.json")
    try:
        with open(hb) as fh:
            rep = json.load(fh)
        age = time.time() - (parse_iso(rep.get("checked_at")) or 0)
        # A heartbeat only runs when the controller ticks, so a few minutes
        # of age is normal between ticks and is not worth a line in a panel
        # this small. Only real silence earns one.
        if age > 1200:
            alerts.append(("halt", "heartbeat %s stale, controller may have "
                           "stopped" % short_secs(age)))
        elif age > 600:
            alerts.append(("warn", "heartbeat %s old" % short_secs(age)))
        for e in rep.get("entries") or []:
            for flag in e.get("flags") or []:
                if flag != "fresh":
                    alerts.append(("warn", "%s %s: %s" % (
                        e.get("family", "?"), e.get("role", "?"), flag)))
    except (OSError, ValueError):
        pass

    for sid, status in stages:
        if status in TERMINAL_BAD:
            detail = ""
            art = os.path.join(repo, "state", "verifiers", "%s.json" % sid)
            try:
                with open(art) as fh:
                    a = json.load(fh)
                for c in a.get("criteria") or []:
                    if c.get("verdict") == "FAIL":
                        detail = " crit %s" % c.get("id")
                        break
            except (OSError, ValueError):
                pass
            alerts.append(("fail", "%s %s%s" % (sid, status, detail)))
    return alerts


def spend_lines(repo, width):
    budget_path = os.path.join(repo, "state", "budget.json")
    cost_path = os.path.join(repo, "state", "cost-log.jsonl")
    spent = cap = 0
    try:
        with open(budget_path) as fh:
            b = json.load(fh)
        spent = b.get("tokens_spent") or 0
        cap = b.get("token_cap_total") or 0
    except (OSError, ValueError):
        pass
    today_cost = 0.0
    midnight = time.time() - (time.time() % 86400)
    try:
        with open(cost_path, errors="replace") as fh:
            fh.seek(0, 2)
            fh.seek(max(0, fh.tell() - 1_000_000))
            for line in fh.read().splitlines()[1:]:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if (parse_iso(row.get("ts")) or 0) >= midnight:
                    today_cost += row.get("cost_usd_est") or 0
    except OSError:
        pass
    pct = (spent * 100.0 / cap) if cap else 0.0
    window = "window %s/%s (%.1f%%)" % (short_tokens(spent),
                                        short_tokens(cap), pct)
    today = "today $%.2f est" % today_cost
    # Fold rather than truncate: a spend figure cut off mid-number is worse
    # than a spend figure on its own line.
    if width < 56:
        return ["SPEND  " + window, "       " + today]
    return ["SPEND  %s   %s" % (window, today)]


# ---------------------------------------------------------------- the frame

readers = {}


def in_flight_lines(repo, width):
    active_dir = os.path.join(repo, "state", "active-agents")
    lines = []
    try:
        names = sorted(os.listdir(active_dir))
    except OSError:
        names = []
    live = []
    for n in names:
        if not n.endswith(".json"):
            continue
        try:
            with open(os.path.join(active_dir, n)) as fh:
                e = json.load(fh)
        except (OSError, ValueError):
            continue
        pid = e.get("pid")
        try:
            os.kill(int(pid), 0)
        except (OSError, TypeError, ValueError):
            continue                      # exited but not yet reaped
        live.append(e)

    if not live:
        return [DIM("  (nothing in flight)")]

    for e in live:
        pid = int(e["pid"])
        family = e.get("family", "?")
        role = e.get("role", "?")
        card = os.path.basename(e.get("card_path") or "-").replace(".md", "")
        started = parse_iso(e.get("started_at")) or time.time()
        elapsed = time.time() - started
        budget = e.get("budget_seconds") or 0

        # Resolution is retried every frame until it succeeds, and only a
        # success is cached. A CLI does not create its transcript at exec:
        # op-fetch, prompt assembly and CLI start-up put seconds between the
        # registry entry and the first transcript byte, and caching that first
        # miss pinned the pane to "tokens unavailable" for the whole run.
        reader = readers.get(pid)
        if reader is None:
            cwd = agent_cwd(pid)
            path = (claude_transcript(cwd, started) if family == "claude"
                    else codex_transcript(cwd, started))
            if path:
                reader = TranscriptReader(path, family)
                readers[pid] = reader
        total = reader.poll() if reader else None
        rate = reader.rate_per_min() if reader else None

        head = "  %s %s %s" % (BOLD(role), family, card)
        lines.append(head[:width + (len(head) - len(strip_ansi(head)))])

        if total is None:
            # Distinguish the normal opening seconds from a genuine miss.
            # Both render as no number, and only one of them is a problem.
            tok = (DIM("waiting for transcript") if elapsed < 120
                   else YELLOW("tokens unavailable (no transcript found)"))
        else:
            tok = BOLD("%s tok" % short_tokens(total))
            if rate is not None:
                tok += "  +%s/min" % short_tokens(rate)
        budget_txt = ""
        if budget:
            frac = elapsed / budget
            txt = "%s/%s" % (short_secs(elapsed), short_secs(budget))
            budget_txt = RED(txt) if frac > 0.9 else (
                YELLOW(txt) if frac > 0.75 else txt)
        else:
            budget_txt = short_secs(elapsed)
        lines.append("    %s  %s" % (budget_txt, tok))
    return lines


ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


def strip_ansi(s):
    return ANSI_RE.sub("", s)


def fit(line, width):
    """Truncate on printable width, keeping the escape codes intact."""
    plain = strip_ansi(line)
    if len(plain) <= width:
        return line
    if line == plain:
        return line[:width - 1] + "…"
    return plain[:width - 1] + "…" + "\x1b[0m"


def build_frame(repo, width, height, interval):
    name = os.path.basename(repo.rstrip("/"))
    stages = read_state_stages(os.path.join(repo, "state", "state.yaml"))
    alerts = collect_alerts(repo, stages)
    pending = sum(1 for _i, s in stages if s == "pending")
    running = sum(1 for _i, s in stages if s in ("in_progress", "in_flight"))

    rule = "─" * width
    head_state = RED("%d alert(s)" % len(alerts)) if alerts else GREEN("clear")
    lines = [
        BOLD("%s  %s  %s" % (name, time.strftime("%H:%M:%SZ", time.gmtime()),
                             head_state)),
        DIM(rule),
        "IN FLIGHT",
    ]
    lines += in_flight_lines(repo, width)
    lines += [DIM(rule)]

    # Alerts are never the panel that gets trimmed: they are why the pane is
    # on screen. Everything below them yields height first.
    if alerts:
        lines.append(RED("ALERTS (%d)" % len(alerts)))
        alert_lines = []
        for kind, text in alerts:
            mark = RED("!") if kind in ("fail", "halt") else YELLOW("~")
            alert_lines.append("  %s %s" % (mark, text))
        lines += alert_lines
    else:
        lines.append(GREEN("ALERTS  none"))

    tail = [
        DIM(rule),
    ] + spend_lines(repo, width) + [
        "QUEUE  %d pending · %d running" % (pending, running),
        DIM("refresh %ss · prototype for card 44 · Ctrl+C to quit"
            % interval),
    ]

    # Fit to height. Trim the alert list before the tail panels, because a
    # trimmed alert list still says how many it is hiding, and a dropped SPEND
    # line says nothing at all. Never let the terminal do the trimming by
    # scrolling: that is the fault this prototype exists to demonstrate.
    room = height - len(tail)
    if len(lines) > room:
        keep = max(1, room - 1)
        hidden = len(lines) - keep
        lines = lines[:keep] + [DIM("  ... %d more line(s) hidden, widen or "
                                    "grow this pane" % hidden)]
    frame = lines + [""] * max(0, room - len(lines)) + tail
    return [fit(l, width) for l in frame[:height]]


def main():
    args = [a for a in sys.argv[1:]]
    if not args or args[0] in ("-h", "--help"):
        sys.stderr.write("usage: repo-ticker-proto.py <repo_root> [--once] "
                         "[--interval N]\n")
        return 2
    repo = os.path.abspath(os.path.expanduser(args[0]))
    once = "--once" in args
    interval = 3
    if "--interval" in args:
        try:
            interval = max(1, int(args[args.index("--interval") + 1]))
        except (IndexError, ValueError):
            pass
    if not os.path.isdir(os.path.join(repo, "state")):
        sys.stderr.write("no state/ under %s\n" % repo)
        return 3

    if once:
        size = shutil.get_terminal_size((80, 24))
        sys.stdout.write("\n".join(
            build_frame(repo, size.columns, size.lines - 1, interval)) + "\n")
        return 0

    stop = {"now": False}
    signal.signal(signal.SIGINT, lambda *_a: stop.__setitem__("now", True))
    signal.signal(signal.SIGTERM, lambda *_a: stop.__setitem__("now", True))

    sys.stdout.write("\x1b[?25l\x1b[2J")           # hide cursor, clear once
    try:
        while not stop["now"]:
            size = shutil.get_terminal_size((80, 24))
            frame = build_frame(repo, size.columns, size.lines, interval)
            # One write, over the top of the previous frame. \x1b[K clears to
            # end of line so a shorter line cannot leave the old tail behind,
            # and \x1b[J clears any rows a shorter frame no longer covers.
            out = "\x1b[H" + "\x1b[K\r\n".join(frame) + "\x1b[K\x1b[J"
            sys.stdout.write(out)
            sys.stdout.flush()
            for _ in range(interval * 10):
                if stop["now"]:
                    break
                time.sleep(0.1)
    finally:
        sys.stdout.write("\x1b[?25h\n")
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
