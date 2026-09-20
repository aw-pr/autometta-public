#!/usr/bin/env bash
# reserve-default-smoke.sh: the provider-window reserve is on unless it is
# switched off, and a manual spawn honours it. Card 137. Offline fixtures,
# injected readings, no token spend.
#
# The defects it pins: before this card the reserve was off for any host
# that had not answered the setup question (template ships percent empty,
# empty resolved to 0/off), and scripts/spawn-worker.sh never consulted it,
# so an orchestrator dispatching by hand could start a card at 100% of a
# window and hand the rest of the run to purchased top-up credit.
# shellcheck disable=SC2034  # AUTOMETTA_QUOTA_TICK_JSON is reset to force a re-read
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected $1, got $2"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing $2"; }

export AUTOMETTA_HOME="$fixture/controller"
export AI_QUOTA_DIR="$fixture/quota"
export AUTOMETTA_CODEX_SESSIONS="$fixture/codex-sessions"
export AI_QUOTA_NOW_EPOCH=2000000000
mkdir -p "$AUTOMETTA_HOME/subscribers" "$AUTOMETTA_HOME/log" "$AI_QUOTA_DIR" \
  "$AUTOMETTA_CODEX_SESSIONS/2033/05/18"
unset AUTOMETTA_IGNORE_RESERVE AUTOMETTA_RESERVE_GATED AUTOMETTA_CONTROLLER_MANDATE

# Readings: Claude comfortably inside its windows, Codex at a chosen 5-hour
# utilisation with a future reset. The reset year is 2033 so the "reset is
# in the future" branch of quota_gate_reading holds for as long as the
# fixture is in use.
write_codex_reading() {
  cat > "$AUTOMETTA_CODEX_SESSIONS/2033/05/18/rollout-fixture.jsonl" <<JSONL
{"timestamp":"2033-05-18T03:30:00Z","type":"event_msg","payload":{"rate_limits":{"primary":{"used_percent":$1,"window_minutes":300,"resets_at":2000009000},"secondary":{"used_percent":31,"window_minutes":10080,"resets_at":2000600000},"plan_type":"plus"}}}
JSONL
}
cat > "$AI_QUOTA_DIR/claude.json" <<'JSON'
{"fetched_at":"2033-05-18T03:33:00Z","source":"fixture","windows":[
  {"key":"5-hour","label":"5-hour","utilization":30,"resets_at":"2033-05-18T08:00:00Z"},
  {"key":"weekly","label":"Weekly","utilization":33,"resets_at":"2033-05-21T00:00:00Z"}]}
JSON
write_codex_reading 85

repo="$fixture/repo"
mkdir -p "$repo/state/logs" "$repo/stage-cards"
git -C "$fixture" init -q -b dev repo
cat > "$repo/state/state.yaml" <<'YAML'
version: 1
current_stage: null
stages:
  - id: 01-manual-card
    status: pending
    worker: "Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>"
    verifier: "Claude Sonnet 5 <claude-sonnet-5@local>"
YAML
cat > "$repo/state/budget.json" <<'JSON'
{"paused_until":null,"paused_reason":null}
JSON
card="$repo/stage-cards/01-manual-card.md"
cat > "$card" <<'MD'
# Stage card 01: manual card

## Metadata

- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Worker wall-clock:** 5 minutes
MD

mandate="$AUTOMETTA_HOME/phat-controller-mandate.yaml"
write_mandate() {
  cat > "$mandate" <<YAML
window_reserve:
  percent: $1
  action: $2
YAML
}

# shellcheck source=./quota-window.sh
source "$script_dir/quota-window.sh"

reserve_of() { quota_reserve_settings "$mandate" "$repo" | cut -f1-2 | tr '\t' ' '; }

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/137-no-new-card-past-the-reserve-line.md

# --- Acceptance 1: the shipped template, unanswered, and an unparseable
# answer both resolve to the default, 20% hold. Only an explicit valid zero
# or action: off switches the reserve off. No mandate file at all is off,
# because init-host installs the template and a host without it is not yet
# initialised (and every fixture controller home in the smokes has none).
rm -f "$mandate"
assert_eq "0 off" "$(reserve_of)" "no mandate file"
cp "$script_dir/../templates/phat-controller-mandate.yaml.tpl" "$mandate"
assert_eq "20 hold" "$(reserve_of)" "the shipped template, unanswered"
write_mandate abc hold
assert_eq "20 hold" "$(reserve_of)" "unparseable percent"
write_mandate 20 sometimes
assert_eq "20 hold" "$(reserve_of)" "unknown action"
write_mandate 0 hold
assert_eq "0 hold" "$(reserve_of)" "explicit zero"
write_mandate 25 off
assert_eq "25 off" "$(reserve_of)" "explicit action off"
write_mandate 35 observe
assert_eq "35 observe" "$(reserve_of)" "an answered mandate is honoured as written"
printf 'PASS acceptance 1: the reserve defaults to 20%% hold and only an explicit answer turns it off\n'

