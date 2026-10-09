#!/usr/bin/env bash
# Offline proof for stage card 148: a model's own window holds only that model.
#
# The Claude reading carries a family-wide 5-hour and weekly window and a
# window scoped to one model (key weekly-fable, label "Weekly (Fable)"). The
# reserve gate used to take the most-used window of the family, so a Fable
# window past the reserve held an Opus verifier that never draws on it. This
# drives the gate, the tick's role gate and the manual spawn gate against a
# fixture repo with an injected reading. No auth, no network, no token spend.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() {
  [[ "$1" == "$2" ]] || fail "$3: expected $1, got $2"
}

export AUTOMETTA_HOME="$fixture/controller"
mkdir -p "$AUTOMETTA_HOME/subscribers" "$AUTOMETTA_HOME/log"
cat > "$AUTOMETTA_HOME/phat-controller-mandate.yaml" <<'YAML'
window_reserve:
  percent: 30
  action: hold
  codex_admit_percent: 100
YAML

repo="$fixture/repo"
git -C "$fixture" init -q -b dev repo
mkdir -p "$repo/state" "$repo/stage-cards"
cat > "$repo/state/state.yaml" <<'YAML'
version: 1
current_stage: opus-stage
stages:
  - id: opus-stage
    status: in_progress
    worker: "Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>"
    verifier: "Claude Opus 5.5 <claude-opus-5-5@local>"
  - id: fable-stage
    status: pending
    worker: "Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>"
    verifier: "Claude Fable 5.1 <claude-fable-5-1@local>"
YAML
reset_budget() {
  printf '%s\n' '{"paused_until":null,"paused_reason":null}' > "$repo/state/budget.json"
}
reset_budget

card_for() {
  local path="$repo/stage-cards/$1.md"
  printf '# Stage card\n\n## Metadata\n\n- **Worker:** %s\n- **Verifier:** %s\n' "$2" "$3" > "$path"
  printf '%s\n' "$path"
}
opus_card="$(card_for opus-worker "Claude Opus 5.5 <claude-opus-5-5@local>" "Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>")"
fable_card="$(card_for fable-worker "Claude Fable 5.1 <claude-fable-5-1@local>" "Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>")"

# The shape quota-window.py printed for claude on 2026-10-09.
reading() {
  local weekly="$1" fable="$2"
  jq -nc --argjson weekly "$weekly" --argjson fable "$fable" '
    {read_at:null, families:{
      claude:{family:"claude", status:"known", reason:null, source:"claude", fetched_at:null,
        windows:[
          {key:"5-hour", label:"5-hour", utilization:8, resets_at:"2033-05-18T03:38:20Z"},
          {key:"weekly", label:"Weekly", utilization:$weekly, resets_at:"2033-05-20T00:00:00Z"},
          {key:"weekly-fable", label:"Weekly (Fable)", utilization:$fable, resets_at:"2033-05-21T00:00:00Z"}]},
      codex:{family:"codex", status:"known", reason:null, source:"fixture", fetched_at:null,
        windows:[
          {key:"primary", label:"5-hour", utilization:0, resets_at:"2033-05-18T03:38:20Z"},
          {key:"secondary", label:"Weekly", utilization:60, resets_at:"2033-05-22T00:00:00Z"}]}
    }}'
}

epoch_of() { date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || date -u -d "$1" +%s; }
fable_reset_epoch="$(epoch_of 2033-05-21T00:00:00Z)"

# shellcheck source=./tick.sh
source "$script_dir/tick.sh"

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/148-a-model-window-holds-only-its-model.md

fable_hot="$(reading 46 73)"
claude_fable_hot="$(jq -c '.families.claude' <<<"$fable_hot")"

# --- Acceptance 1: the pure gate takes the dispatched model as an optional
# fourth argument. A window scoped to another model is not consulted.
rc=0; quota_gate_reading "$claude_fable_hot" 30 hold claude-opus-5-5 || rc=$?
assert_eq 0 "$rc" "Opus is not held by the Fable window"
rc=0; quota_gate_reading "$claude_fable_hot" 30 hold claude-fable-5-1 || rc=$?
assert_eq 1 "$rc" "Fable is held by its own window"
assert_eq "Weekly (Fable)" "$QUOTA_GATE_WINDOW" "Fable hold names its window"
assert_eq "$fable_reset_epoch" "$QUOTA_GATE_RESET" "Fable hold carries its own reset"
printf 'PASS acceptance 1: a model-scoped window binds only its model\n'

