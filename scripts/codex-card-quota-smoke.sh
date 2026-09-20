#!/usr/bin/env bash
# Offline admission and completion checks. No provider/model calls.
set -euo pipefail
IFS=$'\n\t'
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
export AUTOMETTA_HOME="$fixture/controller"
export AUTOMETTA_CODEX_SESSIONS="$fixture/sessions"
export AI_QUOTA_DIR="$fixture/quota"
export AI_QUOTA_NOW_EPOCH=2000000000
unset AUTOMETTA_CODEX_QUOTA_POLICY AUTOMETTA_IGNORE_RESERVE AUTOMETTA_RESERVE_GATED AUTOMETTA_CONTROLLER_MANDATE AUTOMETTA_CODEX_MODE
mkdir -p "$AUTOMETTA_HOME/log" "$AUTOMETTA_HOME/subscribers" "$AUTOMETTA_CODEX_SESSIONS" "$AI_QUOTA_DIR"
repo="$fixture/repo"
mkdir -p "$repo/state/logs" "$repo/docs/stages"
printf '%s\n' '{"paused_until":null}' > "$repo/state/budget.json"
cat > "$repo/state/state.yaml" <<'YAML'
version: 1
current_stage: 01-active
stages:
  - id: 01-active
    status: in_progress
    worker: Claude Sonnet 5
    verifier: GPT-5.6 Sol
  - id: 02-next
    status: pending
    worker: GPT-6 Astra
    verifier: Claude Sonnet 5
YAML
cat > "$repo/docs/stages/02-next.md" <<'MD'
# Quota admission fixture
- **Worker:** GPT-6 Astra
- **Verifier:** Claude Sonnet 5
MD
cat > "$AUTOMETTA_HOME/phat-controller-mandate.yaml" <<'YAML'
window_reserve:
  percent: 20
  action: hold
YAML
source "$script_dir/tick.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
reading() {
  jq -nc --argjson used "$1" --argjson weekly "${2:-30}" '{family:"codex",status:"known",fetched_at:"2033-05-18T03:33:20Z",windows:[{key:"primary",label:"5-hour",utilization:$used,resets_at:"2033-05-18T06:03:20Z"},{key:"secondary",label:"Weekly",utilization:$weekly,resets_at:"2033-05-25T03:33:20Z"}]}'
}
set_reading() {
  AUTOMETTA_QUOTA_TICK_JSON="$(jq -nc --argjson c "$1" '{families:{codex:$c,claude:{family:"claude",status:"known",windows:[{key:"five_hour",label:"5-hour",utilization:30,resets_at:"2033-05-18T06:03:20Z"}]}}}')"
}
# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/138-codex-card-quota.md

for used in 0 79 80 99 99.9; do
  set_reading "$(reading "$used")"
  quota_gate_role_dispatch "$repo" "$repo/state/state.yaml" 02-next worker || fail "$used% held"
  quota_spawn_permits "$repo" codex "$repo/docs/stages/02-next.md" || fail "manual $used% held"
done
for pair in '100 30' '105 30' '50 100'; do
  used="${pair%% *}"; weekly="${pair#* }"
  set_reading "$(reading "$used" "$weekly")"
  if quota_gate_role_dispatch "$repo" "$repo/state/state.yaml" 02-next worker; then fail "$pair admitted"; fi
  if quota_spawn_permits "$repo" codex "$repo/docs/stages/02-next.md"; then fail "manual $pair admitted"; fi
  quota_gate_role_dispatch "$repo" "$repo/state/state.yaml" 01-active verifier || fail 'active verifier held'
