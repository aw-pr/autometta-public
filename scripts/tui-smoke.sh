#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
repo="$fixture/repo"
polls="$fixture/polls.json"
empty_polls="$fixture/empty-polls.json"
controller_home="$fixture/controller"
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

assert_equals() {
  [[ "$1" == "$2" ]] || fail "$3 (got '$1', wanted '$2')"
}

queue_repo="$fixture/queue-repo"
mkdir -p "$queue_repo/state" "$queue_repo/stage-cards"
printf '%s\n' \
  'version: 1' \
  'current_stage: null' \
  'stages: []' \
  'last_tick_at: 2026-08-26T07:00:00Z' \
  'tick_count: 0' \
  'clock_tick_budget_remaining: 100' > "$queue_repo/state/state.yaml"

for stage_id in 80-run-one-first 81-run-one-second 82-run-two-first; do
  printf '%s\n' \
    "# Stage card ${stage_id}" \
    '' \
    '## Metadata' \
    '- **Worker:** GPT-5.6 Sol <gpt-5-6-sol@local>' \
    '- **Verifier:** Claude Fable 5 <claude-fable-5@local>' \
    > "$queue_repo/stage-cards/${stage_id}.md"
done

"$script_dir/add-stage.sh" "$queue_repo" "$queue_repo/stage-cards/80-run-one-first.md"
first_run="$(yq -r '.stages[] | select(.id == "80-run-one-first") | .run_id' "$queue_repo/state/state.yaml")"
[[ "$first_run" =~ ^run-[0-9]{8}-[0-9]{6}$ ]] || fail "first add-stage invocation did not mint a run id"

"$script_dir/add-stage.sh" "$queue_repo" "$queue_repo/stage-cards/81-run-one-second.md"
second_run="$(yq -r '.stages[] | select(.id == "81-run-one-second") | .run_id' "$queue_repo/state/state.yaml")"
assert_equals "$second_run" "$first_run" "second outstanding stage did not join the current run"

yq -i '(.stages[] | select(.id == "80-run-one-first")).status = "in_progress"' "$queue_repo/state/state.yaml"
assert_equals "$(yq -r '.stages[] | select(.id == "80-run-one-first") | .run_id' "$queue_repo/state/state.yaml")" \
  "$first_run" "pending-to-in_progress transition stripped run_id"
yq -i '
  (.stages[] | select(.id == "80-run-one-first")).status = "completed" |
  (.stages[] | select(.id == "81-run-one-second")).status = "completed"' "$queue_repo/state/state.yaml"
assert_equals "$(yq -r '.stages[] | select(.id == "80-run-one-first") | .run_id' "$queue_repo/state/state.yaml")" \
  "$first_run" "in_progress-to-completed transition stripped run_id"

while [[ "$(date -u +"run-%Y%m%d-%H%M%S")" == "$first_run" ]]; do
  sleep 0.1
done
"$script_dir/add-stage.sh" "$queue_repo" "$queue_repo/stage-cards/82-run-two-first.md"
third_run="$(yq -r '.stages[] | select(.id == "82-run-two-first") | .run_id' "$queue_repo/state/state.yaml")"
[[ "$third_run" =~ ^run-[0-9]{8}-[0-9]{6}$ ]] || fail "third add-stage invocation did not mint a run id"
[[ "$third_run" != "$first_run" ]] || fail "queue-empty add-stage invocation reused the completed run id"

long_id="36-this-stage-identifier-is-deliberately-fifty-characters"

python3 - "$polls" "$empty_polls" "$long_id" "$repo" "$controller_home" <<'PY'
import copy
import json
import os
import sys

polls_path, empty_path, long_id, repo_path, controller_home = sys.argv[1:]
sol = "GPT-5.6 Sol <gpt-5-6-sol@local>"
terra = "Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>"
fable = "Claude Fable 5 <claude-fable-5@local>"
gpt53 = "Codex GPT-5.3 <codex-gpt-5-3@local>"
opus47 = "Claude Opus 4.7 <claude-opus-4-7@local>"
unknown = "Unknown Worker <unknown-worker-slug@local>"
family = "Codex <codex@local>"
historic = []
for number in range(1, 41):
    stage = {
        "id": f"{number:02d}-historic-stage-{number:02d}",
        "status": "completed",
        "worker": terra,
        "verifier": fable,
        "tokens": number * 1000,
        "card": f"stage-cards/{number:02d}-historic-stage-{number:02d}.md",
    }
    if number > 20:
        stage["run_id"] = "run-20260529-090000"
    historic.append(stage)