# --- Acceptance 2: under the default, a manual codex spawn at 85% of the
# 5-hour window exits 4 before anything is spawned or written; the refusal
# names the window and the override.
cp "$script_dir/../templates/phat-controller-mandate.yaml.tpl" "$mandate"
spawn_rc=0
spawn_err="$("$script_dir/spawn-worker.sh" "$card" "$repo" 2>&1 >/dev/null)" || spawn_rc=$?
assert_eq 4 "$spawn_rc" "manual spawn at 85% exits 4"
assert_contains "$spawn_err" "5-hour inside 20% reserve" "refusal names the binding window and reserve"
assert_contains "$spawn_err" "AUTOMETTA_IGNORE_RESERVE=1" "refusal names the override"
assert_eq null "$(yq -r '.stages[0].worker_pid // "null"' "$repo/state/state.yaml")" "no worker pid recorded"
assert_eq "" "$(ls "$repo/state/logs")" "no worker log created"
assert_eq null "$(jq -r '.paused_until' "$repo/state/budget.json")" "a manual refusal pauses nothing"
printf 'PASS acceptance 2: a manual spawn past the reserve line is refused with exit 4 and no side effects\n'

# --- Acceptance 3: the line is 80% used. 79% dispatches; 80% holds. Each
# family is judged on its own windows: the codex hold leaves claude free.
write_codex_reading 79
AUTOMETTA_QUOTA_TICK_JSON=""
quota_spawn_permits "$repo" codex || fail "79% used should permit a new card"
write_codex_reading 80
AUTOMETTA_QUOTA_TICK_JSON=""
held_rc=0
quota_spawn_permits "$repo" codex || held_rc=$?
assert_eq 1 "$held_rc" "80% used holds"
quota_spawn_permits "$repo" claude || fail "claude at 30% is not held by the codex window"
printf 'PASS acceptance 3: the reserve line is 80%% used, judged per family\n'

# --- Acceptance 4: the two escapes are explicit. The tick marks its own
# spawns as already gated so a refresh between its gate and the spawn cannot
# halt the repo; the operator overrides by name. Both leave a reason.
AUTOMETTA_RESERVE_GATED=1 quota_spawn_permits "$repo" codex || fail "tick-marked spawn must pass"
assert_contains "$QUOTA_GATE_REASON" "already applied by the tick" "tick escape names itself"
AUTOMETTA_IGNORE_RESERVE=1 quota_spawn_permits "$repo" codex || fail "operator override must pass"
assert_contains "$QUOTA_GATE_REASON" "AUTOMETTA_IGNORE_RESERVE=1" "operator escape names itself"
write_mandate 0 hold
AUTOMETTA_QUOTA_TICK_JSON=""
quota_spawn_permits "$repo" codex || fail "percent: 0 must switch the gate off"
assert_eq "reserve off" "$QUOTA_GATE_REASON" "switched off says so"
printf 'PASS acceptance 4: the escapes are explicit and each leaves its reason\n'

# --- Acceptance 5: an unknown reading still fails open on the manual path,
# exactly as it does in the tick.
cp "$script_dir/../templates/phat-controller-mandate.yaml.tpl" "$mandate"
rm -f "$AUTOMETTA_CODEX_SESSIONS/2033/05/18/rollout-fixture.jsonl"
AUTOMETTA_QUOTA_TICK_JSON=""
quota_spawn_permits "$repo" codex || fail "unknown reading must fail open"
assert_contains "$QUOTA_GATE_REASON" "reading unknown" "fail-open names the unknown"
printf 'PASS acceptance 5: an unknown reading fails open with its reason\n'

# AUTOMETTA-CONTRACT-END

bash -n "$script_dir/quota-window.sh" "$script_dir/spawn-worker.sh" "$script_dir/tick.sh"
printf 'PASS reserve-default-smoke: no new card starts past the reserve line\n'
