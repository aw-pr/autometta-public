#!/usr/bin/env bash
# Offline contract proof for provider-window readings and the pre-dispatch gate.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() {
  [[ "$1" == "$2" ]] || fail "$3: expected $1, got $2"
}
assert_contains() {
  [[ "$1" == *"$2"* ]] || fail "$3: missing $2"
}

export AI_QUOTA_DIR="$fixture/quota"
export AUTOMETTA_CODEX_SESSIONS="$fixture/codex-sessions"
export AI_QUOTA_NOW_EPOCH=2000000000
export AI_QUOTA_STALE_SECONDS=600
export AUTOMETTA_HOME="$fixture/controller"
mkdir -p "$AI_QUOTA_DIR" "$AUTOMETTA_CODEX_SESSIONS/2026/08/25" \
  "$AUTOMETTA_HOME/log" "$AUTOMETTA_HOME/subscribers"

write_claude() {
  local fetched="$1"
  cat > "$AI_QUOTA_DIR/claude.json" <<JSON
{
  "fetched_at": "${fetched}",
  "source": "vibe-menuapp",
  "access_token": "SECRET_DO_NOT_COPY",
  "windows": [
    {"key":"five_hour","label":"5-hour","utilization":96,"resets_at":"2033-05-18T03:38:20Z","token":"SECRET_DO_NOT_COPY"},
    {"key":"seven_day","label":"Weekly","utilization":42,"resets_at":"2033-05-24T00:00:00Z"}
  ]
}
JSON
}

cat > "$AUTOMETTA_CODEX_SESSIONS/2026/08/25/rollout-fixture.jsonl" <<'JSONL'
{"timestamp":"2033-05-18T03:30:00Z","type":"event_msg","payload":{"rate_limits":{"primary":{"used_percent":73.5,"window_minutes":300,"resets_at":2000000500},"secondary":{"used_percent":31,"window_minutes":10080,"resets_at":2000600000},"plan_type":"plus"}}}
JSONL

write_claude 2033-05-18T03:30:00Z
claude="$(python3 "$script_dir/quota-window.py" claude)"
assert_eq known "$(printf '%s' "$claude" | jq -r '.status')" "Claude fixture parses"
assert_eq 5-hour "$(printf '%s' "$claude" | jq -r '.windows[0].label')" "Claude label"
assert_eq 96.0 "$(printf '%s' "$claude" | jq -r '.windows[0].utilization')" "Claude utilisation"
assert_eq 2033-05-18T03:38:20Z "$(printf '%s' "$claude" | jq -r '.windows[0].resets_at')" "Claude reset"
[[ "$claude" != *SECRET_DO_NOT_COPY* ]] || fail "Claude reader propagated a credential-shaped field"
printf 'PASS Claude snapshot: label, used percentage and reset parsed; extra token fields discarded\n'

codex="$(python3 "$script_dir/quota-window.py" codex)"
assert_eq known "$(printf '%s' "$codex" | jq -r '.status')" "Codex rollout parses"
assert_eq 73.5 "$(printf '%s' "$codex" | jq -r '.windows[0].utilization')" "Codex utilisation"
assert_eq 5-hour "$(printf '%s' "$codex" | jq -r '.windows[0].label')" "Codex label"
printf 'PASS Codex rollout: same interface, local rate_limits evidence parsed\n'

rm "$AI_QUOTA_DIR/claude.json"
absent="$(python3 "$script_dir/quota-window.py" claude)"
assert_eq unknown "$(printf '%s' "$absent" | jq -r '.status')" "absent snapshot unknown"
assert_eq snapshot\ absent "$(printf '%s' "$absent" | jq -r '.reason')" "absent reason"
printf '{bad json\n' > "$AI_QUOTA_DIR/claude.json"
malformed="$(python3 "$script_dir/quota-window.py" claude)"
assert_eq snapshot\ malformed "$(printf '%s' "$malformed" | jq -r '.reason')" "malformed reason"
write_claude 2033-05-18T03:16:40Z
stale="$(python3 "$script_dir/quota-window.py" claude)"
assert_eq unknown "$(printf '%s' "$stale" | jq -r '.status')" "stale snapshot unknown"
assert_contains "$(printf '%s' "$stale" | jq -r '.reason')" "snapshot stale" "stale reason"
printf 'PASS absent, malformed and stale snapshots are three explicit unknowns\n'