run_id = "run-20260826-073000"
current = [
    {"id": "65-loop-stamps-hb", "status": "completed", "worker": sol, "verifier": fable,
     "tokens": 412000, "card": "stage-cards/65-loop-stamps-hb.md", "run_id": run_id},
    {"id": "66-fleet-view-fits", "status": "completed", "worker": gpt53, "verifier": opus47,
     "tokens": 3911200, "card": "stage-cards/66-fleet-view-fits.md", "run_id": run_id},
    {"id": "67-outlier-says-so", "status": "completed", "worker": terra, "verifier": fable,
     "tokens": 1200000, "card": "stage-cards/67-outlier-says-so.md", "run_id": run_id},
    {"id": "50-cards", "status": "completed", "worker": unknown, "verifier": family,
     "tokens": 3800000, "card": "stage-cards/50-cards.md", "run_id": run_id},
    {"id": long_id, "status": "completed", "worker": terra, "verifier": fable,
     "tokens": 776800, "card": f"stage-cards/{long_id}.md", "run_id": run_id},
    {"id": "68-a-pipeline-pair", "status": "in_progress", "worker": sol, "verifier": fable,
     "verifier_attempts": 2, "tokens": 2301200, "card": "stage-cards/68-a-pipeline-pair.md",
     "acceptance": "scripts/pipeline-pair-smoke.sh", "run_id": run_id},
    {"id": "69-tui", "status": "pending", "worker": fable, "verifier": gpt53,
     "tokens": 0, "card": "stage-cards/69-tui.md", "run_id": run_id},
]

history_cards = []
for index, stage in enumerate(historic + current):
    history_cards.append({
        "id": stage["id"], "result": "PASS", "attempts": 1,
        "tokens": stage["tokens"], "lost_tokens": 0, "cost_usd_est": 0.01,
        "worker": stage["worker"], "verifier": stage["verifier"],
        "last_dispatch_at": f"2026-05-{min(29, index + 1):02d}T09:00:00Z",
        "dispatches": [],
    })

def poll(now, tick, live_tokens, output_tokens, run_tokens):
    return {
        "_now": now, "name": "autometta", "current_stage": "68-a-pipeline-pair",
        "last_tick_at": "2026-08-26T07:59:18Z", "tick_count": tick,
        "run_started_at": "2026-05-29T09:00:00Z", "tokens_spent": run_tokens,
        "effective_token_cap": 150000000, "verifier_attempt_cap": 3,
        "spend": {
            "tokens_total": run_tokens, "cost_usd_est": 9.12,
            "by_stage": [
                {"stage_id": "68-a-pipeline-pair", "input_tokens": 2000000,
                 "cached_input_tokens": 300000, "output_tokens": output_tokens,
                 "tokens": live_tokens, "cost_usd_est": 1.87},
                {"stage_id": "50-cards", "input_tokens": 3000000,
                 "cached_input_tokens": 750000, "output_tokens": 50000,
                 "tokens": 3800000, "cost_usd_est": 2.41},
            ],
        },
        "stages": copy.deepcopy(historic + current),
        "current_run": {
            "id": run_id, "started_at": "2026-08-26T07:30:00Z",
            "stages": copy.deepcopy(current), "tokens_total": run_tokens,
            "cost_usd_est": 9.12,
        },
        "agents": [{
            "stage_id": "68-a-pipeline-pair", "role": "worker", "identity": sol,
            "elapsed_seconds": 192 + (now - 1787731200), "budget_seconds": 1800,
            "live_total_tokens": live_tokens,
        }],
        "history": {
            "summary": {"card_count": 47, "lost_seven_day_tokens": 0,
                        "seven_day_cost_usd_est": 9.12},
            "cards": history_cards,
            "fortnight": {"by_day": [], "by_model": []},
        },
    }

poll_documents = [
    poll(1787731200, 214, 2300000, 1000, 12400000),
    poll(1787731205, 215, 2301200, 2200, 12401200),
]
with open(polls_path, "w", encoding="utf-8") as handle:
    json.dump({"polls": poll_documents}, handle)

empty = copy.deepcopy(poll_documents[-1])
empty["current_stage"] = None
empty["current_run"] = None
empty["agents"] = []
for stage in empty["stages"]:
    if stage.get("run_id") == run_id:
        stage["status"] = "completed"
with open(empty_path, "w", encoding="utf-8") as handle:
    json.dump({"polls": [empty]}, handle)

