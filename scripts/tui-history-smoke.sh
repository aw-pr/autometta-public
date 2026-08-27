#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
repo="$fixture/repo"
controller="$fixture/controller"
cost_log="$repo/state/cost-log.jsonl"
mkdir -p "$repo/state" "$controller/subscribers" "$controller/dashboard"

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

python3 - "$repo" "$controller" <<'PY'
import datetime
import json
import os
import sys

repo, controller = sys.argv[1:]
state_dir = os.path.join(repo, "state")
now = datetime.datetime.now(datetime.timezone.utc)
today = now.replace(hour=0, minute=0, second=0, microsecond=0)
sol = "GPT-5.6 Sol <gpt-5-6-sol@local>"
terra = "Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>"
fable = "Claude Fable 5 <claude-fable-5@local>"
gpt53 = "Codex GPT-5.3 <codex-gpt-5-3@local>"
opus47 = "Claude Opus 4.7 <claude-opus-4-7@local>"
unknown = "Unknown Worker <unknown-worker-slug@local>"
ids = [
    "01-history-alpha", "02-history-bravo", "03-history-charlie", "04-history-delta",
    "05-history-echo", "06-history-foxtrot", "07-history-golf", "08-history-hotel",
    "09-history-india", "10-history-juliet", "11-history-kilo",
    "12-history-card-identifier-is-deliberately-whole-at-every-width",
]

