#!/usr/bin/env python3
"""Polling and curses event loop for the Autometta TUI."""
import argparse
import curses
import shlex
import json
import locale
import os
import queue
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from render import (ACTIVE, ALERT, BOLD, DIM, NORMAL, REVERSE, TuiState,
                    ordered_run_stages, render)
from messages import read_bus, write_pending


def payload_from_aggregator(aggregator, repo_root):
    result = subprocess.run(
        [aggregator, "--repo", repo_root], check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


_NO_PAYLOAD = object()


def _poll(results, generation, started_at, aggregator, repo_root, payload):
    try:
        value = (payload_from_aggregator(aggregator, repo_root)
                 if payload is _NO_PAYLOAD else payload)
        error = None
    except Exception as caught:
        value = None
        error = caught
    results.put({
        "generation": generation,
        "started_at": started_at,
        "payload": value,
        "error": error,
    })


def start_poll(results, generation, started_at, aggregator, repo_root, payload=_NO_PAYLOAD):
    thread = threading.Thread(
        target=_poll,
        args=(results, generation, started_at, aggregator, repo_root, payload),
        name="autometta-tui-poll-%d" % generation,
        daemon=True,
    )
    thread.start()
    return thread


def apply_poll_result(state, result, latest_generation):
    if result["generation"] != latest_generation:
        return False
    if result["error"] is not None:
        state.poll_failed(str(result["error"]))
    else:
        state.update(result["payload"], observed_at=result["started_at"],
                     data_started_at=result["started_at"])
    return True


def fixture_polls(path):
    with open(path, "r", encoding="utf-8") as handle:
        document = json.load(handle)
    polls = document.get("polls") if isinstance(document, dict) else document
    if not isinstance(polls, list) or not polls:
        raise ValueError("fixture must contain a non-empty polls array")
    return polls


def refresh_controller(state, repo_root):
    state.update_controller(read_bus(repo_root))


def open_card(repo_root, card_path):
    """Show a stage card. Returns a short notice for the footer.

    Inside tmux the card opens as its own window, which is what an operator
    watching a run actually wants: the TUI keeps painting, and the card is a
    window switch away rather than a modal that has to be dismissed. Outside
    tmux there is nowhere to put it, so fall back to suspending curses around
    a pager. Never shell out to an editor: this is a read path, and a card the
    worker is mid-dispatch on must not be editable by accident.
    """
    path = card_path if os.path.isabs(card_path) else os.path.join(repo_root, card_path)
    if not os.path.exists(path):
        return "card not found: %s" % card_path
    if os.environ.get("TMUX"):
        window_name = os.path.basename(path)[:20] or "card"
        try:
            subprocess.run(
                ["tmux", "new-window", "-n", window_name,
                 "%s %s" % (os.environ.get("PAGER", "less"), shlex.quote(path))],
                check=True, capture_output=True)
        except (OSError, subprocess.CalledProcessError) as error:
            return "could not open a tmux window: %s" % error
        return "opened %s in a tmux window" % os.path.basename(path)
    try:
        curses.endwin()
        subprocess.run([os.environ.get("PAGER", "less"), path], check=False)
    except OSError as error:
        return "could not page the card: %s" % error
    return "viewed %s" % os.path.basename(path)


# A card is a prompt, not a document; anything past this is a card that has
# gone wrong, and reading it whole belongs in the pager that o opens.
CARD_BODY_MAX_LINES = 400


def ensure_card_body(state, repo_root):
    """Keep the detail pane's card text in step with the pinned stage.

    render.py is rendered in the smokes against fixtures with no repo on disk,
    so it stays a pure function of state: the file read lives here and the card
    is handed over as data.
    """
    stage = next((item for item in ordered_run_stages(state.payload)
                  if item.get("id") == state.pinned_stage), None)
    if not stage:
        if state.card_body_stage is not None:
            state.card_body = []
            state.card_body_stage = None
            state.card_offset = 0
        return
    stage_id = stage.get("id")
    if state.card_body_stage == stage_id:
        return
    path = stage.get("card") or "stage-cards/%s.md" % stage_id
    if not os.path.isabs(path):
        path = os.path.join(repo_root, path)
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            body = handle.read().splitlines()[:CARD_BODY_MAX_LINES]
    except OSError as error:
        body = ["could not read the card: %s" % error]
    state.card_body = body
    state.card_body_stage = stage_id
    state.card_offset = 0


def open_card_external(repo_root, card_path):
    """Hand the card to the desktop's default handler for .md.

    Separate from open_card because it is a different promise: that opens a
    pager and guarantees the file cannot be changed, this opens whatever the
    desktop associates with .md, which on most machines can write. The notice
    says so, since the operator cannot see what got launched.
    """
    path = card_path if os.path.isabs(card_path) else os.path.join(repo_root, card_path)
    if not os.path.exists(path):
        return "card not found: %s" % card_path
    if sys.platform == "darwin":
        opener = ["open", path]
    elif os.name == "posix":
        opener = ["xdg-open", path]
    else:
        return "no default opener on this platform; press o to page it"
    try:
        subprocess.run(opener, check=True, capture_output=True)
    except FileNotFoundError:
        return "no %s on PATH; press o to page it" % opener[0]
    except (OSError, subprocess.CalledProcessError) as error:
        return "could not open the card: %s" % error
    return "opened %s in the default viewer (editable)" % os.path.basename(path)


def apply_key(state, key, repo_root):
    action = state.key(key)
    if not action:
        return
    kind, message = action
    if kind == "open_card":
        state.card_notice = open_card(repo_root, message)
        return
    if kind == "open_card_external":
        state.card_notice = open_card_external(repo_root, message)
        return
    if kind != "submit":
        return
    try:
        message_id = write_pending(repo_root, message)
        controller = read_bus(repo_root)
    except (OSError, ValueError) as error:
        state.compose_failed(str(error))
        return
    observed = any(
        row.get("id") == message_id and row.get("status") == "pending"
        for row in controller.get("conversation") or [])
    state.update_controller(controller)
    if observed:
        state.compose_done("queued for the controller's next pass")
    else:
        state.compose_failed("write completed but the pending message was not observed")


def capture(args):
    state = TuiState(args.interval)
    if args.fixture:
        polls = fixture_polls(args.fixture)
    else:
        polls = [payload_from_aggregator(args.aggregator, args.repo_root)]
    for index, payload in enumerate(polls):
        state.update(payload, observed_at=index * args.interval)
        refresh_controller(state, args.repo_root)
    ensure_card_body(state, args.repo_root)
    for key in filter(None, (part.strip() for part in args.keys.split(","))):
        apply_key(state, key, args.repo_root)
        ensure_card_body(state, args.repo_root)
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


def paint(stdscr, canvas, frame_log=None):
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
    if frame_log is not None:
        frame_log.write(json.dumps({"at": time.monotonic(), "text": canvas.text()}) + "\n")
        frame_log.flush()


def interactive(args):
    polls = fixture_polls(args.fixture) if args.fixture else None
    poll_index = 0
    results = queue.Queue()
    latest_generation = 0
    in_flight_generation = None
    frame_log_path = os.environ.get("AUTOMETTA_TUI_FRAME_LOG")
    frame_log = open(frame_log_path, "w", encoding="utf-8") if frame_log_path else None
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
            if state.observe_time(now):
                dirty = True
            while True:
                try:
                    result = results.get_nowait()
                except queue.Empty:
                    break
                if result["generation"] == in_flight_generation:
                    in_flight_generation = None
                if apply_poll_result(state, result, latest_generation):
                    if result["error"] is None:
                        refresh_controller(state, args.repo_root)
                    dirty = True
            if now >= next_poll and in_flight_generation is None:
                latest_generation += 1
                started_at = now
                payload = _NO_PAYLOAD
                if polls:
                    payload = polls[min(poll_index, len(polls) - 1)]
                    poll_index += 1
                state.poll_started(started_at)
                start_poll(results, latest_generation, started_at, args.aggregator,
                           args.repo_root, payload)
                in_flight_generation = latest_generation
                next_poll = started_at + args.interval
                ensure_card_body(state, args.repo_root)
                dirty = True
            if dirty:
                height, width = stdscr.getmaxyx()
                paint(stdscr, render(state, width, height), frame_log)
                dirty = False
            key = stdscr.getch()
            if key == -1:
                continue
            if key == curses.KEY_RESIZE:
                dirty = True
                continue
            if key in (ord("q"), ord("Q")) and not state.composing:
                break
            mapping = {
                curses.KEY_DOWN: "DOWN", curses.KEY_UP: "UP", curses.KEY_ENTER: "ENTER",
                10: "ENTER", 13: "ENTER", 9: "TAB", 27: "ESC",
                curses.KEY_BACKSPACE: "BACKSPACE", 127: "BACKSPACE", 8: "BACKSPACE",
            }
            apply_key(state, mapping.get(key, chr(key) if 0 <= key < 256 else ""), args.repo_root)
            ensure_card_body(state, args.repo_root)
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
        if frame_log is not None:
            frame_log.close()


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