os.makedirs(os.path.join(repo_path, "state"), exist_ok=True)
state = {
    "version": 1, "current_stage": "68-a-pipeline-pair",
    "stages": historic + current, "last_tick_at": "2026-08-26T07:59:18Z",
    "tick_count": 215, "clock_tick_budget_remaining": 100,
}
with open(os.path.join(repo_path, "state", "state.yaml"), "w", encoding="utf-8") as handle:
    json.dump(state, handle)
with open(os.path.join(repo_path, "state", "budget.json"), "w", encoding="utf-8") as handle:
    json.dump({"tokens_spent": 12401200, "token_cap_total": 150000000,
               "halted": False, "consecutive_failures": 0,
               "consecutive_failure_cap": 3}, handle)
costs = [0.30, 2.00, 0.80, 2.41, 0.73, 1.87, 1.01]
with open(os.path.join(repo_path, "state", "cost-log.jsonl"), "w", encoding="utf-8") as handle:
    for stage, cost in zip(current, costs):
        handle.write(json.dumps({
            "ts": "2026-08-26T07:45:00Z", "stage_id": stage["id"],
            "role": "worker", "identity": stage["worker"], "result": "pass",
            "input_tokens": stage["tokens"], "cached_input_tokens": 0,
            "output_tokens": 0, "cost_usd_est": cost,
        }) + "\n")
subscribers = os.path.join(controller_home, "subscribers")
os.makedirs(subscribers, exist_ok=True)
with open(os.path.join(subscribers, "autometta.yaml"), "w", encoding="utf-8") as handle:
    handle.write(f"enabled: true\nrepo_path: {repo_path}\nmanifest_path: ''\n")
PY

aggregate="$(AUTOMETTA_HOME="$controller_home" "$script_dir/aggregate-dashboard.sh" --repo "$repo")"
assert_equals "$(jq -r '.current_run.id' <<<"$aggregate")" "run-20260826-073000" \
  "aggregate did not expose the current run id"
assert_equals "$(jq -r '.current_run.started_at' <<<"$aggregate")" "2026-08-26T07:30:00Z" \
  "aggregate did not derive the run start from the mint time"
assert_equals "$(jq -r '.current_run.stages | length' <<<"$aggregate")" "7" \
  "aggregate did not scope current-run stages"
assert_equals "$(jq -r '.current_run.tokens_total' <<<"$aggregate")" "12401200" \
  "aggregate did not scope current-run tokens"
assert_equals "$(jq -r '.current_run.cost_usd_est' <<<"$aggregate")" "9.12" \
  "aggregate did not scope current-run cost"

capture() {
  local width="$1" height="$2" keys="${3:-}" ansi="${4:-false}" fixture_polls="${5:-$polls}"
  LC_ALL=C.UTF-8 TERM=xterm-256color AUTOMETTA_TUI_CAPTURE=true \
    AUTOMETTA_TUI_COLUMNS="$width" AUTOMETTA_TUI_ROWS="$height" \
    AUTOMETTA_TUI_INTERVAL=5 AUTOMETTA_TUI_FIXTURE_POLLS="$fixture_polls" \
    AUTOMETTA_TUI_KEYS="$keys" AUTOMETTA_TUI_ANSI="$ansi" \
    "$script_dir/tui.sh" "$repo"
}

frame80="$(capture 80 60)"
frame80x24="$(capture 80 24)"
frame119="$(capture 119 40)"
frame160="$(capture 160 40)"

legacy_count="$(jq -r '.polls[-1] |
  "\([.stages[] | select(.status == "completed")] | length) of \(.stages | length)"' "$polls")"
assert_equals "$legacy_count" "45 of 47" "fixture no longer reproduces the pre-fix all-stage count"