# --- Acceptance 2: with no model named the gate is as conservative as it
# was before this card, so a caller that cannot name its seat is never
# admitted past a window it might draw on.
rc=0; quota_gate_reading "$claude_fable_hot" 30 hold || rc=$?
assert_eq 1 "$rc" "no model named: every window of the family binds"
assert_eq "Weekly (Fable)" "$QUOTA_GATE_WINDOW" "no model named: hold names the most-used window"
rc=0; quota_gate_reading "$claude_fable_hot" 30 hold "" || rc=$?
assert_eq 1 "$rc" "empty model: every window of the family binds"
printf 'PASS acceptance 2: an unnamed seat sees every window\n'

# --- Acceptance 3: a family-wide window still binds every model, the scoped
# model included, and the most-used binding window is the one reported.
weekly_hot="$(jq -c '.families.claude' <<<"$(reading 75 40)")"
rc=0; quota_gate_reading "$weekly_hot" 30 hold claude-opus-5-5 || rc=$?
assert_eq 1 "$rc" "family weekly past the reserve holds Opus"
assert_eq "Weekly" "$QUOTA_GATE_WINDOW" "Opus hold names the family window"
both_hot="$(jq -c '.families.claude' <<<"$(reading 72 90)")"
rc=0; quota_gate_reading "$both_hot" 30 hold claude-fable-5-1 || rc=$?
assert_eq 1 "$rc" "both windows past the reserve hold Fable"
assert_eq "Weekly (Fable)" "$QUOTA_GATE_WINDOW" "Fable hold names the more-used window"
rc=0; quota_gate_reading "$both_hot" 30 hold claude-opus-5-5 || rc=$?
assert_eq 1 "$rc" "both windows past the reserve still hold Opus on the family window"
assert_eq "Weekly" "$QUOTA_GATE_WINDOW" "Opus never reports the Fable window"
printf 'PASS acceptance 3: family windows bind every model\n'

# --- Acceptance 4: the tick's role gate resolves the seat's model from the
# stage identity, so the Opus verifier dispatches and the Fable verifier is
# held and pauses the repo to the Fable reset.
AUTOMETTA_QUOTA_TICK_JSON="$fable_hot"
rc=0; quota_gate_role_dispatch "$repo" "$repo/state/state.yaml" opus-stage verifier || rc=$?
assert_eq 0 "$rc" "tick admits the Opus verifier past a hot Fable window"
assert_eq null "$(jq -r '.paused_until' "$repo/state/budget.json")" "an admitted Opus verifier leaves the repo unpaused"
rc=0; quota_gate_role_dispatch "$repo" "$repo/state/state.yaml" fable-stage verifier || rc=$?
assert_eq 1 "$rc" "tick holds the Fable verifier on its own window"
assert_eq "$fable_reset_epoch" "$(jq -r '.paused_until' "$repo/state/budget.json")" "Fable hold pauses to the Fable reset"
reset_budget
printf 'PASS acceptance 4: the tick gates each seat on the windows it draws on\n'

# --- Acceptance 5: the manual spawn gate reads the worker's model from the
# card, and without a card stays conservative.
rc=0; quota_spawn_permits "$repo" claude "$opus_card" || rc=$?
assert_eq 0 "$rc" "manual spawn of an Opus worker passes a hot Fable window"
rc=0; quota_spawn_permits "$repo" claude "$fable_card" || rc=$?
assert_eq 1 "$rc" "manual spawn of a Fable worker is held"
rc=0; quota_spawn_permits "$repo" claude || rc=$?
assert_eq 1 "$rc" "manual spawn with no card is held as before"
assert_eq null "$(jq -r '.paused_until' "$repo/state/budget.json")" "the manual gate pauses nothing"
printf 'PASS acceptance 5: the manual spawn gate names the worker model\n'

# AUTOMETTA-CONTRACT-END

# --- Regression guard added on re-brief after attempt 1: a manual spawn of a
# Claude worker whose card names a Codex subscription verifier still checks
# the Codex window before admitting the card (CLAUDE.md, manual dispatch).
codex_spent="$(jq -c '.families.codex.windows[0].utilization = 100' <<<"$(reading 46 40)")"
mixed_card="$(card_for mixed-worker "Claude Opus 5.5 <claude-opus-5-5@local>" "Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>")"
rc=0; AUTOMETTA_QUOTA_TICK_JSON="$codex_spent" quota_spawn_permits "$repo" claude "$mixed_card" || rc=$?
assert_eq 1 "$rc" "a Claude worker with a Codex verifier is still held on an exhausted Codex window"
printf 'PASS regression: the Codex verifier check survives for a Claude worker\n'

printf 'model-window-smoke: PASS\n'