# Restore the stage-54 replay: 96% used, ten-percent reserve, reset 500 seconds
# ahead. The historical run started a worker; this gate must hold it instead.
write_claude 2033-05-18T03:30:00Z
repo="$fixture/replay-repo"
mkdir -p "$repo/state" "$repo/stage-cards"
git -C "$fixture" init -q -b dev replay-repo
cat > "$repo/state/state.yaml" <<'YAML'
version: 1
current_stage: null
stages:
  - id: 54-a-warden-pass-minds-the-queue
    status: pending
    worker: "Claude Sonnet 5 <claude-sonnet-5@local>"
    verifier: "GPT-5.6 Sol <gpt-5-6-sol@local>"
YAML
cat > "$repo/state/budget.json" <<'JSON'
{"paused_until":null,"paused_reason":null}
JSON
cat > "$AUTOMETTA_HOME/phat-controller-mandate.yaml" <<'YAML'
window_reserve:
  percent: 10
  action: hold
YAML

# shellcheck source=./tick.sh
source "$script_dir/tick.sh"
quota_refresh_tick
held_rc=0
quota_gate_role_dispatch "$repo" "$repo/state/state.yaml" \
  54-a-warden-pass-minds-the-queue worker || held_rc=$?
assert_eq 1 "$held_rc" "near-exhausted stage-54 worker held"
assert_eq 2000000300 "$(jq -r '.paused_until' "$repo/state/budget.json")" "pause uses snapshot reset"
assert_contains "$(jq -r '.paused_reason' "$repo/state/budget.json")" "5-hour" "pause names binding window"
printf 'PASS stage-54 replay held before spawn; pause carries the snapshot reset 2033-05-18T03:38:20Z\n'

# Zero is explicitly off and unknown is explicitly fail-open. Neither mutates
# state or consumes a role attempt.
jq '.paused_until=null | .paused_reason=null' "$repo/state/budget.json" > "$repo/state/budget.next"
mv "$repo/state/budget.next" "$repo/state/budget.json"
yq -i '.window_reserve.percent = 0' "$AUTOMETTA_HOME/phat-controller-mandate.yaml"
quota_gate_role_dispatch "$repo" "$repo/state/state.yaml" \
  54-a-warden-pass-minds-the-queue worker || fail "zero reserve blocked dispatch"
assert_eq null "$(jq -r '.paused_until' "$repo/state/budget.json")" "zero reserve leaves pause untouched"

yq -i '.window_reserve.percent = 10' "$AUTOMETTA_HOME/phat-controller-mandate.yaml"
# Read by the sourced quota_write_repo_state helper.
# shellcheck disable=SC2034
AUTOMETTA_QUOTA_TICK_JSON="$(jq -nc '{read_at:null,families:{claude:{family:"claude",status:"unknown",reason:"snapshot absent",source:null,fetched_at:null,windows:[]},codex:{family:"codex",status:"unknown",reason:"no rollout files",source:null,fetched_at:null,windows:[]}}}')"
quota_gate_role_dispatch "$repo" "$repo/state/state.yaml" \
  54-a-warden-pass-minds-the-queue worker || fail "unknown reading blocked dispatch"
assert_eq null "$(jq -r '.paused_until' "$repo/state/budget.json")" "unknown leaves pause untouched"

for failure_reading in "$absent" "$malformed" "$stale"; do
  AUTOMETTA_QUOTA_TICK_JSON="$(jq -nc --argjson claude "$failure_reading" --argjson codex "$codex" \
    '{read_at:null,families:{claude:$claude,codex:$codex}}')"
  quota_log_tick_readings
done
tick_log="$(cat "$AUTOMETTA_HOME/log/tick-$(date +%F).log")"
assert_contains "$tick_log" "snapshot absent" "absent unknown logged"
assert_contains "$tick_log" "snapshot malformed" "malformed unknown logged"
assert_contains "$tick_log" "snapshot stale" "stale unknown logged"
[[ ! -e "$repo/state/cost-log.jsonl" ]] || fail "quota reads wrote a cost-log row"
printf 'PASS reserve zero and unknown reading preserve the pre-existing dispatch path\n'
printf 'PASS all three Claude failure cases are logged and add no cost-log row\n'

# Setup refuses a spend-only answer, then records the explicit reserve in both
# the rendered seed and its machine-readable mandate.
seed="$fixture/rendered-seed.md"
reserve_missing_rc=0
"$script_dir/render-controller-seed.sh" --spend-authority 'Fixture authority' \
  --repo "$repo" --out "$seed" >/dev/null 2>&1 || reserve_missing_rc=$?
