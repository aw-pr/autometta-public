#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
repo="$fixture/repo"
polls="$fixture/polls.json"
mkdir -p "$repo"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  [[ "$1" == *"$2"* ]] || fail "$3"
}

assert_not_contains() {
  [[ "$1" != *"$2"* ]] || fail "$3"
}

long_id="36-this-stage-identifier-is-deliberately-fifty-eight-characters-long"

cat > "$polls" <<EOF
{"polls":[
  {
    "_now":1787731200,"name":"autometta","current_stage":"68-a-pipeline-pair","last_tick_at":"2026-08-26T07:59:18Z","tick_count":214,"run_started_at":"2026-08-26T06:12:09Z","tokens_spent":12400000,"effective_token_cap":150000000,"verifier_attempt_cap":3,
    "spend":{"tokens_total":12400000,"cost_usd_est":9.12,"by_stage":[{"stage_id":"68-a-pipeline-pair","input_tokens":2000000,"cached_input_tokens":300000,"output_tokens":1000,"tokens":2300000,"cost_usd_est":1.87},{"stage_id":"50-cards","input_tokens":3000000,"cached_input_tokens":750000,"output_tokens":50000,"tokens":3800000,"cost_usd_est":2.41}]},
    "stages":[
      {"id":"65-loop-stamps-hb","status":"completed","worker":"GPT-5.6 Sol <gpt-5-6-sol@local>","verifier":"Claude Fable 5 <claude-fable-5@local>","tokens":412000,"card":"stage-cards/65-loop-stamps-hb.md"},
      {"id":"66-fleet-view-fits","status":"completed","worker":"GPT-5.6 Sol <gpt-5-6-sol@local>","verifier":"Claude Fable 5 <claude-fable-5@local>","tokens":9100000,"card":"stage-cards/66-fleet-view-fits.md"},
      {"id":"67-outlier-says-so","status":"completed","worker":"Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>","verifier":"Claude Fable 5 <claude-fable-5@local>","tokens":1200000,"card":"stage-cards/67-outlier-says-so.md"},
      {"id":"68-a-pipeline-pair","status":"in_progress","worker":"GPT-5.6 Sol <gpt-5-6-sol@local>","verifier":"Claude Fable 5 <claude-fable-5@local>","verifier_attempts":2,"tokens":2300000,"card":"stage-cards/68-a-pipeline-pair.md","acceptance":"scripts/pipeline-pair-smoke.sh"},
      {"id":"50-cards","status":"in_progress","worker":"Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>","verifier":"Claude Fable 5 <claude-fable-5@local>","verifier_attempts":1,"tokens":3800000,"card":"stage-cards/50-cards.md"},
      {"id":"69-tui","status":"pending","worker":"GPT-5.6 Sol <gpt-5-6-sol@local>","verifier":"Claude Fable 5 <claude-fable-5@local>","tokens":0,"card":"stage-cards/69-tui.md"},
      {"id":"$long_id","status":"verifier_failed","worker":"Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>","verifier":"Claude Fable 5 <claude-fable-5@local>","tokens":76000000,"card":"stage-cards/$long_id.md"}
    ],
    "agents":[
      {"stage_id":"68-a-pipeline-pair","role":"worker","identity":"GPT-5.6 Sol <gpt-5-6-sol@local>","elapsed_seconds":192,"budget_seconds":1800,"live_total_tokens":2300000},
      {"stage_id":"50-cards","role":"verifier","identity":"Claude Fable 5 <claude-fable-5@local>","elapsed_seconds":63,"budget_seconds":1200,"live_total_tokens":3800000}
    ]
  },
  {
    "_now":1787731205,"name":"autometta","current_stage":"68-a-pipeline-pair","last_tick_at":"2026-08-26T07:59:18Z","tick_count":215,"run_started_at":"2026-08-26T06:12:09Z","tokens_spent":12401200,"effective_token_cap":150000000,"verifier_attempt_cap":3,
    "spend":{"tokens_total":12401200,"cost_usd_est":9.12,"by_stage":[{"stage_id":"68-a-pipeline-pair","input_tokens":2000000,"cached_input_tokens":300000,"output_tokens":2200,"tokens":2301200,"cost_usd_est":1.87},{"stage_id":"50-cards","input_tokens":3000000,"cached_input_tokens":750000,"output_tokens":50000,"tokens":3800000,"cost_usd_est":2.41}]},
    "stages":[
      {"id":"65-loop-stamps-hb","status":"completed","worker":"GPT-5.6 Sol <gpt-5-6-sol@local>","verifier":"Claude Fable 5 <claude-fable-5@local>","tokens":412000,"card":"stage-cards/65-loop-stamps-hb.md"},
      {"id":"66-fleet-view-fits","status":"completed","worker":"GPT-5.6 Sol <gpt-5-6-sol@local>","verifier":"Claude Fable 5 <claude-fable-5@local>","tokens":9100000,"card":"stage-cards/66-fleet-view-fits.md"},
      {"id":"67-outlier-says-so","status":"completed","worker":"Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>","verifier":"Claude Fable 5 <claude-fable-5@local>","tokens":1200000,"card":"stage-cards/67-outlier-says-so.md"},
      {"id":"68-a-pipeline-pair","status":"in_progress","worker":"GPT-5.6 Sol <gpt-5-6-sol@local>","verifier":"Claude Fable 5 <claude-fable-5@local>","verifier_attempts":2,"tokens":2301200,"card":"stage-cards/68-a-pipeline-pair.md","acceptance":"scripts/pipeline-pair-smoke.sh"},
      {"id":"50-cards","status":"in_progress","worker":"Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>","verifier":"Claude Fable 5 <claude-fable-5@local>","verifier_attempts":1,"tokens":3800000,"card":"stage-cards/50-cards.md"},
      {"id":"69-tui","status":"pending","worker":"GPT-5.6 Sol <gpt-5-6-sol@local>","verifier":"Claude Fable 5 <claude-fable-5@local>","tokens":0,"card":"stage-cards/69-tui.md"},
      {"id":"$long_id","status":"verifier_failed","worker":"Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>","verifier":"Claude Fable 5 <claude-fable-5@local>","tokens":76000000,"card":"stage-cards/$long_id.md"}
    ],
    "agents":[
      {"stage_id":"68-a-pipeline-pair","role":"worker","identity":"GPT-5.6 Sol <gpt-5-6-sol@local>","elapsed_seconds":197,"budget_seconds":1800,"live_total_tokens":2301200},
      {"stage_id":"50-cards","role":"verifier","identity":"Claude Fable 5 <claude-fable-5@local>","elapsed_seconds":68,"budget_seconds":1200,"live_total_tokens":3800000}
    ]
  }
]}
EOF