for frame in "$frame80" "$frame119" "$frame160"; do
  for panel in '[0]─Card detail' '[1]─Status' '[2]─This run' '[3]─Agents' '[4]─Escalations & inbox'; do
    assert_contains "$frame" "$panel" "missing panel $panel"
  done
  assert_contains "$frame" '[r]un [h]istory [m]essages' "missing page tabs"
  assert_contains "$frame" 'This run  5 of 7' "current-run count is not scoped to seven cards"
  assert_not_contains "$frame" '01-historic-stage-01' "historic stage leaked onto the run page"
  assert_contains "$frame" "$long_id" "long stage id was truncated or hidden"
  for stage_id in 65-loop-stamps-hb 66-fleet-view-fits 67-outlier-says-so 68-a-pipeline-pair 50-cards 69-tui; do
    assert_contains "$frame" "$stage_id" "stage id $stage_id was truncated or hidden"
  done
  assert_contains "$frame" 'sol→fable' "worker-to-verifier pairing was lost"
  assert_contains "$frame" 'terra→fable' "second worker-to-verifier pairing was lost"
  assert_contains "$frame" 'gpt-5.3→opus-4.7' "old-style model aliases were lost"
  assert_contains "$frame" 'fable→gpt-5.3' "current verifier alias was lost"
  assert_contains "$frame" 'unknown-worker-slug→codex' "unknown and family-fallback aliases were lost"
  assert_contains "$frame" 'Claude Fable 5 <claude-fable-5@local>' "full verifier identity was truncated"
  for status in "done" WORKER queued; do
    assert_contains "$frame" "$status" "status word $status was truncated or hidden"
  done
  assert_not_contains "$frame" '…' "a frame used silent identifying-column truncation"
done

for spec in "80:$frame80" "119:$frame119" "160:$frame160"; do
  width="${spec%%:*}"
  frame="${spec#*:}"
  AUTOMETTA_TEST_FRAME="$frame" AUTOMETTA_TEST_LONG_ID="$long_id" \
    AUTOMETTA_TEST_WIDTH="$width" python3 - <<'PY' \
    || fail "$width-column run rows did not keep constant column offsets"
import os
lines = os.environ["AUTOMETTA_TEST_FRAME"].splitlines()
right_x = lines[0].rfind("┌")
if right_x > 0:
    lines = [line[:right_x] for line in lines]
run_start = next(i for i, line in enumerate(lines) if "[2]─This run" in line)
run_end = next(i for i, line in enumerate(lines[run_start + 1:], run_start + 1)
               if "[3]─Agents" in line)
lines = lines[run_start:run_end]
long_id = os.environ["AUTOMETTA_TEST_LONG_ID"]
long_index = next(i for i, line in enumerate(lines) if long_id in line)
assert "✔  " + long_id in lines[long_index], lines[long_index]
assert long_index + 1 < len(lines), lines[long_index]
continuation = lines[long_index + 1]
assert "└─" in continuation, continuation
assert "done" in continuation and "terra→fable" in continuation and "776k" in continuation, continuation
print("%s columns:\n%s\n%s" % (os.environ["AUTOMETTA_TEST_WIDTH"],
                                 lines[long_index], continuation))
stages = {
    "65-loop-stamps-hb": ("done", "sol→fable", "412k"),
    "66-fleet-view-fits": ("done", "gpt-5.3→opus-4.7", "3,911k"),
    "67-outlier-says-so": ("done", "terra→fable", "1,200k"),
    "50-cards": ("done", "unknown-worker-slug→codex", "3,800k"),
    "68-a-pipeline-pair": ("WORKER", "sol→fable", "2,301k"),
    "69-tui": ("queued", "fable→gpt-5.3", "0"),
}
offsets = set()
for stage_id, (status, pair, tokens) in stages.items():
    line = next(line for line in lines if stage_id in line)
    assert pair in line and status in line, (stage_id, status, pair, line)
    offsets.add((line.find(next(g for g in "✔▶○" if g in line)), line.index(stage_id),
                 line.index(status), line.index(pair), line.rfind(tokens)))
assert len(offsets) == 1, offsets
PY
done

AUTOMETTA_TEST_FRAME="$frame80x24" python3 - <<'PY' \
  || fail "80x24 frame escaped its terminal height"
import os
assert len(os.environ["AUTOMETTA_TEST_FRAME"].splitlines()) == 24
PY

python3 - "$script_dir/lib/tui/render.py" <<'PY' \
  || fail "identity alias mapping did not follow canonical slugs"
import importlib.util
import sys
spec = importlib.util.spec_from_file_location("autometta_tui_render", sys.argv[1])
render = importlib.util.module_from_spec(spec)
spec.loader.exec_module(render)
cases = {
    "GPT-5.6 Sol <gpt-5-6-sol@local>": "sol",
    "Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>": "terra",
    "Codex GPT-5.6 Luna <codex-gpt-5-6-luna@local>": "luna",
    "Claude Fable 5 <claude-fable-5@local>": "fable",
    "Codex GPT-5.3 <codex-gpt-5-3@local>": "gpt-5.3",
    "Claude Opus 4.7 <claude-opus-4-7@local>": "opus-4.7",
    "Unknown Worker <unknown-worker-slug@local>": "unknown-worker-slug",
    "Codex <codex@local>": "codex",
}
assert {identity: render.identity_alias(identity) for identity in cases} == cases
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

