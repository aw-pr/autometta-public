#!/usr/bin/env bash
# AUTOMETTA-CONTRACT-NONE reason=regression suite; no stage card freezes it
# live-share-smoke.sh: the aggregator predicts each stage role in the measure
# the stage cells show, and puts the running dispatch's spend against that
# prediction beside the phase. No auth, no network, no token spend.
#
# What it asserts, against a fixture cost log whose cached reads dwarf its
# uncached tokens and a registry of agents the heartbeat calls alive:
#
#   1. A role predicts from the median uncached tokens (input plus output) its
#      model has spent per dispatch here, never the processed median.
#   2. It counts only the samples that carry an uncached split.
#   3. A model with no history here falls back to the middle of the per-model
#      medians in that role, and says so.
#   4. A working stage shows its worker's live uncached tokens as a share of
#      that prediction.
#   5. A verifying stage counts only the running dispatch, never an earlier
#      settled attempt, and reads high from twice the median.
#   6. Only the heartbeat's own flag makes a share an outlier.
#   7. On a panel, the verifier furthest past its own prediction speaks for
#      the stage, and an SDK reading wins over the heartbeat sample.
#   8. A waiting phase, a settled stage and an agent with no reading show no
#      share at all.
#   9. The web stage table draws the share inside the status, coloured by its
#      level, with a title that says it is not completion, and sorts the
#      column by status alone.
#  10. The TUI run row carries the share beside its status, red only for an
#      outlier, and the repo ticker's NOW line says "of typical" beside the
#      phase.
#  11. A repo with no history predicts nothing rather than a zero.
#
# Exit 0 on all-pass, 1 on any assertion failure.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

fail=0
check() {
  local desc="$1" cond="$2"
  if [[ "$cond" == "ok" ]]; then printf '  PASS: %s\n' "$desc" >&2
  else printf '  FAIL: %s (%s)\n' "$desc" "$cond" >&2; fail=1; fi
}
eq() { [[ "$1" == "$2" ]] && printf 'ok\n' || printf 'expected %q, got %q\n' "$1" "$2"; }

# The aggregator reads registered subscribers and live transcripts, so both
# point at throwaway directories rather than the operator's.
export PHAT_CONTROLLER_HOME="$tmp_root/controller"
export AUTOMETTA_CLAUDE_PROJECTS="$tmp_root/claude-projects"
export AUTOMETTA_CODEX_SESSIONS="$tmp_root/codex-sessions"
mkdir -p "$PHAT_CONTROLLER_HOME/subscribers" "$PHAT_CONTROLLER_HOME/log" \
  "$AUTOMETTA_CLAUDE_PROJECTS" "$AUTOMETTA_CODEX_SESSIONS"

subscribe() {
  local name="$1" path="$2"
  mkdir -p "$path/state"
  printf 'version: 1\n' > "$path/.autometta.local.yaml"
  cat > "$PHAT_CONTROLLER_HOME/subscribers/$name.yaml" <<YAML
repo_path: "$path"
manifest_path: "$path/.autometta.local.yaml"
weight: 100
enabled: true
YAML
}

repo="$tmp_root/repo"
empty="$tmp_root/empty"
subscribe repo "$repo"
subscribe empty "$empty"

opus="Opus <opus@local>"
terra="Terra <terra@local>"
sol="Sol <sol@local>"

cat > "$repo/state/state.yaml" <<YAML
version: 1
current_stage: null
stages:
  - id: 01-known-pair
    status: completed
    worker: "$opus"
    verifier: "$sol"
  - id: 02-new-models
    status: pending
    worker: "Fable <fable@local>"
    verifier: "Never <never@local>"
YAML
cp "$repo/state/state.yaml" "$empty/state/state.yaml"
cat >> "$repo/state/state.yaml" <<YAML
  - id: 03-working
    status: in_progress
    run_id: run-20261112-120000
    worker: "$opus"
    verifier: "$sol"
    worker_pid: 4999901
  - id: 04-verifying
    status: in_progress
    run_id: run-20261112-120000
    worker: "$opus"
    verifier: "$sol"
    verifier_pid: 4999902
  - id: 05-outlier
    status: in_progress
    run_id: run-20261112-120000
    worker: "$terra"
    verifier: "$sol"
    worker_pid: 4999903
  - id: 06-panel
    status: in_progress
    run_id: run-20261112-120000
    worker: "$opus"
    verifier: "$sol"
    verifier_pid: 4999904
  - id: 07-waiting
    status: in_progress
    run_id: run-20261112-120000
    worker: "$opus"
    verifier: "$sol"
  - id: 08-no-reading
    status: in_progress
    run_id: run-20261112-120000
    worker: "$opus"
    verifier: "$sol"
    worker_pid: 4999908
