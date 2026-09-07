#!/usr/bin/env bash
# Offline proof for stage card 132: the dashboard shows its own pulse.
#
# Everything here drives render() directly against a synthetic state, so no
# assertion depends on a live repo, a running tick, or the wall clock of the
# machine it runs on.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/132-the-dashboard-shows-its-own-pulse.md
python3 - "$script_dir/lib/tui/render.py" <<'PY' || fail "132: the dashboard does not tick once per second"
import importlib.util, sys, re

spec = importlib.util.spec_from_file_location("autometta_tui_render", sys.argv[1])
render = importlib.util.module_from_spec(spec)
spec.loader.exec_module(render)

WIDTH, HEIGHT = 120, 30

def frame(state):
    return render.render(state, WIDTH, HEIGHT).text()

# The payload must render a token figure, or the "tokens did not move"
# assertion below is vacuously true against a frame that shows no number.
# agents[].live_total_tokens is what the run row's token column reads
# (render.stage_total), and current_run.started_at is required or
# status_lines raises.
payload = {
    "_now": 1_800_000_000,
    "agents": [{"stage_id": "01-example", "live_total_tokens": 1234567}],
    "current_run": {
        "id": "run-smoke",
        "started_at": "2026-09-07T12:00:00Z",
        "stages": [
            {"id": "01-example", "status": "in_progress",
             "worker": "Claude Sonnet 5 <claude-sonnet-5@local>",
             "verifier": "Codex GPT-5.6 Sol <codex-gpt-5-6-sol@local>",
             "started_at": "2026-09-07T12:00:00Z"},
        ],
    },
}

state = render.TuiState(5.0)
state.update(payload, observed_at=0.0)

# The poll cadence is 5s; the pulse is 1s. A frame taken one second after
# another, with no new payload, must differ -- that difference is the whole
# point of the card. Without it the operator cannot tell a live dashboard
# from a frozen one, which is the failure this card exists to remove.
state.observe_time(100.0)
first = frame(state)
state.observe_time(101.0)
second = frame(state)
if first == second:
    fail_msg = "132: two frames one second apart are byte-identical; nothing on screen moves"
    raise SystemExit(fail_msg)

# The moving element is a clock the operator can read, not only an
# animation. Somewhere in the frame there is an HH:MM:SS that advances by
# exactly one second between those two frames.
def clocks(text):
    return re.findall(r"\b([0-9]{2}:[0-9]{2}:[0-9]{2})\b", text)

def to_secs(hms):
    h, m, s = (int(part) for part in hms.split(":"))
    return h * 3600 + m * 60 + s

first_clocks, second_clocks = clocks(first), clocks(second)
if not first_clocks:
    raise SystemExit("132: no HH:MM:SS clock is rendered anywhere in the frame")
advanced = [
    (a, b) for a, b in zip(first_clocks, second_clocks)
    if (to_secs(b) - to_secs(a)) % 86400 == 1
]
if not advanced:
    raise SystemExit(
        "132: no rendered clock advanced by one second between frames "
        "(first=%r second=%r)" % (first_clocks, second_clocks))

# A pulse must not invent data. Between polls the token figure is unchanged,
# because no new reading has arrived -- card 103's rule, that the dashboard
# does not invent a number it was not given, is not suspended by making the
# display live.
def token_figures(text):
    return re.findall(r"1,234k", text)
if not token_figures(first):
    raise SystemExit(
        "132: no token figure rendered, so the no-invented-data assertion "
        "would be vacuous; fix the fixture, not the assertion")
if token_figures(first) != token_figures(second):
    raise SystemExit("132: the token figure changed between polls; the pulse invented data")

# And the pulse must survive a poll that fails. A dashboard that freezes
# exactly when its seam breaks is telling the operator the opposite of the
# truth.
state.poll_failed("synthetic seam failure")
state.observe_time(200.0)
third = frame(state)
state.observe_time(201.0)
fourth = frame(state)
if third == fourth:
    raise SystemExit("132: the pulse stopped while the seam was failing")
PY
# AUTOMETTA-CONTRACT-END

printf 'PASS: the dashboard ticks once per second, reads as a clock, invents no data, and keeps pulsing through a failed poll\n'