assert_contains "$frame119" 'GPT-5.6 Sol <gpt-5-6-sol@local>' "detail omitted worker identity"
assert_contains "$frame119" 'Claude Fable 5 <claude-fable-5@local>' "detail omitted verifier identity"
assert_contains "$frame119" 'attempt   2 of 3' "detail omitted attempt"
assert_contains "$frame119" 'budget    3m17s / 30m00s (10% used)' "detail omitted budget"
assert_contains "$frame119" 'tokens  in 2.0M  cached 300.0K  out 2.2K' "detail omitted token breakdown"
assert_contains "$frame119" "\$1.87" "detail omitted stage cost"
assert_contains "$frame119" '14.4K/min' "burn rate was not computed from the 1,200-token poll delta"
assert_contains "$frame119" 'run start 07:30:00Z  elapsed 30m05s' "run start or elapsed did not use the mint time"
assert_contains "$frame119" 'run spend 12,401k  $9.12 actual' "status lost the run-scoped actual spend"
# The run's own spend and the repo's lifetime percentage of the cap used to
# share a line, so "12.4M ... 150.0M (8%)" invited the reading that 12.4M of
# 150.0M is 8%. It is not; 8% is the repo's lifetime 12.4M against the cap. A
# figure that will not reconcile reads as a budget rather than a measurement,
# so each quantity gets a line and the cap line names both of its numbers.
assert_contains "$frame119" 'repo 12,401k of 150,000k cap (8%)' "cap line does not name what the percentage is of"
assert_not_contains "$frame119" 'run tokens 12.4M  $9.12  repo cap' "run spend and repo cap still share a line"
# The in-flight role is in no settled figure until it exits, so without this
# the number sits still for the length of a worker and reads as a static
# budget. The turning bar moves every second whether or not the figures do.
assert_contains "$frame119" 'worker 3m17s +2,301k live' "status lost the in-flight live spend ticker"

# The refresh line comes and goes with every poll. It used to sit in the
# status panel, where each appearance shoved run start, run spend and the cap
# line down a row and each disappearance pulled them back, so the panel a
# reader glances at never held still. It now belongs to panel 5, whose subject
# it is. Two halves to the contract: the status panel never carries it at any
# poll age, and panel 5 always does.
printf '3b. the refresh line lives on panel 5, and the status panel holds still\n' >&2
AUTOMETTA_LIB="$script_dir/lib" python3 - <<'PYEOF' || fail "the refresh line is not confined to panel 5"
import os, sys, time
sys.path.insert(0, os.environ["AUTOMETTA_LIB"])
from tui import render

payload = {
    "name": "smoke", "tick_count": 7, "last_tick_at": "2026-08-26T07:59:00Z",
    "tokens_spent": 12_400_000, "token_cap_total": 150_000_000,
    "current_run": {"id": "run-1", "started_at": "2026-08-26T07:30:00Z",
                    "tokens_total": 12_400_000, "cost_usd_est": 9.12,
                    "stages": [{"id": "68-a-pipeline-pair", "status": "in_progress"}]},
    "stages": [{"id": "68-a-pipeline-pair", "status": "in_progress"}],
    "agents": [{"stage_id": "68-a-pipeline-pair", "role": "worker",
                "started_at": "2026-08-26T07:56:48Z", "live_total_tokens": 2_300_000}],
    "_now": int(time.mktime(time.strptime("2026-08-26 08:00:05", "%Y-%m-%d %H:%M:%S"))),
}

state = render.TuiState(interval=5.0)
state.update(payload)
state.update_status_updates([("07:59:00", "dispatched 68-a-pipeline-pair")])

def status_texts():
    return [line[0] for line in render.status_lines(state)]

def panel5_texts():
    return [line[0] for line in render.status_update_lines(state, 70)]

fresh = status_texts()
state.data_started_at = state.monotonic_now - 30.0
stale = status_texts()
if fresh != stale:
    raise SystemExit("poll age moved the status panel:\n  %r\n  %r" % (fresh, stale))
if any(text.startswith("data ") or "refreshed" in text for text in stale):
    raise SystemExit("the status panel still carries a refresh line: %r" % stale)

rows = panel5_texts()
if not any("refreshed" in text for text in rows):
    raise SystemExit("panel 5 lost the refresh line: %r" % rows)