YAML

# Process ids above the platform maximum, so no real process can answer to
# them; the heartbeat's alive list is what keeps them on the board.
mkdir -p "$repo/state/active-agents"
agent() {
  local pid="$1" stage_id="$2" role="$3" identity="$4" extra="${5:-}"
  printf '{"pid":%s,"stage_id":"%s","role":"%s","family":"claude","identity":"%s","card_path":"stage-cards/%s.md","log_path":"","started_at":"%s","working_dir":"%s"%s}\n' \
    "$pid" "$stage_id" "$role" "$identity" "$stage_id" "$now" "$repo" "$extra" > "$repo/state/active-agents/$pid.json"
}

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
row() {
  # Five million cached reads per dispatch put the processed median an order
  # of magnitude above the uncached one, so a prediction in the wrong measure
  # cannot pass by accident.
  printf '{"ts":"%s","repo":"repo","stage_id":"history","role":"%s","identity":"%s","input_tokens":%s,"cached_input_tokens":5000000,"output_tokens":%s,"cost_usd_est":1.0,"result":"pass"}\n' \
    "$now" "$1" "$2" "$3" "$4" >> "$repo/state/cost-log.jsonl"
}
row worker   "$opus"  90000 10000
row worker   "$opus" 180000 20000
row worker   "$opus" 270000 30000
row worker   "$opus" 360000 40000
row worker   "$opus" 450000 50000
row worker   "$terra" 70000 10000
row worker   "$terra" 100000 20000
row verifier "$sol"  45000  5000
row verifier "$sol"  54000  6000
row verifier "$sol"  63000  7000
# A dispatch with no uncached split still counts towards the processed median
# but must not count as an uncached sample.
printf '{"ts":"%s","repo":"repo","stage_id":"history","role":"worker","identity":"%s","total_tokens":9000000,"cost_usd_est":1.0,"result":"pass"}\n' \
  "$now" "$opus" >> "$repo/state/cost-log.jsonl"

# An earlier verifier attempt on 04 settled at the median; the running one
# must not inherit it.
printf '{"ts":"%s","repo":"repo","stage_id":"04-verifying","role":"verifier","identity":"%s","input_tokens":54000,"cached_input_tokens":5000000,"output_tokens":6000,"cost_usd_est":1.0,"result":"fail"}\n' \
  "$now" "$sol" >> "$repo/state/cost-log.jsonl"

agent 4999901 03-working   worker   "$opus"
agent 4999902 04-verifying verifier "$sol"
agent 4999903 05-outlier   worker   "$terra"
agent 4999904 06-panel     verifier "$sol"
agent 4999905 06-panel     verifier "Never <never@local>" ',"live_input_tokens":60000,"live_output_tokens":6000'
agent 4999907 07-waiting   worker   "$opus"
agent 4999908 08-no-reading worker  "$opus"
cat > "$repo/state/heartbeat.json" <<JSON
{"checked_at":"$now","entries":[
 {"pid":4999901,"alive":true,"flags":[],"live_total_tokens":5120000,"live_uncached_tokens":120000,"live_uncached_input_tokens":100000},
 {"pid":4999902,"alive":true,"flags":[],"live_total_tokens":5150000,"live_uncached_tokens":150000,"live_uncached_input_tokens":140000},
 {"pid":4999903,"alive":true,"flags":["token-outlier"],"live_total_tokens":9500000,"live_uncached_tokens":1500000,"live_uncached_input_tokens":1400000},
 {"pid":4999904,"alive":true,"flags":[],"live_total_tokens":2030000,"live_uncached_tokens":30000,"live_uncached_input_tokens":25000},
 {"pid":4999905,"alive":true,"flags":[],"live_total_tokens":100,"live_uncached_tokens":10,"live_uncached_input_tokens":5},
 {"pid":4999907,"alive":true,"flags":[],"live_total_tokens":5090000,"live_uncached_tokens":90000,"live_uncached_input_tokens":80000},
 {"pid":4999908,"alive":true,"flags":[]}
]}
JSON

payload="$("$script_dir/aggregate-dashboard.sh" --repo "$repo" 2>/dev/null)"
[[ -n "$payload" ]] || { echo "FAIL: aggregator produced nothing" >&2; exit 1; }
field() { printf '%s' "$payload" | jq -r "$1"; }
stage() { printf '.stages[] | select(.id == "%s")' "$1"; }

printf '== 1. a role predicts from its model'"'"'s uncached median ==\n' >&2
check "the worker predicts 300,000 uncached, not the processed median" \
  "$(eq 300000 "$(field "$(stage 01-known-pair) | .estimate.worker.uncached_tokens")")"