assert_eq 2 "$reserve_missing_rc" "setup refuses missing reserve answer"
[[ ! -e "$seed" ]] || fail "setup wrote a seed without the reserve answer"
"$script_dir/render-controller-seed.sh" --spend-authority 'Fixture authority' \
  --window-reserve-percent 12 --window-reserve-action hold \
  --repo "$repo" --out "$seed" >/dev/null
assert_contains "$(cat "$seed")" 'Leave 12% of each reported provider window unspent' "rendered reserve"
assert_eq 12 "$(yq -r '.window_reserve.percent' "$AUTOMETTA_HOME/phat-controller-mandate.yaml")" "mandate reserve"
printf 'PASS setup run rendered seed with the answered 12%% hold reserve; no answer rendered nothing\n'

# The exact once-per-tick value is what both displays consume.
quota_refresh_tick
quota_write_repo_state "$repo"
[[ "$(cat "$repo/state/quota-window.json")" != *SECRET_DO_NOT_COPY* ]] || fail "credential reached repo state"
cat > "$AUTOMETTA_HOME/subscribers/replay.yaml" <<YAML
enabled: true
repo_path: "$repo"
manifest_path: "$repo/.autometta.local.yaml"
YAML
"$script_dir/aggregate-dashboard.sh" >/dev/null
assert_eq known "$(jq -r '.repos[0].quota.families.claude.status' "$AUTOMETTA_HOME/dashboard/data.json")" "web dashboard known reading"
assert_eq 96.0 "$(jq -r '.repos[0].quota.families.claude.windows[0].utilization' "$AUTOMETTA_HOME/dashboard/data.json")" "web dashboard utilisation"
known_ticker="$(AUTOMETTA_TICKER_COLUMNS=160 AUTOMETTA_TICKER_ROWS=40 "$script_dir/agent-ticker.sh" "$repo" --once)"
assert_contains "$known_ticker" "quota claude: 5-hour 96.0% used" "tmux known display"

AUTOMETTA_QUOTA_TICK_JSON="$(jq -nc '{read_at:null,families:{claude:{family:"claude",status:"unknown",reason:"snapshot absent",source:null,fetched_at:null,windows:[]},codex:{family:"codex",status:"unknown",reason:"no rollout files",source:null,fetched_at:null,windows:[]}}}')"
quota_write_repo_state "$repo"
"$script_dir/aggregate-dashboard.sh" >/dev/null
assert_eq snapshot\ absent "$(jq -r '.repos[0].quota.families.claude.reason' "$AUTOMETTA_HOME/dashboard/data.json")" "web dashboard unknown reason"
ticker_out="$(AUTOMETTA_TICKER_COLUMNS=160 AUTOMETTA_TICKER_ROWS=40 "$script_dir/agent-ticker.sh" "$repo" --once)"
assert_contains "$ticker_out" "quota claude: unknown (snapshot absent)" "tmux unknown display"
printf 'PASS fleet pane and web dashboard show known readings and degrade to explicit unknowns\n'

runtime_files=(
  "$script_dir/quota-window.py"
  "$script_dir/quota-window.sh"
  "$script_dir/tick.sh"
  "$script_dir/agent-ticker.sh"
  "$script_dir/aggregate-dashboard.sh"
)
if rg -n 'api\.anthropic\.com/api/oauth/usage|find-generic-password|/usr/bin/security|[[:space:]]security[[:space:]]' \
  "${runtime_files[@]}"; then
  fail "runtime contains an endpoint or Keychain reader"
fi
if rg -n 'SECRET_DO_NOT_COPY|access_token|Authorization' \
  "$repo/state/quota-window.json" "$AUTOMETTA_HOME/dashboard/data.json" "$AUTOMETTA_HOME/log"; then
  fail "credential-shaped fixture material reached a log or state surface"
fi
printf 'PASS runtime grep: no usage endpoint, Keychain command or credential propagation\n'

for file in quota-window.sh quota-window-smoke.sh tick.sh agent-ticker.sh aggregate-dashboard.sh render-controller-seed.sh install-launchagent-phat-controller.sh; do
  bash -n "$script_dir/$file"
done
PYTHONPYCACHEPREFIX="$fixture/pycache" python3 -m py_compile "$script_dir/quota-window.py"
printf 'PASS syntax: touched shell and Python files parse\n'