if rows[-1] != "refreshed 30s ago":
    raise SystemExit("the refresh line is not panel 5's last row: %r" % rows)
if not any("dispatched 68-a-pipeline-pair" in text for text in rows):
    raise SystemExit("panel 5 lost the loop's status updates: %r" % rows)

# A poll in flight is a marker on the age line, never a replacement for it:
# the age is a fact about the figures on screen, and a slow poll is exactly
# when a reader needs to know how old they are.
state.polling = True
polling_line = render.status_update_lines(state, 70)[-1][0]
if polling_line != "refreshed 30s ago · refreshing":
    raise SystemExit("panel 5 lost the age or the in-flight marker: %r" % polling_line)
PYEOF

after="$(capture 119 40 '2,j,ENTER')"
assert_contains "$frame119" 'stage-cards/68-a-pipeline-pair.md' "initial detail card is wrong"
assert_contains "$after" 'stage-cards/69-tui.md' "enter did not repopulate card detail"

history="$(capture 119 40 ']')"
messages="$(capture 119 40 '],]')"
returned="$(capture 119 40 '2,j,ENTER,],],]')"
assert_contains "$history" '01-historic-stage-01' "historic cards are absent from the history page"
assert_contains "$messages" 'no controller record yet' "fresh messages page state missing"
assert_contains "$returned" 'stage-cards/69-tui.md' "page round-trip disturbed run-page state"

history_last_keys=']'
for _ in $(seq 1 39); do
  history_last_keys="${history_last_keys},j"
done
history_last="$(capture 119 40 "$history_last_keys")"
assert_contains "$history_last" '40-historic-stage-40' "later historic cards are absent from the history page"

empty_frame="$(capture 119 40 '' false "$empty_polls")"
assert_contains "$empty_frame" 'no current run · use the history tab' "empty run state does not name the history tab"
assert_not_contains "$empty_frame" 'run start' "empty run state fabricated a run start"
assert_not_contains "$empty_frame" 'elapsed' "empty run state fabricated elapsed time"
assert_contains "$empty_frame" 'repo cap 150,000k (8% lifetime used)' "empty run state lost the repo-lifetime cap"

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

LC_ALL=C.UTF-8 TERM=xterm-256color python3 - \
  "$script_dir/lib/tui/app.py" "$repo" "$polls" "$fixture" <<'PY' || \
  fail "non-blocking poll contract failed"
import fcntl
import importlib.util
import json
import os
import pty
import queue
import re
import signal
import struct
import sys
import termios
import time

app_path, repo_path, payload_path, fixture_dir = sys.argv[1:]
stub_path = os.path.join(fixture_dir, "stub-aggregator.py")
with open(stub_path, "w", encoding="utf-8") as handle:
    handle.write(r'''#!/usr/bin/env python3
import fcntl
import json
import os
import sys
import time

plan_path = os.environ["AUTOMETTA_TUI_STUB_PLAN"]
state_path = os.environ["AUTOMETTA_TUI_STUB_STATE"]
events_path = os.environ["AUTOMETTA_TUI_STUB_EVENTS"]
payload_path = os.environ["AUTOMETTA_TUI_STUB_PAYLOAD"]
with open(state_path, "a+", encoding="utf-8") as state:
    fcntl.flock(state, fcntl.LOCK_EX)
    state.seek(0)
    raw = state.read().strip()
    call = int(raw) if raw else 0
    state.seek(0)
    state.truncate()
    state.write(str(call + 1))
    state.flush()
    fcntl.flock(state, fcntl.LOCK_UN)
with open(plan_path, "r", encoding="utf-8") as handle:
    plan = json.load(handle)
entry = plan[min(call, len(plan) - 1)]
def event(kind):
    with open(events_path, "a", encoding="utf-8") as events:
        events.write(json.dumps({"event": kind, "call": call,
                                 "marker": entry["marker"],
                                 "at": time.monotonic()}) + "\n")
        events.flush()
event("start")
time.sleep(entry["delay"])
if entry.get("fail"):
    event("fail")
    sys.stderr.write("configured stub failure\n")
    sys.exit(7)
with open(payload_path, "r", encoding="utf-8") as handle:
    document = json.load(handle)
payload = document["polls"][-1]
payload["name"] = entry["marker"]
event("finish")
json.dump(payload, sys.stdout)
''')
os.chmod(stub_path, 0o755)