capture() {
  local width="$1" height="$2" keys="${3:-}" ansi="${4:-false}"
  LC_ALL=C.UTF-8 TERM=xterm-256color AUTOMETTA_TUI_CAPTURE=true \
    AUTOMETTA_TUI_COLUMNS="$width" AUTOMETTA_TUI_ROWS="$height" \
    AUTOMETTA_TUI_INTERVAL=5 AUTOMETTA_TUI_FIXTURE_POLLS="$polls" \
    AUTOMETTA_TUI_KEYS="$keys" AUTOMETTA_TUI_ANSI="$ansi" \
    "$script_dir/tui.sh" "$repo"
}

frame80="$(capture 80 60)"
frame119="$(capture 119 40)"
frame160="$(capture 160 40)"

for frame in "$frame80" "$frame119" "$frame160"; do
  for panel in '[0]─Card detail' '[1]─Status' '[2]─This run' '[3]─Agents' '[4]─Escalations & inbox'; do
    assert_contains "$frame" "$panel" "missing panel $panel"
  done
  assert_contains "$frame" '[1]run [2]history [3]messages' "missing page tabs"
  assert_contains "$frame" "$long_id" "long stage id was truncated or hidden"
  for stage_id in 65-loop-stamps-hb 66-fleet-view-fits 67-outlier-says-so 68-a-pipeline-pair 50-cards 69-tui; do
    assert_contains "$frame" "$stage_id" "stage id $stage_id was truncated or hidden"
  done
  assert_contains "$frame" 'sol→fable' "worker-to-verifier pairing was lost"
  assert_contains "$frame" 'terra→fable' "second worker-to-verifier pairing was lost"
  assert_contains "$frame" 'Claude Fable 5 <claude-fable-5@local>' "full verifier identity was truncated"
  for status in "done" WORKER VERIFY queued ESCALTD; do
    assert_contains "$frame" "$status" "status word $status was truncated or hidden"
  done
  assert_not_contains "$frame" '…' "a frame used silent identifying-column truncation"
done

assert_contains "$frame119" '▶  68-a-pipeline-pair  WORKER  sol→fable' "119-column wide row missing"
assert_contains "$frame160" '▶  68-a-pipeline-pair  WORKER  sol→fable' "160-column wide row missing"
AUTOMETTA_TEST_FRAME="$frame80" python3 - <<'PY' || fail "80-column pairing did not wrap"
import os
lines = os.environ["AUTOMETTA_TEST_FRAME"].splitlines()
stage = next(i for i, line in enumerate(lines) if "68-a-pipeline-pair" in line)
assert "sol→fable" not in lines[stage]
assert "sol→fable" in lines[stage + 1]
PY

for spec in "80:$frame80" "119:$frame119" "160:$frame160"; do
  width="${spec%%:*}"
  frame="${spec#*:}"
  AUTOMETTA_TEST_FRAME="$frame" AUTOMETTA_TEST_WIDTH="$width" python3 - <<'PY' || fail "$width-column frame overflowed"
import os
width = int(os.environ["AUTOMETTA_TEST_WIDTH"])
assert all(len(line) <= width for line in os.environ["AUTOMETTA_TEST_FRAME"].splitlines())
PY
done

