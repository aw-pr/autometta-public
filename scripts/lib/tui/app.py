#!/usr/bin/env python3
"""Polling and curses event loop for the Autometta TUI."""
import argparse
import curses
import json
import locale
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from render import ACTIVE, ALERT, BOLD, DIM, NORMAL, REVERSE, TuiState, render


def payload_from_aggregator(aggregator, repo_root):
    result = subprocess.run(
        [aggregator, "--repo", repo_root], check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def fixture_polls(path):
    with open(path, "r", encoding="utf-8") as handle:
        document = json.load(handle)
    polls = document.get("polls") if isinstance(document, dict) else document
    if not isinstance(polls, list) or not polls:
        raise ValueError("fixture must contain a non-empty polls array")
    return polls


def capture(args):
    state = TuiState(args.interval)
    if args.fixture:
        polls = fixture_polls(args.fixture)
    else:
        polls = [payload_from_aggregator(args.aggregator, args.repo_root)]
    for index, payload in enumerate(polls):
        state.update(payload, observed_at=index * args.interval)
    for key in filter(None, (part.strip() for part in args.keys.split(","))):
        state.key(key)
    sys.stdout.write(render(state, args.width, args.height).text(args.ansi) + "\n")


def curses_attr(attr):
    if attr == BOLD:
        return curses.A_BOLD
    if attr == REVERSE:
        return curses.A_REVERSE
    if attr == ACTIVE:
        return curses.A_BOLD | (curses.color_pair(1) if curses.has_colors() else 0)
    if attr == ALERT:
        return curses.A_BOLD | (curses.color_pair(2) if curses.has_colors() else 0)
    if attr == DIM:
        return curses.A_DIM
    return curses.A_NORMAL


def paint(stdscr, canvas):
    stdscr.erase()
    for y, (chars, attrs) in enumerate(zip(canvas.cells, canvas.attrs)):
        x = 0
        while x < canvas.width:
            attr = attrs[x]
            end = x + 1
            while end < canvas.width and attrs[end] == attr:
                end += 1
            try:
                stdscr.addstr(y, x, "".join(chars[x:end]), curses_attr(attr))
            except curses.error:
                pass
            x = end
    stdscr.refresh()


def interactive(args):
    polls = fixture_polls(args.fixture) if args.fixture else None
    poll_index = 0
    stdscr = curses.initscr()
    configured = False
    try:
        curses.noecho()
        curses.cbreak()
        configured = True
        stdscr.keypad(True)
        stdscr.timeout(100)
        try:
            curses.curs_set(0)
        except curses.error:
            pass
        if curses.has_colors():
            curses.start_color()
            curses.use_default_colors()
            curses.init_pair(1, curses.COLOR_CYAN, -1)
            curses.init_pair(2, curses.COLOR_RED, -1)

        state = TuiState(args.interval)
        next_poll = 0.0
        dirty = True
        while True:
            now = time.monotonic()
            if now >= next_poll:
                try:
                    if polls:
                        payload = polls[min(poll_index, len(polls) - 1)]
                        poll_index += 1
                    else:
                        payload = payload_from_aggregator(args.aggregator, args.repo_root)
                    state.update(payload, now)
                    dirty = True
                except (OSError, ValueError, subprocess.SubprocessError) as error:
                    failed = dict(state.payload)
                    failed["state_error"] = str(error)
                    state.update(failed, now)
                    dirty = True
                next_poll = now + args.interval
            if dirty:
                height, width = stdscr.getmaxyx()
                paint(stdscr, render(state, width, height))
                dirty = False
            key = stdscr.getch()
            if key == -1:
                continue
            if key == curses.KEY_RESIZE:
                dirty = True
                continue
            if key in (ord("q"), ord("Q")):
                break
            mapping = {
                curses.KEY_DOWN: "DOWN", curses.KEY_UP: "UP", curses.KEY_ENTER: "ENTER",
                10: "ENTER", 13: "ENTER", 9: "TAB",
            }
            state.key(mapping.get(key, chr(key) if 0 <= key < 256 else ""))
            dirty = True
    finally:
        try:
            stdscr.keypad(False)
        except curses.error:
            pass
        if configured:
            try:
                curses.nocbreak()
                curses.echo()
            except curses.error:
                pass
        curses.endwin()


def main():
    locale.setlocale(locale.LC_ALL, "")
    parser = argparse.ArgumentParser()
    parser.add_argument("repo_root")
    parser.add_argument("aggregator")
    parser.add_argument("--interval", type=float, default=5.0)
    parser.add_argument("--capture", action="store_true")
    parser.add_argument("--width", type=int, default=119)
    parser.add_argument("--height", type=int, default=40)
    parser.add_argument("--fixture")
    parser.add_argument("--keys", default="")
    parser.add_argument("--ansi", action="store_true")
    args = parser.parse_args()
    if args.interval <= 0:
        parser.error("--interval must be greater than zero")
    if args.capture:
        capture(args)
    else:
        try:
            interactive(args)
        except KeyboardInterrupt:
            return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