def read_jsonl(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return [json.loads(line) for line in handle if line.strip()]
    except FileNotFoundError:
        return []


class RunningApp:
    serial = 0

    def __init__(self, plan, interval):
        RunningApp.serial += 1
        prefix = os.path.join(fixture_dir, "interactive-%d" % RunningApp.serial)
        self.plan_path = prefix + "-plan.json"
        self.state_path = prefix + "-state"
        self.events_path = prefix + "-events.jsonl"
        self.frames_path = prefix + "-frames.jsonl"
        with open(self.plan_path, "w", encoding="utf-8") as handle:
            json.dump(plan, handle)
        env = dict(os.environ,
                   AUTOMETTA_TUI_STUB_PLAN=self.plan_path,
                   AUTOMETTA_TUI_STUB_STATE=self.state_path,
                   AUTOMETTA_TUI_STUB_EVENTS=self.events_path,
                   AUTOMETTA_TUI_STUB_PAYLOAD=payload_path,
                   AUTOMETTA_TUI_FRAME_LOG=self.frames_path)
        self.started_at = time.monotonic()
        self.pid, self.terminal = pty.fork()
        if self.pid == 0:
            os.execve(sys.executable, [sys.executable, app_path, repo_path, stub_path,
                                       "--interval", str(interval)], env)
        fcntl.ioctl(self.terminal, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 119, 0, 0))
        self.before = termios.tcgetattr(self.terminal)
        flags = fcntl.fcntl(self.terminal, fcntl.F_GETFL)
        fcntl.fcntl(self.terminal, fcntl.F_SETFL, flags | os.O_NONBLOCK)
        self.status = None
        self.output = bytearray()

    def pump(self):
        try:
            while True:
                chunk = os.read(self.terminal, 65536)
                if not chunk:
                    break
                self.output.extend(chunk)
        except (BlockingIOError, OSError):
            pass
        if self.status is None:
            done, status = os.waitpid(self.pid, os.WNOHANG)
            if done:
                self.status = status

    def wait_for(self, reader, predicate, timeout, message):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.pump()
            items = reader()
            match = next((item for item in items if predicate(item)), None)
            if match is not None:
                return match
            if self.status is not None:
                raise AssertionError("%s; app exited %d; terminal=%r" % (
                    message, os.waitstatus_to_exitcode(self.status), bytes(self.output[-500:])))
            time.sleep(0.02)
        raise AssertionError(message)

    def frame(self, predicate, timeout, message):
        return self.wait_for(lambda: read_jsonl(self.frames_path), predicate, timeout, message)

    def event(self, predicate, timeout, message):
        return self.wait_for(lambda: read_jsonl(self.events_path), predicate, timeout, message)

    def send(self, keys):
        os.write(self.terminal, keys)

    def quit(self):
        started = time.monotonic()
        self.send(b"q")
        deadline = started + 1.0
        while time.monotonic() < deadline and self.status is None:
            self.pump()
            time.sleep(0.02)
        assert self.status is not None, "q did not exit within one second during a poll"
        elapsed = time.monotonic() - started
        after = termios.tcgetattr(self.terminal)
        mask = termios.ECHO | termios.ICANON
        assert os.waitstatus_to_exitcode(self.status) == 0
        assert self.before[3] & mask == after[3] & mask, "terminal flags were not restored"
        os.close(self.terminal)
        return elapsed

    def stop(self):
        if self.status is None:
            try:
                os.kill(self.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            _, self.status = os.waitpid(self.pid, 0)
        os.close(self.terminal)


primary = RunningApp([
    {"delay": 10.0, "marker": "slow-old"},
    {"delay": 0.1, "marker": "fresh"},
    {"delay": 3.0, "marker": "mid-poll"},
], 5.0)
try:
    loading = primary.frame(lambda row: "first poll running..." in row["text"], 1.0,
                            "loading frame did not appear within one second")
    assert loading["at"] - primary.started_at < 1.0
    primary.send(b"]")
    primary.frame(lambda row: "[0]─History:" in row["text"], 1.0,
                  "page switch was not applied during the first poll")
    primary.send(b"[")
    # The refresh line moved off the status panel onto panel 5, so the age a
    # slow poll leaves behind is now "refreshed Ns ago" rather than the old
    # "data Ns old". What is being proved is unchanged: a payload that took ten
    # seconds to arrive is drawn, and says how stale it is, without the loop
    # having blocked on it.
    stale = primary.frame(
        lambda row: "slow-old" in row["text"] and "refreshed " in row["text"] and " ago" in row["text"],
        11.0, "slow payload did not replace loading with a refresh-age line")
    # Matched on the marker as the status panel draws it. A bare "fresh" also
    # matches "refreshed" in the new panel-5 age line, so the stale frame
    # satisfied it and the age never appeared to reset.
    fresh = primary.frame(lambda row: "● fresh" in row["text"], 1.0,
                          "fresh payload did not replace the slow payload")
    # Age in whole seconds against a real clock: pinning an exact 0s makes the
    # test lose on scheduling jitter. What matters is that the ten-second age
    # the slow poll left behind is gone.
    fresh_age = re.search(r"refreshed (\d+)s ago", fresh["text"])
    assert fresh_age and int(fresh_age.group(1)) <= 2, \
        "a fresh payload did not reset the refresh age: %r" % (
            fresh_age.group(0) if fresh_age else None)
    primary.event(lambda row: row["event"] == "start" and row["call"] == 2, 6.0,
                  "third poll did not start")
    primary.send(b"2j\r")
    primary.frame(lambda row: "stage-cards/69-tui.md" in row["text"], 1.0,
                  "pinning was not applied during a poll")
    primary.send(b"]")
    primary.frame(lambda row: "01-historic-stage-01" in row["text"], 1.0,
                  "history page did not render during a poll")
    primary.send(b"[")
    quit_elapsed = primary.quit()
finally:
    if primary.status is None:
        primary.stop()

failure = RunningApp([
    {"delay": 0.05, "marker": "failure-base"},
    {"delay": 0.5, "marker": "failure", "fail": True},
], 0.2)
try:
    failure.frame(lambda row: "failure-base" in row["text"], 1.0,
                  "failure test did not receive its first payload")
    failure.event(lambda row: row["event"] == "start" and row["call"] == 1, 1.0,
                  "failing poll did not start")
    failure.send(b"]")
    failure.frame(lambda row: "[0]─History:" in row["text"], 1.0,
                  "keys stopped responding during the failing poll")
    failure.send(b"[")
    failure.frame(lambda row: "state error:" in row["text"], 1.0,
                  "poll failure did not render state_error")
    failure.quit()
finally:
    if failure.status is None:
        failure.stop()

spec = importlib.util.spec_from_file_location("autometta_tui_app", app_path)
app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app)
overlap_plan = os.path.join(fixture_dir, "overlap-plan.json")
overlap_state = os.path.join(fixture_dir, "overlap-state")
overlap_events = os.path.join(fixture_dir, "overlap-events.jsonl")
with open(overlap_plan, "w", encoding="utf-8") as handle:
    json.dump([{"delay": 0.5, "marker": "overlap-old"},
               {"delay": 0.05, "marker": "overlap-new"}], handle)