ansi="$(capture 119 40 '' true)"
assert_contains "$ansi" $'\033[1;36msol' "active worker alias was not emphasised"
assert_contains "$ansi" $'\033[1;36mfable' "active verifier alias was not emphasised"

assert_contains "$frame119" 'GPT-5.6 Sol <gpt-5-6-sol@local>' "detail omitted worker identity"
assert_contains "$frame119" 'Claude Fable 5 <claude-fable-5@local>' "detail omitted verifier identity"
assert_contains "$frame119" 'attempt   2 of 3' "detail omitted attempt"
assert_contains "$frame119" 'budget    3m17s / 30m00s (10% used)' "detail omitted budget"
assert_contains "$frame119" 'tokens  in 2.0M  cached 300.0K  out 2.2K' "detail omitted token breakdown"
assert_contains "$frame119" "\$1.87" "detail omitted stage cost"
assert_contains "$frame119" '14.4K/min' "burn rate was not computed from the 1,200-token poll delta"

after="$(capture 119 40 '2,j,ENTER')"
assert_contains "$frame119" 'stage-cards/68-a-pipeline-pair.md' "initial detail card is wrong"
assert_contains "$after" 'stage-cards/50-cards.md' "enter did not repopulate card detail"

history="$(capture 119 40 ']')"
messages="$(capture 119 40 '],]')"
returned="$(capture 119 40 '2,j,ENTER,],],]')"
assert_contains "$history" 'no historic dispatches' "empty history page missing"
assert_contains "$messages" 'arrives with card 71' "messages placeholder missing"
assert_contains "$returned" 'stage-cards/50-cards.md' "page round-trip disturbed run-page state"

AUTOMETTA_TEST_80="$frame80" AUTOMETTA_TEST_119="$frame119" AUTOMETTA_TEST_160="$frame160" python3 - <<'PY' || fail "layouts were not genuinely different"
import os
f80, f119, f160 = (os.environ[name].splitlines() for name in ("AUTOMETTA_TEST_80", "AUTOMETTA_TEST_119", "AUTOMETTA_TEST_160"))
assert f80 != f119 != f160
assert next(i for i, line in enumerate(f80) if "[0]─Card detail" in line) > next(i for i, line in enumerate(f80) if "[4]─Escalations" in line)
assert any("[1]─Status" in line and "[0]─Card detail" in line for line in f119)
assert any("[1]─Status" in line and "[0]─Card detail" in line for line in f160)
assert len(f80) == 60 and "and " not in os.environ["AUTOMETTA_TEST_80"]
PY

assert_not_contains "$(grep -Ev '^\s*#' "$script_dir/tui.sh" "$script_dir/lib/tui/app.py" "$script_dir/lib/tui/render.py")" 'state.yaml' "TUI opens state.yaml directly"
assert_not_contains "$(grep -Ev '^\s*#' "$script_dir/tui.sh" "$script_dir/lib/tui/app.py" "$script_dir/lib/tui/render.py")" 'cost-log' "TUI opens cost-log directly"
assert_contains "$(sed -n '/def payload_from_aggregator/,/return json.loads/p' "$script_dir/lib/tui/app.py")" '"--repo"' "poller does not use aggregate-dashboard --repo"

LC_ALL=C.UTF-8 TERM=xterm-256color python3 - "$script_dir/tui.sh" "$repo" "$polls" <<'PY' || fail "q did not restore sane terminal flags"
import fcntl, os, pty, signal, sys, termios, time
pid, terminal = pty.fork()
env = dict(os.environ, AUTOMETTA_TUI_FIXTURE_POLLS=sys.argv[3], AUTOMETTA_TUI_INTERVAL="60")
if pid == 0:
    os.execve(sys.argv[1], [sys.argv[1], sys.argv[2]], env)
before = termios.tcgetattr(terminal)
fcntl.fcntl(terminal, fcntl.F_SETFL, fcntl.fcntl(terminal, fcntl.F_GETFL) | os.O_NONBLOCK)
send_at = time.time() + 0.5
deadline = time.time() + 5
status = None
while time.time() < deadline:
    try:
        os.read(terminal, 65536)
    except (BlockingIOError, OSError):
        pass
    if send_at and time.time() >= send_at:
        os.write(terminal, b"q")
        send_at = None
    done, value = os.waitpid(pid, os.WNOHANG)
    if done:
        status = value
        break
    time.sleep(0.05)
if status is None:
    os.kill(pid, signal.SIGTERM)
    os.waitpid(pid, 0)
    raise AssertionError("TUI did not quit")
after = termios.tcgetattr(terminal)
mask = termios.ECHO | termios.ICANON
assert os.waitstatus_to_exitcode(status) == 0
assert before[3] & mask == after[3] & mask
os.close(terminal)
PY

printf 'PASS tui: 80/119/160 layouts, whole identifiers, role emphasis, detail navigation, burn delta, pages, one seam, terminal restored\n'