rows = []
for index, stage_id in enumerate(ids):
    day_offset = 2 - index // 4
    base = today - datetime.timedelta(days=day_offset) + datetime.timedelta(hours=index % 4 + 8)
    worker = (sol, terra, gpt53, unknown)[index % 4]
    verifier = opus47 if index % 3 == 1 else fable
    worker_cost = float(index // 4 + 1)
    rows.extend((
        {
            "ts": base.strftime("%Y-%m-%dT%H:%M:%SZ"), "repo": "fixture-history",
            "stage_id": stage_id, "role": "worker", "identity": worker,
            "input_tokens": 100000, "cached_input_tokens": 50000, "output_tokens": 10000,
            "total_tokens": 160000, "usage_status": "recorded",
            "cost_usd_est": worker_cost, "result": "pass",
        },
        {
            "ts": (base + datetime.timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "repo": "fixture-history", "stage_id": stage_id, "role": "verifier",
            "identity": verifier, "input_tokens": 20000, "cached_input_tokens": 10000,
            "output_tokens": 2000, "total_tokens": 32000, "usage_status": "recorded",
            "cost_usd_est": 0.2, "result": "pass",
        },
    ))

special = ids[-1]
rows = [row for row in rows if row["stage_id"] != special]
special_base = today + datetime.timedelta(hours=23)
rows.append({
    "ts": special_base.strftime("%Y-%m-%dT%H:%M:%SZ"), "repo": "fixture-history",
    "stage_id": special, "role": "worker", "identity": sol,
    "input_tokens": 50000, "cached_input_tokens": 5000, "output_tokens": 0,
    "total_tokens": 55000, "usage_status": "recorded", "cost_usd_est": 4.0,
    "result": "fail",
})
for attempt, result in enumerate(("fail", "aborted", "fail"), start=1):
    rows.append({
        "ts": (special_base + datetime.timedelta(minutes=attempt * 5)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "repo": "fixture-history", "stage_id": special, "role": "verifier",
        "identity": fable, "input_tokens": 9000, "cached_input_tokens": 0,
        "output_tokens": 1000, "total_tokens": 10000, "usage_status": "recorded",
        "cost_usd_est": 0.3, "result": result,
    })

with open(os.path.join(state_dir, "cost-log.jsonl"), "w", encoding="utf-8") as handle:
    for row in rows:
        handle.write(json.dumps(row, separators=(",", ":")) + "\n")

with open(os.path.join(state_dir, "state.yaml"), "w", encoding="utf-8") as handle:
    handle.write("stages:\n")
    for stage_id in ids:
        handle.write(f"  - id: {stage_id}\n    status: completed\n")

subscriber = os.path.join(controller, "subscribers", "fixture-history.yaml")
with open(subscriber, "w", encoding="utf-8") as handle:
    handle.write(f'enabled: true\nrepo_path: "{repo}"\nmanifest_path: ""\n')
PY

payload="$(AUTOMETTA_HOME="$controller" "$script_dir/aggregate-dashboard.sh" --repo "$repo")" \
  || fail "history seam did not return a payload"

expected_count="$(jq -s '[.[].stage_id] | unique | length' "$cost_log")"
expected_lost="$(jq -s '[.[] | select(.result != "pass") | .total_tokens] | add' "$cost_log")"
expected_cost="$(jq -s '[.[].cost_usd_est] | add' "$cost_log")"
jq -e --argjson count "$expected_count" --argjson lost "$expected_lost" --argjson cost "$expected_cost" '
  .history.summary.card_count == $count and
  .history.summary.lost_seven_day_tokens == $lost and
  ((.history.summary.seven_day_cost_usd_est - $cost) | fabs) < 0.000001 and
  .history.summary.lost_seven_day_marked and
  .history.summary.seven_day_cost_marked and
  (.history.cards | length) == 12 and
  .history.cards[0].id == "12-history-card-identifier-is-deliberately-whole-at-every-width" and
  .history.cards[0].attempts == 3 and
  .history.cards[0].result == "FAIL" and
  .history.cards[0].tokens_marked and .history.cards[0].lost_marked and .history.cards[0].cost_marked
' <<<"$payload" >/dev/null || fail "history seam disagreed with independent fixture arithmetic"

capture() {
  local width="$1" height="$2" keys="${3:-}"
  LC_ALL=C.UTF-8 TERM=xterm-256color AUTOMETTA_HOME="$controller" \
    AUTOMETTA_TUI_CAPTURE=true AUTOMETTA_TUI_COLUMNS="$width" AUTOMETTA_TUI_ROWS="$height" \
    AUTOMETTA_TUI_KEYS="$keys" "$script_dir/tui.sh" "$repo"
}

frame80="$(capture 80 72 ']')"
frame119="$(capture 119 40 ']')"
frame160="$(capture 160 40 ']')"
long_id='12-history-card-identifier-is-deliberately-whole-at-every-width'

for frame in "$frame80" "$frame119" "$frame160"; do
  assert_contains "$frame" '[0]─History: fixture-history' "history title missing"
  assert_contains "$frame" '12 cards' "card count missing"
  assert_contains "$frame" '85.0K? lost 7d' "marked seven-day lost total missing"
  assert_contains "$frame" '$28.10? cost 7d' "marked seven-day cost total missing"
  assert_contains "$frame" '? codex zero-output read: marked totals are undercounts' "zero-read note missing"
  assert_contains "$frame" "$long_id" "long history identifier was truncated or hidden"
  assert_contains "$frame" 'sol→fable' "worker-to-verifier aliases were truncated or hidden"
  assert_contains "$frame" 'FAIL' "failed history result missing"
  assert_contains "$frame" '3' "three-attempt count missing"
  assert_contains "$frame" '85.0K?' "marked card total missing"
  assert_contains "$frame" '$4.90?' "marked card cost missing"
  assert_contains "$frame" 'spend 14d' "fortnight sparkline missing"
  assert_contains "$frame" 'by model: sol' "largest model share is not first"
  assert_not_contains "$frame" '…' "history silently truncated an identifying column"
done

AUTOMETTA_TEST_FRAME="$frame160" python3 - <<'PY' \
  || fail "history footer did not name every distinct model exactly once"
import os
line = next(line for line in os.environ["AUTOMETTA_TEST_FRAME"].splitlines()
            if "by model:" in line)
for alias in ("sol", "terra", "gpt-5.3", "unknown-worker-slug", "fable", "opus-4.7"):
    assert line.count(alias) == 1, (alias, line)
assert "claude " not in line and "codex " not in line
PY

AUTOMETTA_TEST_FRAME="$frame80" AUTOMETTA_TEST_ID="$long_id" python3 - <<'PY' \
  || fail "80-column identifier and alias did not survive drop-then-wrap"
import os
lines = os.environ["AUTOMETTA_TEST_FRAME"].splitlines()
detail = next(i for i, line in enumerate(lines) if "[0]─Card detail" in line)
assert not any("when" in line for line in lines[:detail])
index = next(i for i, line in enumerate(lines) if os.environ["AUTOMETTA_TEST_ID"] in line)
assert any("sol→fable" in line for line in lines[index:index + 4])
PY

detail119="$(capture 119 40 '],ENTER')"
detail160="$(capture 160 40 '],ENTER')"
for detail in "$detail119" "$detail160"; do
  assert_contains "$detail" 'FAIL · sol→fable' "history detail pairing disagreed with the card row"
  assert_contains "$detail" 'role  result  tokens  cost' "history detail headings missing"
  assert_contains "$detail" 'when' "history detail time heading missing"
  assert_contains "$detail" 'worker' "history detail omitted worker dispatch"
  assert_contains "$detail" 'verifier' "history detail omitted verifier dispatch"
  assert_contains "$detail" 'ABORTED' "history detail omitted an intermediate attempt"
  assert_contains "$detail" '55.0K?' "zero-output dispatch token figure was not marked"
  assert_contains "$detail" '$4.00?' "zero-output dispatch cost was not marked"
done

for spec in "119:$detail119" "160:$detail160"; do
  width="${spec%%:*}"
  detail="${spec#*:}"
  AUTOMETTA_TEST_FRAME="$detail" AUTOMETTA_TEST_ID="$long_id" python3 - <<'PY' \
    || fail "$width-column detail pane clipped the pinned card identifier"
import os
lines = os.environ["AUTOMETTA_TEST_FRAME"].splitlines()
right_x = lines[0].rfind("┌")
assert right_x > 0
fragments = []
for line in lines[1:]:
    fragment = line[right_x + 2:].rstrip("│ ").strip()
    if fragment.startswith(("PASS ·", "FAIL ·", "UNKNOWN ·")):
        break
    fragments.append(fragment)
assert len(fragments) > 1
assert "".join(fragments) == os.environ["AUTOMETTA_TEST_ID"]
PY
done

second_detail="$(capture 119 40 '],j,ENTER')"
AUTOMETTA_TEST_FRAME="$second_detail" python3 - <<'PY' \
  || fail "j/enter did not pin the next history card"
import os
lines = os.environ["AUTOMETTA_TEST_FRAME"].splitlines()
right_x = lines[0].rfind("┌")
assert right_x > 0
right_pane = "\n".join(line[right_x:] for line in lines)
assert "11-history-kilo" in right_pane
assert "12-history-card-identifier-is-deliberately-whole-at-every-width" not in right_pane
PY

spark="$(jq -r '.history.fortnight.by_day | map(.cost_usd_est) |
  (max // 0) as $peak | map(if $peak == 0 then 0 else ((. * 7 / $peak) | floor) end) |
  map(["▁","▂","▃","▄","▅","▆","▇","█"][.]) | join("")' <<<"$payload")"
assert_contains "$frame119" "spend 14d $spark" "fortnight sparkline disagreed with fixture distribution"
largest_model="$(jq -r '.history.fortnight.by_model[0].identity' <<<"$payload")"
[[ "$largest_model" == *Sol* ]] || fail "fixture did not make sol the largest model share"

for spec in "80:$frame80" "119:$frame119" "160:$frame160"; do
  width="${spec%%:*}"
  frame="${spec#*:}"
  AUTOMETTA_TEST_FRAME="$frame" AUTOMETTA_TEST_WIDTH="$width" python3 - <<'PY' \
    || fail "$width-column history frame overflowed"
import os
width = int(os.environ["AUTOMETTA_TEST_WIDTH"])
assert all(len(line) <= width for line in os.environ["AUTOMETTA_TEST_FRAME"].splitlines())
PY
done

python3 - "$script_dir/lib/tui/render.py" "$script_dir/lib/tui/app.py" <<'PY' \
  || fail "renderer crosses the declared history seam"
import ast
import sys

render_tree = ast.parse(open(sys.argv[1], encoding="utf-8").read())
assert not any(isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "open"
               for node in ast.walk(render_tree))
app_tree = ast.parse(open(sys.argv[2], encoding="utf-8").read())
poller = next(node for node in app_tree.body if isinstance(node, ast.FunctionDef)
              and node.name == "payload_from_aggregator")
calls = [node for node in ast.walk(poller) if isinstance(node, ast.Call)]
assert sum(isinstance(node.func, ast.Attribute) and node.func.attr == "run" for node in calls) == 1
PY
assert_not_contains "$(grep -Ev '^\s*#' "$script_dir/tui.sh" "$script_dir/lib/tui/app.py" "$script_dir/lib/tui/render.py")" \
  'state.yaml' "TUI opens state.yaml directly"
assert_not_contains "$(grep -Ev '^\s*#' "$script_dir/tui.sh" "$script_dir/lib/tui/app.py" "$script_dir/lib/tui/render.py")" \
  'cost-log' "TUI parses the cost log directly"

printf 'PASS tui history: real 12-card seam, 80/119/160 layouts, sums, marks, sparkline, model share and detail\n'