os.environ.update(AUTOMETTA_TUI_STUB_PLAN=overlap_plan,
                  AUTOMETTA_TUI_STUB_STATE=overlap_state,
                  AUTOMETTA_TUI_STUB_EVENTS=overlap_events,
                  AUTOMETTA_TUI_STUB_PAYLOAD=payload_path)
results = queue.Queue()
state = app.TuiState(0.1)
started = time.monotonic()
old_thread = app.start_poll(results, 1, started, stub_path, repo_path)
deadline = time.monotonic() + 1.0
while time.monotonic() < deadline:
    if any(row["event"] == "start" and row["call"] == 0 for row in read_jsonl(overlap_events)):
        break
    time.sleep(0.01)
else:
    raise AssertionError("old overlapping poll did not start")
new_thread = app.start_poll(results, 2, time.monotonic(), stub_path, repo_path)
accepted = 0
deadline = time.monotonic() + 2.0
while accepted < 2 and time.monotonic() < deadline:
    try:
        result = results.get(timeout=0.1)
    except queue.Empty:
        continue
    app.apply_poll_result(state, result, 2)
    accepted += 1
old_thread.join(1.0)
new_thread.join(1.0)
assert accepted == 2, "overlapping polls did not both finish"
overlap_frame = app.render(state, 119, 40).text()
assert "overlap-new" in overlap_frame, "newer overlapping payload was not rendered"
assert "overlap-old" not in overlap_frame, "stale overlapping payload replaced newer data"

print("non-blocking evidence: loading %.3fs; quit %.3fs; stale and fresh age frames; "
      "mid-poll pin/page; state_error; stale generation discarded" % (
          loading["at"] - primary.started_at, quit_elapsed))
PY

printf 'PASS tui: run mint/join/remint, preserved run id, two-run scope at 80/119/160, mint elapsed, empty state, non-blocking polls, terminal restored\n'