done
[[ "$(jq -r '.paused_until' "$repo/state/budget.json")" == null ]] || fail 'new-card hold stranded active work with a repo pause'
set_reading "$(reading 100)"
if quota_gate_role_dispatch "$repo" "$repo/state/state.yaml" 01-active worker; then fail 'Claude worker started a new Codex-verifier card at 100%'; fi
if AUTOMETTA_IGNORE_RESERVE=1 quota_spawn_permits "$repo" codex; then fail 'reserve escape bypassed exhaustion'; fi
for invalid in \
  '{"status":"unknown"}' \
  "$(reading 20 | jq '.fetched_at="2033-05-18T03:00:00Z"')" \
  "$(reading 20 | jq '.windows[0].resets_at=null')" \
  "$(reading 20 | jq '.windows[0].resets_at="2033-05-18T03:00:00Z"')" \
  "$(reading 20 | jq '.windows |= .[:1]')"; do
  set_reading "$invalid"
  if quota_gate_role_dispatch "$repo" "$repo/state/state.yaml" 02-next worker; then fail 'uncertain quota admitted'; fi
done
set_reading "$(reading 0 0)"
quota_gate_role_dispatch "$repo" "$repo/state/state.yaml" 02-next worker || fail 'fresh reset did not resume'
printf 'PASS below-100 admission, exhausted session/weekly hold, active verifier completion, stale/unknown hold and fresh reset\n'
# The real manual entry point must refuse before resolving credentials or spawning.
cat > "$AUTOMETTA_CODEX_SESSIONS/rollout-fixture.jsonl" <<'JSON'
{"timestamp":"2033-05-18T03:33:20Z","payload":{"rate_limits":{"primary":{"used_percent":105,"window_minutes":300,"resets_at":2000009000},"secondary":{"used_percent":30,"window_minutes":10080,"resets_at":2000600000}}}}
JSON
[[ "$(python3 "$script_dir/quota-window.py" codex | jq -r '.windows[0].utilization')" == 105.0 ]] || fail 'reader discarded over-100 evidence'
rc=0
"$script_dir/spawn-worker.sh" "$repo/docs/stages/02-next.md" "$repo" > "$fixture/spawn.log" 2>&1 || rc=$?
[[ "$rc" == 4 ]] || fail "real spawn returned $rc"
[[ -z "$(ls -A "$repo/state/logs")" ]] || fail 'refused spawn created worker log'
[[ "$(yq -r '.stages[1].worker_pid // "null"' "$repo/state/state.yaml")" == null ]] || fail 'refused spawn recorded pid'
printf 'PASS real manual spawn refused with exit 4 and no worker; over-100 telemetry preserved\n'
# API/local execution does not draw on the subscription allowance.
set_reading '{"status":"unknown"}'
for mode in api local; do
  AUTOMETTA_CODEX_MODE="$mode" quota_spawn_permits "$repo" codex "$repo/docs/stages/02-next.md" || fail "$mode route gated by subscription"
done
printf 'PASS non-subscription routes do not require subscription telemetry\n'

# AUTOMETTA-CONTRACT-END

# Supplemental regression: a live account snapshot can observe a manual reset
# before any new model turn has written a rollout event.
python3 - "$script_dir" <<'PYTEST'
import importlib.util, json, os
from pathlib import Path
import sys
spec = importlib.util.spec_from_file_location("quota", Path(sys.argv[1]) / "quota-window.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
path = Path(os.environ["AI_QUOTA_DIR"]) / "codex.json"
rollout = module.read_codex()
assert rollout["windows"][0]["utilization"] == 105
snapshot = {**rollout, "source": "codex-app-server", "fetched_at": "2033-05-18T03:33:21Z"}
snapshot["windows"][0]["utilization"] = 12
path.write_text(json.dumps(snapshot))
assert module.read_codex()["windows"][0]["utilization"] == 12
snapshot["fetched_at"] = "2033-05-18T03:33:19Z"
path.write_text(json.dumps(snapshot))
assert module.read_codex()["windows"][0]["utilization"] == 105
snapshot["fetched_at"] = "2033-05-18T03:00:00Z"
path.write_text(json.dumps(snapshot))
assert module.read_codex()["windows"][0]["utilization"] == 105
print("PASS fresh account snapshot supersedes old rollout; older/stale snapshots do not")
PYTEST