check "the verifier predicts 60,000 uncached" \
  "$(eq 60000 "$(field "$(stage 01-known-pair) | .estimate.verifier.uncached_tokens")")"
check "the total predicts both roles" \
  "$(eq 360000 "$(field "$(stage 01-known-pair) | .estimate.total_uncached_tokens")")"
check "the basis is the model's own history" \
  "$(eq model "$(field "$(stage 01-known-pair) | .estimate.worker.basis")")"

printf '== 2. only dispatches with an uncached split are samples ==\n' >&2
check "the worker counts five samples, not six" \
  "$(eq 5 "$(field "$(stage 01-known-pair) | .estimate.worker.samples")")"

printf '== 3. a model with no history falls back to the role ==\n' >&2
check "a new worker takes the middle of the worker medians" \
  "$(eq 300000 "$(field "$(stage 02-new-models) | .estimate.worker.uncached_tokens")")"
check "and says the basis is the role" \
  "$(eq role "$(field "$(stage 02-new-models) | .estimate.worker.basis")")"
check "with no sample count of its own" \
  "$(eq null "$(field "$(stage 02-new-models) | .estimate.worker.samples")")"

printf '== 4. a working stage shows its worker against the prediction ==\n' >&2
check "120,000 of a typical 300,000 reads 40%" \
  "$(eq 40 "$(field "$(stage 03-working) | .live_share.percent")")"
check "the share names the worker" \
  "$(eq worker "$(field "$(stage 03-working) | .live_share.role")")"
check "it carries both figures it divided" \
  "$(eq "120000/300000" "$(field "$(stage 03-working) | .live_share | \"\(.live_uncached_tokens)/\(.estimate_uncached_tokens)\"")")"
check "and the basis and sample count behind the prediction" \
  "$(eq "model/5" "$(field "$(stage 03-working) | .live_share | \"\(.basis)/\(.samples)\"")")"
check "below twice the median it reads normal" \
  "$(eq normal "$(field "$(stage 03-working) | .live_share.level")")"

printf '== 5. a verifying stage counts only the running dispatch ==\n' >&2
check "150,000 of a typical 60,000 reads 250%, without the settled attempt" \
  "$(eq 250 "$(field "$(stage 04-verifying) | .live_share.percent")")"
check "past twice the median it reads high" \
  "$(eq high "$(field "$(stage 04-verifying) | .live_share.level")")"

printf '== 6. only the heartbeat makes an outlier ==\n' >&2
check "a flagged dispatch reads outlier" \
  "$(eq outlier "$(field "$(stage 05-outlier) | .live_share.level")")"
check "at 1,500% of its typical 100,000" \
  "$(eq 1500 "$(field "$(stage 05-outlier) | .live_share.percent")")"

printf '== 7. a panel shows the verifier furthest past its own prediction ==\n' >&2
check "the SDK verifier at 66,000 of 60,000 speaks for the stage" \
  "$(eq 110 "$(field "$(stage 06-panel) | .live_share.percent")")"
check "named by its own identity, on the role's prediction" \
  "$(eq "Never <never@local>/role" "$(field "$(stage 06-panel) | .live_share | \"\(.identity)/\(.basis)\"")")"

printf '== 8. no phase, no reading, no share ==\n' >&2
check "a waiting stage shows no share" \
  "$(eq null "$(field "$(stage 07-waiting) | .live_share")")"
check "an agent with no reading shows no share" \
  "$(eq null "$(field "$(stage 08-no-reading) | .live_share")")"
check "a settled stage shows no share" \
  "$(eq null "$(field "$(stage 01-known-pair) | .live_share")")"

printf '== 9. the web stage table draws the share inside the status ==\n' >&2
web="$(printf '%s' "$payload" | AUTOMETTA_DASHBOARD_JS="$script_dir/../dashboard/dashboard.js" node -e '
const fs = require("fs"), vm = require("vm");
const repo = JSON.parse(fs.readFileSync(0, "utf8"));
const context = vm.createContext({ window: { location: { protocol: "http:" } }, document: {} });
const source = fs.readFileSync(process.env.AUTOMETTA_DASHBOARD_JS, "utf8");
vm.runInContext(source.slice(0, source.lastIndexOf("  var first =")) + `
  window.captureStages = function (repos) {
    var captured;
    renderPagedTable = function (id, headers, rows) { captured = { headers: headers, rows: rows }; };
    renderStageOrder = function () {};
    renderStagesTable(repos);
    return captured;
  };
})();`, context);
const table = context.window.captureStages([repo]);
const column = table.headers.indexOf("Status");
const out = {};
table.rows.forEach(function (row) {
  const cell = row.cells[column];
  out[row.key.split("/").pop()] = { html: cell.html, text: cell.html.replace(/<[^>]*>/g, ""), sort: cell.sort };
});
process.stdout.write(JSON.stringify(out));
' 2>&1)" || { printf '  FAIL: the stage table did not render (%s)\n' "$web" >&2; fail=1; web='{}'; }
cell() { printf '%s' "$web" | jq -r --arg id "$1" ".[\$id].$2"; }
check "a working stage reads 'working (40%)'" "$(eq "working (40%)" "$(cell 03-working text)")"
check "a high share is marked high" \
  "$([[ "$(cell 04-verifying html)" == *'class="live-share high"'* ]] && echo ok || cell 04-verifying html)"
