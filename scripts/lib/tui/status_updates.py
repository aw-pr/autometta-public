#!/usr/bin/env python3
"""Recent loop status updates for one repo, for the TUI's panel 5.

The tick log is the loop narrating what it is doing: which stage it
dispatched, what it reaped, why it paused, what it refused. It is already the
most-read thing in the tmux layout (the `log` window is a tail of exactly
this), but nothing inside the TUI surfaced it, so a reader watching the panels
had to leave them to find out why nothing was moving.

Lines are filtered to the repo, because one log carries every subscriber.
"""
import os
import re

# A panel, not a pager: enough to say what just happened, not a history.
MAX_ROWS = 40
# Reading the tail of a log the tick appends to all day. 256 kB back is
# thousands of lines, far more than MAX_ROWS survives, and bounds the read on
# a file that has grown to megabytes by evening.
TAIL_BYTES = 256 * 1024


def _log_dir():
    home = os.environ.get("PHAT_CONTROLLER_HOME")
    if home:
        return os.path.join(home, "log")
    return os.path.join(os.path.expanduser("~"), ".phat-controller", "log")


def _latest_log(log_dir):
    """The newest tick-YYYY-MM-DD.log. Named by date, so lexical order is
    chronological and today's file sorts last."""
    try:
        names = sorted(name for name in os.listdir(log_dir)
                       if name.startswith("tick-") and name.endswith(".log"))
    except OSError:
        return None
    return os.path.join(log_dir, names[-1]) if names else None


def _strip_stamp(line):
    """Drop the leading ISO stamp, keeping the clock. The date is today's on
    every row worth showing and the panel is narrow."""
    head, _, rest = line.partition(" ")
    if len(head) == 20 and head.endswith("Z") and head[4] == "-":
        return head[11:19], rest
    return "", line


def read_status_updates(repo_root, limit=MAX_ROWS):
    """Return [(clock, text)] for this repo, oldest first.

    Empty when there is no log yet, which is the honest answer for a host
    whose loop has not run rather than an error worth drawing.
    """
    path = _latest_log(_log_dir())
    if not path:
        return []
    try:
        size = os.path.getsize(path)
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            if size > TAIL_BYTES:
                handle.seek(size - TAIL_BYTES)
                handle.readline()  # discard the partial line the seek landed in
            lines = handle.read().splitlines()
    except OSError:
        return []

    repo_root = os.path.normpath(repo_root)
    name = os.path.basename(repo_root)
    # A plain substring test is wrong here: every sibling whose path starts
    # with this one matches it, so the autometta panel filled with
    # autometta-testing rows. The path must end at a character that cannot
    # continue a directory name.
    boundary = re.compile(re.escape(repo_root) + r"(?![\w.-])")
    rows = []
    for line in lines:
        if not boundary.search(line):
            continue
        clock, text = _strip_stamp(line)
        # The path is how the line was matched, but it is also most of its
        # width and the same on every row. The repo is named by the panel.
        text = text.replace(repo_root + "/", "").replace(repo_root, name)
        rows.append((clock, " ".join(text.split())))
    return rows[-limit:]


def age_line(data_started_at, monotonic_now, polling):
    """The refresh line. This used to sit in the status panel, where it
    appeared and vanished with every poll and shoved four lines up and down
    under the reader's eye. Here it is the panel's own subject, so it can
    change as often as it likes without moving anything."""
    if data_started_at is None:
        return "first poll running"
    # The age is a fact about the data on screen, so it is shown whether or not
    # a request is in flight. Suppressing it while polling hid exactly the case
    # worth seeing: a slow poll leaves stale figures up for as long as it takes,
    # and "refreshing now" would have said nothing about how old they were.
    age = max(0, int(monotonic_now - data_started_at))
    suffix = " · refreshing" if polling else ""
    return "refreshed %ds ago%s" % (age, suffix)
