#!/usr/bin/env bash
# Offline checks for weekly pacing and the Codex run cap. No provider/model calls.
set -euo pipefail
IFS=$'\n\t'
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture="$(mktemp -d)"
sleeper=""
trap '[[ -z "$sleeper" ]] || kill "$sleeper" 2>/dev/null || true; rm -rf "$fixture"' EXIT
export AUTOMETTA_HOME="$fixture/controller"
export AUTOMETTA_CODEX_SESSIONS="$fixture/sessions"
export AI_QUOTA_DIR="$fixture/quota"
export AI_QUOTA_NOW_EPOCH=2000000000
unset AUTOMETTA_CODEX_QUOTA_POLICY AUTOMETTA_IGNORE_RESERVE AUTOMETTA_IGNORE_PACE AUTOMETTA_RESERVE_GATED \
  AUTOMETTA_CONTROLLER_MANDATE AUTOMETTA_CODEX_MODE AUTOMETTA_CLAUDE_MODE AUTOMETTA_CODEX_ADMIT_PERCENT
mkdir -p "$AUTOMETTA_HOME/log" "$AUTOMETTA_HOME/subscribers" "$AUTOMETTA_CODEX_SESSIONS" "$AI_QUOTA_DIR"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Half a day into the week: slot 1 of 14, pace line 7.14%, 13 slots left.
week_reset=2000561600
week_reset_iso="$(python3 -c 'import sys,datetime as d; print(d.datetime.fromtimestamp(int(sys.argv[1]), d.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$week_reset")"
weekly() {
  jq -nc --arg family "$1" --argjson used "$2" --arg reset "$week_reset_iso" \
    '{family:$family,status:"known",fetched_at:"2033-05-18T03:33:20Z",windows:[{key:(if $family == "codex" then "secondary" else "weekly" end),label:"Weekly",utilization:$used,resets_at:$reset}]}'
}
pace() {
  printf '%s' "$(weekly "$1" "$2")" | AUTOMETTA_PACE_ACTION="${3:-hold}" AUTOMETTA_PACE_STATE="${PACE_STATE:-}" \
    python3 "$script_dir/quota-window.py" pace "$1"
}

verdict="$(pace codex 5)"
[[ "$(jq -r .allowed <<<"$verdict")" == true ]] || fail "under pace held: $verdict"
[[ "$(jq -r .ceiling <<<"$verdict")" == 12.31 ]] || fail "under-pace ceiling is not used + remaining/13: $verdict"
verdict="$(pace codex 16)"
[[ "$(jq -r .allowed <<<"$verdict")" == false ]] || fail "ahead of pace admitted: $verdict"
[[ "$(jq -r .ceiling <<<"$verdict")" == 14.29 ]] || fail "ahead-of-pace ceiling is not the slot-end pace line: $verdict"
[[ "$(jq -r .allowed <<<"$(pace codex 16 observe)")" == true ]] || fail 'observe held'
[[ "$(jq -r .allowed <<<"$(pace codex 99 off)")" == true ]] || fail 'off held'
printf 'PASS a slot may spend the remaining headroom over the slots left; ahead of pace holds\n'

PACE_STATE="$fixture/pace.json"
[[ "$(jq -r .allowed <<<"$(pace codex 5)")" == true ]] || fail 'first sighting held'
[[ "$(jq -r .allowed <<<"$(pace codex 12)")" == true ]] || fail 'spend inside the slot allowance held'
verdict="$(pace codex 12.5)"
[[ "$(jq -r .allowed <<<"$verdict")" == false ]] || fail "spend inside a slot raised its own ceiling: $verdict"
AI_QUOTA_NOW_EPOCH=$((AI_QUOTA_NOW_EPOCH + 43200)) pace codex 12.5 | jq -e '.allowed and .ceiling == 19.79' >/dev/null \
  || fail 'next slot did not rebase on its own first sighting'
unset PACE_STATE
printf 'PASS the slot base is its first sighting, so spend inside a slot cannot raise its ceiling\n'

printf '%s' "$(weekly codex 16 | jq '.windows[0].resets_at = "2033-05-18T00:00:00Z"')" \
  | AUTOMETTA_PACE_ACTION=hold python3 "$script_dir/quota-window.py" pace codex | jq -e '.allowed' >/dev/null \
  || fail 'a passed weekly reset held'
printf '{"status":"unknown"}' | AUTOMETTA_PACE_ACTION=hold python3 "$script_dir/quota-window.py" pace claude | jq -e '.allowed' >/dev/null \
  || fail 'an unknown reading held'
weekly codex 20 | python3 "$script_dir/quota-window.py" codex-admission | jq -e '.allowed' >/dev/null \
  || fail 'a weekly-only Codex reading (no session window) was refused'
printf 'PASS a plan with no session window is admitted on its weekly window alone\n'