check "an outlier share is marked outlier" \
  "$([[ "$(cell 05-outlier html)" == *'class="live-share outlier"'* ]] && echo ok || cell 05-outlier html)"
check "the title says it is not completion" \
  "$([[ "$(cell 03-working html)" == *'not completion'* ]] && echo ok || cell 03-working html)"
check "the title gives both figures and the basis" \
  "$([[ "$(cell 03-working html)" == *'120,000 uncached tokens so far this dispatch, against a typical 300,000 (median of 5 Opus worker dispatches here)'* ]] && echo ok || cell 03-working html)"
check "a waiting stage reads 'waiting' alone" "$(eq waiting "$(cell 07-waiting text)")"
check "the share does not move the column sort" "$(eq working "$(cell 03-working sort)")"

printf '== 10. the terminal views carry the share beside the status ==\n' >&2
tui="$(AUTOMETTA_TEST_PAYLOAD="$payload" python3 - "$script_dir/lib/tui/render.py" <<'PY' 2>&1
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("autometta_tui_render", sys.argv[1])
render = importlib.util.module_from_spec(spec)
spec.loader.exec_module(render)
state = render.TuiState(5.0)
state.update(json.loads(os.environ["AUTOMETTA_TEST_PAYLOAD"]), observed_at=0.0)
state.observe_time(0.0)
rows = {}
for text, spans in render.run_lines(state, 100):
    for stage_id in ("03-working", "04-verifying", "05-outlier", "07-waiting"):
        if stage_id in text:
            alert = [text[a:b] for a, b, attr in spans if attr == render.ALERT]
            rows[stage_id] = {"text": " ".join(text.split()), "alert": alert}
print(json.dumps(rows))
PY
)" || { printf '  FAIL: the TUI did not render (%s)\n' "$tui" >&2; fail=1; tui='{}'; }
row() { printf '%s' "$tui" | jq -r --arg id "$1" ".[\$id].$2"; }
check "the TUI run row reads 'WORKER 40%'" \
  "$([[ "$(row 03-working text)" == *"03-working WORKER 40% "* ]] && echo ok || row 03-working text)"
check "a verifying row reads 'VERIFY 250%'" \
  "$([[ "$(row 04-verifying text)" == *"VERIFY 250% "* ]] && echo ok || row 04-verifying text)"
check "an outlier share alone is red" \
  "$(eq '["1500%"]' "$(row 05-outlier alert | jq -c .)")"
check "a high share is not red" "$(eq '[]' "$(row 04-verifying alert | jq -c .)")"
check "a waiting row carries no share" \
  "$([[ "$(row 07-waiting text)" == *"WORKER "* && "$(row 07-waiting text)" != *"%"* ]] && echo ok || row 07-waiting text)"
now_line="$(AUTOMETTA_TICKER_PAYLOAD="$payload" python3 "$script_dir/lib/repo-ticker-render.py" "$repo" 120 40 5 600 \
  | sed -n '/^NOW/{n;n;p;}')"
check "the ticker's NOW line reads 'worker running  40% of typical'" \
  "$([[ "$now_line" == *"worker running  40% of typical  Opus"* ]] && echo ok || printf '%s' "$now_line")"

printf '== 11. no history predicts nothing ==\n' >&2
payload="$("$script_dir/aggregate-dashboard.sh" --repo "$empty" 2>/dev/null)"
check "an empty repo predicts no worker figure" \
  "$(eq null "$(field "$(stage 01-known-pair) | .estimate.worker")")"
check "and no total" \
  "$(eq null "$(field "$(stage 01-known-pair) | .estimate.total_uncached_tokens")")"

if [[ "$fail" -eq 0 ]]; then printf 'live-share-smoke: PASS\n' >&2
else printf 'live-share-smoke: FAIL\n' >&2; fi
exit "$fail"