# The tick gate: a card is held when any subscription family it names is ahead.
repo="$fixture/repo"
mkdir -p "$repo/state/logs" "$repo/docs/stages"
printf '%s\n' '{"paused_until":null}' > "$repo/state/budget.json"
cat > "$repo/state/state.yaml" <<'YAML'
version: 1
current_stage: 01-active
stages:
  - id: 01-active
    status: in_progress
    worker: GPT-6 Astra
    verifier: Claude Sonnet 5
  - id: 02-next
    status: pending
    worker: GPT-6 Astra
    verifier: Claude Sonnet 5
YAML
cat > "$repo/docs/stages/02-next.md" <<'MD'
# Pace fixture
- **Worker:** GPT-6 Astra
- **Verifier:** Claude Sonnet 5
MD
cat > "$AUTOMETTA_HOME/phat-controller-mandate.yaml" <<'YAML'
window_reserve:
  percent: 0
  action: off
  pace:
    action: hold
    slot_hours: 12
    families: [codex, claude]
    run_cap_slots: 1
YAML
source "$script_dir/tick.sh"
set_readings() {
  AUTOMETTA_QUOTA_TICK_JSON="$(jq -nc --argjson c "$(weekly codex "$1")" --argjson a "$(weekly claude "$2")" '{families:{codex:$c,claude:$a}}')"
}
rm -f "$AUTOMETTA_HOME/quota-pace.json"
set_readings 5 5
quota_gate_role_dispatch "$repo" "$repo/state/state.yaml" 02-next worker || fail "both under pace held: $QUOTA_GATE_REASON"
quota_spawn_permits "$repo" codex "$repo/docs/stages/02-next.md" || fail "manual both under pace held: $QUOTA_GATE_REASON"
rm -f "$AUTOMETTA_HOME/quota-pace.json"
set_readings 5 30
if quota_gate_role_dispatch "$repo" "$repo/state/state.yaml" 02-next worker; then fail 'Claude verifier ahead of pace admitted the card'; fi
[[ "$QUOTA_GATE_REASON" == claude\ weekly* ]] || fail "hold did not name Claude: $QUOTA_GATE_REASON"
if quota_spawn_permits "$repo" codex "$repo/docs/stages/02-next.md"; then fail 'manual spawn admitted a card ahead of pace'; fi
quota_gate_role_dispatch "$repo" "$repo/state/state.yaml" 01-active verifier || fail 'admitted card verifier held by pace'
AUTOMETTA_IGNORE_PACE=1 quota_gate_role_dispatch "$repo" "$repo/state/state.yaml" 02-next worker || fail 'AUTOMETTA_IGNORE_PACE=1 still held'
yq -i '.window_reserve.pace.families = ["codex"]' "$AUTOMETTA_HOME/phat-controller-mandate.yaml"
quota_gate_role_dispatch "$repo" "$repo/state/state.yaml" 02-next worker || fail 'unpaced family held the card'
[[ "$(jq -r '.paused_until' "$repo/state/budget.json")" == null ]] || fail 'pace hold paused the repo'
printf 'PASS a new card is held while a family it names is ahead of pace; its verifier and active work are not\n'

# Run cap: the heartbeat kills a Codex dispatch once it has moved the weekly
# window by a slot allowance since it started.
rm -f "$AUTOMETTA_HOME/quota-pace.json"
rollout() {
  printf '{"timestamp":"2033-05-18T03:33:20Z","payload":{"rate_limits":{"secondary":{"used_percent":%s,"window_minutes":10080,"resets_at":%s}}}}\n' \
    "$1" "$week_reset" > "$AUTOMETTA_CODEX_SESSIONS/rollout-fixture.jsonl"
}
rollout 5
sleep 300 &
sleeper=$!
disown "$sleeper"
agent="$("$script_dir/register-agent.sh" "$repo" "$sleeper" worker codex "GPT-6 Astra" "$repo/docs/stages/02-next.md" "$repo/state/logs/02-next-worker.log")"
jq -e '.quota_start.used == 5 and .quota_start.run_cap_percent == 7.31' "$agent" >/dev/null \
  || fail "registration did not stamp the run cap: $(jq -c '.quota_start' "$agent")"
rollout 12
"$script_dir/heartbeat.sh" "$repo" >/dev/null
kill -0 "$sleeper" 2>/dev/null || fail 'run under its cap was killed'
rollout 12.4
output="$("$script_dir/heartbeat.sh" "$repo")"
[[ "$output" == *"KILLED: quota run cap"* ]] || fail "run past its cap was not reported killed: $output"
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$sleeper" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$sleeper" 2>/dev/null; then fail 'run past its cap is still alive'; fi
sleeper=""
printf 'PASS a Codex run is killed once it has moved the weekly window by its slot allowance\n'
