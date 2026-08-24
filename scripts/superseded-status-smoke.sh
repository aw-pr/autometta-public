#!/usr/bin/env bash
# superseded-status-smoke.sh: offline proof of the superseded stage status
# (stage card 43). No auth, no network, no token spend.
#
# What it asserts, in the order card 43 asks for it:
#
#   1. A ledger carrying a superseded stage validates against
#      schemas/state.yaml.json, and a pre-change ledger still validates.
#   2. A tick with a superseded stage ahead of a pending one dispatches the
#      pending stage and leaves the superseded one exactly as it found it.
#   3. budget_record_failure does not count a superseded stage, so it cannot
#      walk a repo toward a failure-cap halt.
#   4. requeue-stage.sh refuses a superseded stage non-zero without --force
#      and proceeds with it.
#   5. The pre-change ledger ticks to the same decision it did before.
#   6. superseded raises no alert in the fleet pane or the per-repo ticker,
#      while a genuinely failed stage in the same ledger still does.
#   7. The alert-worthy set has one definition: adding superseded to
#      scripts/alert-statuses.sh alone makes every renderer alert on it.
#
# Exit 0 on all-pass, 1 on any assertion failure.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root_real="$(cd "$script_dir/.." && pwd)"

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT
export PHAT_CONTROLLER_HOME="$tmp_root/controller"
mkdir -p "$PHAT_CONTROLLER_HOME/subscribers" "$PHAT_CONTROLLER_HOME/log"

fail=0
check() {
  local desc="$1" cond="$2"
  if [[ "$cond" == "ok" ]]; then
    printf '  PASS: %s\n' "$desc" >&2
  else
    printf '  FAIL: %s (%s)\n' "$desc" "$cond" >&2
    fail=1
  fi
}
eq() { [[ "$1" == "$2" ]] && printf 'ok\n' || printf 'expected %q, got %q\n' "$1" "$2"; }

# Stubs: tmux (the tick's viewer is a real side effect on the operator's
# terminal), and op-fetch (the auth wrapper every dispatch goes through).
# The stub op-fetch exits immediately without running the child, so a
# "dispatch" spends nothing and touches no provider.
mkdir -p "$tmp_root/stub"
printf '#!/bin/sh\nexit 0\n' > "$tmp_root/stub/tmux"
printf '#!/bin/sh\nexit 0\n' > "$tmp_root/stub/op-fetch"
chmod +x "$tmp_root/stub/tmux" "$tmp_root/stub/op-fetch"

# ---------------------------------------------------------------------------
printf '== 1. the schema accepts superseded, and still accepts what came before ==\n' >&2

validate_state() {
  python3 - "$repo_root_real/schemas/state.yaml.json" "$1" <<'PY'
import json, sys, yaml
from jsonschema import Draft202012Validator
schema = json.load(open(sys.argv[1]))
doc = yaml.safe_load(open(sys.argv[2]))
errors = sorted(Draft202012Validator(schema).iter_errors(doc), key=lambda e: e.path)
print("ok" if not errors else "; ".join(e.message for e in errors[:2]))
PY
}

cat > "$tmp_root/with-superseded.yaml" <<'YAML'
version: 1
current_stage: null
last_tick_at: "2026-08-24T00:00:00Z"
tick_count: 12
clock_tick_budget_remaining: 388
stages:
  - id: 14-retired-by-later-work
    status: superseded
    worker: "Worker <worker@local>"
    verifier: "Verifier <verifier@local>"
  - id: 15-still-queued
    status: pending
    worker: "Worker <worker@local>"
    verifier: "Verifier <verifier@local>"
YAML

cat > "$tmp_root/pre-change.yaml" <<'YAML'
version: 1
current_stage: null
last_tick_at: "2026-08-24T00:00:00Z"
tick_count: 12
clock_tick_budget_remaining: 388
stages:
  - id: 14-retired-by-later-work
    status: verifier_failed
    worker: "Worker <worker@local>"
    verifier: "Verifier <verifier@local>"
  - id: 15-still-queued
    status: pending
    worker: "Worker <worker@local>"
    verifier: "Verifier <verifier@local>"
YAML

check "a ledger carrying a superseded stage validates" \
  "$(validate_state "$tmp_root/with-superseded.yaml")"
check "a pre-change ledger validates unchanged (no migration step)" \
  "$(validate_state "$tmp_root/pre-change.yaml")"
check "an invented status is still rejected" \
  "$(sed 's/status: superseded/status: retired/' "$tmp_root/with-superseded.yaml" \
      > "$tmp_root/bad.yaml"; \
     [[ "$(validate_state "$tmp_root/bad.yaml")" == ok ]] \
       && printf 'schema accepted retired\n' || printf 'ok\n')"

# ---------------------------------------------------------------------------
printf '== 2. a tick steps over the superseded stage and dispatches the pending one ==\n' >&2

# A subscriber-shaped repo: dev checked out, state/ gitignored as every real
# subscriber has it, two cards on disk so dispatch can resolve a prompt.
make_repo() {
  local name="$1" ledger="$2"
  local dir="$tmp_root/$name"
  mkdir -p "$dir/state/handoffs" "$dir/state/verifiers" "$dir/state/logs" "$dir/docs/stages"
  for stage in 14-retired-by-later-work 15-still-queued; do
    cat > "$dir/docs/stages/$stage.md" <<CARD
# Stage card: $stage

## Metadata

- **Worker:** Claude Opus 5 <claude-opus-5@local>
- **Verifier:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>

## Budget

- **Worker wall-clock:** 30 minutes
CARD
  done
  (
    cd "$dir"
    git init -q -b dev .
    git config user.email smoke@local
    git config user.name smoke
    git config commit.gpgsign false
    printf 'state/**\n' > .gitignore
    printf 'seed\n' > README.md
    git add -A
    git commit -qm seed
  )
  cp "$ledger" "$dir/state/state.yaml"
  cat > "$dir/state/budget.json" <<JSON
{
  "version": 1,
  "token_cap_total": 1000000,
  "tokens_spent": 0,
  "wall_clock_cap_seconds": 86400,
  "wall_clock_elapsed_seconds": 0,
  "clock_tick_cap": 400,
  "clock_ticks_used": 1,
  "consecutive_failure_cap": 3,
  "consecutive_failures": 0,
  "halted": false,
  "window_started_at": "$(date -u +%F)"
}
JSON
  cat > "$PHAT_CONTROLLER_HOME/subscribers/$name.yaml" <<YAML
repo_path: "$dir"
weight: 100
enabled: true
YAML
  printf '%s' "$dir"
}

run_tick() {
  PATH="$tmp_root/stub:$PATH" "$script_dir/tick.sh" >/dev/null 2>&1 || true
}

ticked="$(make_repo ticked "$tmp_root/with-superseded.yaml")"
run_tick
printf '  ledger after the tick (current_stage: %s):\n' \
  "$(yq -o=json '.' "$ticked/state/state.yaml" | jq -r '.current_stage')" >&2
yq -o=json '.' "$ticked/state/state.yaml" |
  jq -r '.stages[] | "    " + .id + " " + .status' >&2

check "the pending stage was the one chosen" \
  "$(eq 15-still-queued "$(yq -r '.current_stage' "$ticked/state/state.yaml")")"
check "and it is in flight" \
  "$(eq in_progress "$(yq -r '.stages[] | select(.id == "15-still-queued") | .status' "$ticked/state/state.yaml")")"
check "the superseded stage is still superseded" \
  "$(eq superseded "$(yq -r '.stages[] | select(.id == "14-retired-by-later-work") | .status' "$ticked/state/state.yaml")")"
check "the superseded stage was never started" \
  "$(eq null "$(yq -r '.stages[] | select(.id == "14-retired-by-later-work") | .started_at // "null"' "$ticked/state/state.yaml")")"
check "no stall marker was written against it" \
  "$(eq null "$(yq -r '.stages[] | select(.id == "14-retired-by-later-work") | .stall_marker // "null"' "$ticked/state/state.yaml")")"
check "the tick counted no failure" \
  "$(eq 0 "$(jq -r '.consecutive_failures' "$ticked/state/budget.json")")"
rm -f "$PHAT_CONTROLLER_HOME/subscribers/ticked.yaml"

# Criterion 5: the same ledger with the pre-change status in that slot ticks
# to the same decision, so nothing about the old shape moved.
control="$(make_repo control "$tmp_root/pre-change.yaml")"
run_tick
check "a pre-change ledger dispatches the same stage it always did" \
  "$(eq 15-still-queued "$(yq -r '.current_stage' "$control/state/state.yaml")")"
check "and its verifier_failed stage is untouched too" \
  "$(eq verifier_failed "$(yq -r '.stages[] | select(.id == "14-retired-by-later-work") | .status' "$control/state/state.yaml")")"
rm -f "$PHAT_CONTROLLER_HOME/subscribers/control.yaml"

# A superseded stage that is somehow the current stage is released, not reaped.
stuck="$(make_repo stuck "$tmp_root/with-superseded.yaml")"
yq -i '.current_stage = "14-retired-by-later-work"
  | (.stages[] | select(.id == "14-retired-by-later-work")).started_at = "2020-01-01T00:00:00Z"' \
  "$stuck/state/state.yaml"
run_tick
check "a superseded current_stage is released rather than stalled" \
  "$(eq superseded "$(yq -r '.stages[] | select(.id == "14-retired-by-later-work") | .status' "$stuck/state/state.yaml")")"
check "and current_stage is cleared" \
  "$(eq null "$(yq -r '.current_stage' "$stuck/state/state.yaml")")"
check "releasing it counted no failure" \
  "$(eq 0 "$(jq -r '.consecutive_failures' "$stuck/state/budget.json")")"
rm -f "$PHAT_CONTROLLER_HOME/subscribers/stuck.yaml"

# ---------------------------------------------------------------------------
printf '== 3. the budget does not count a retirement as a failure ==\n' >&2

# shellcheck source=./budget.sh
source "$script_dir/budget.sh"
IFS=$' \t\n'

budget_repo="$tmp_root/budget-repo"
mkdir -p "$budget_repo/state"
cat > "$budget_repo/state/budget.json" <<JSON
{
  "version": 1,
  "token_cap_total": 1000000,
  "tokens_spent": 0,
  "wall_clock_cap_seconds": 86400,
  "wall_clock_elapsed_seconds": 0,
  "clock_tick_cap": 400,
  "clock_ticks_used": 1,
  "consecutive_failure_cap": 3,
  "consecutive_failures": 0,
  "halted": false,
  "window_started_at": "$(date -u +%F)"
}
JSON

cf() { jq -r '.consecutive_failures' "$budget_repo/state/budget.json"; }
budget_record_failure "$budget_repo" superseded
check "recording a superseded stage does not increment consecutive_failures" \
  "$(eq 0 "$(cf)")"
budget_record_failure "$budget_repo" superseded
budget_record_failure "$budget_repo" superseded
budget_record_failure "$budget_repo" superseded
check "three retirements in a row still cannot reach the failure cap of 3" \
  "$(eq 0 "$(cf)")"
budget_record_failure "$budget_repo" stalled
check "a genuine casualty still counts" "$(eq 1 "$(cf)")"
budget_record_failure "$budget_repo"
check "and a caller that names no status still counts, as before" \
  "$(eq 2 "$(cf)")"
IFS=$'\n\t'

# ---------------------------------------------------------------------------
printf '== 4. re-queueing a retirement takes an explicit --force ==\n' >&2

rq="$(make_repo requeue "$tmp_root/with-superseded.yaml")"
rm -f "$PHAT_CONTROLLER_HOME/subscribers/requeue.yaml"
set +e
rq_out="$("$script_dir/requeue-stage.sh" "$rq" 14-retired-by-later-work 2>&1)"
rq_rc=$?
set -e
printf '  %s\n' "$rq_out" >&2
check "requeue without --force exits non-zero" \
  "$([[ $rq_rc -ne 0 ]] && printf 'ok\n' || printf 'exited 0\n')"
check "and names the status in its refusal" \
  "$([[ "$rq_out" == *superseded* ]] && printf 'ok\n' || printf 'status not named\n')"
check "the stage is left superseded" \
  "$(eq superseded "$(yq -r '.stages[] | select(.id == "14-retired-by-later-work") | .status' "$rq/state/state.yaml")")"

set +e
"$script_dir/requeue-stage.sh" --force "$rq" 14-retired-by-later-work >/dev/null 2>&1
rq_forced_rc=$?
set -e
check "requeue --force exits 0" "$(eq 0 "$rq_forced_rc")"
check "and puts the stage back to pending" \
  "$(eq pending "$(yq -r '.stages[] | select(.id == "14-retired-by-later-work") | .status' "$rq/state/state.yaml")")"

# A stage that was never superseded is unaffected by the new gate.
set +e
"$script_dir/requeue-stage.sh" "$rq" 15-still-queued >/dev/null 2>&1
rq_plain_rc=$?
set -e
check "an ordinary stage still re-queues without --force" "$(eq 0 "$rq_plain_rc")"

# ---------------------------------------------------------------------------
printf '== 5. no renderer alerts on a retirement, and every one still alerts on a failure ==\n' >&2

alert_repo="$tmp_root/alerts-fixture"
mkdir -p "$alert_repo/state/logs" "$alert_repo/state/handoffs" "$alert_repo/state/verifiers"
cat > "$alert_repo/state/state.yaml" <<'YAML'
current_stage: null
stages:
  - id: 14-retired-by-later-work
    status: superseded
    worker: "Worker <worker@local>"
    verifier: "Verifier <verifier@local>"
  - id: 16-genuinely-broken
    status: failed
    worker: "Worker <worker@local>"
    verifier: "Verifier <verifier@local>"
  - id: 17-still-queued
    status: pending
    worker: "Worker <worker@local>"
    verifier: "Verifier <verifier@local>"
YAML
cat > "$alert_repo/state/budget.json" <<'JSON'
{
  "tokens_spent": 0,
  "token_cap_total": 1000000,
  "halted": false,
  "halt_reason": null,
  "consecutive_failures": 0,
  "consecutive_failure_cap": 3
}
JSON
cat > "$PHAT_CONTROLLER_HOME/subscribers/alerts-fixture.yaml" <<YAML
enabled: true
repo_path: "$alert_repo"
manifest_path: ""
YAML

render_fleet() {
  "$script_dir/aggregate-dashboard.sh" >/dev/null 2>&1
  PHAT_CONTROLLER_FLEET_ONCE=true "$script_dir/attach.sh" --fleet-ticker 2>/dev/null |
    sed -n '/^ALERTS/,$p'
}
render_ticker() {
  "$script_dir/agent-ticker.sh" "$alert_repo" --once 2>/dev/null |
    sed -n '/^ALERTS/,/^$/p'
}

fleet="$(render_fleet)"
ticker="$(render_ticker)"
printf '  fleet alerts:\n%s\n' "$(printf '%s\n' "$fleet" | sed 's/^/    /')" >&2
printf '  ticker alerts:\n%s\n' "$(printf '%s\n' "$ticker" | sed 's/^/    /')" >&2

check "the fleet pane alerts on the genuinely failed stage" \
  "$([[ "$fleet" == *16-genuinely-broken* ]] && printf 'ok\n' || printf 'failed stage silent\n')"
check "the fleet pane says nothing about the superseded one" \
  "$([[ "$fleet" != *14-retired-by-later-work* ]] && printf 'ok\n' || printf 'superseded stage alerted\n')"
check "the per-repo ticker alerts on the genuinely failed stage" \
  "$([[ "$ticker" == *16-genuinely-broken* ]] && printf 'ok\n' || printf 'failed stage silent\n')"
check "the per-repo ticker says nothing about the superseded one" \
  "$([[ "$ticker" != *14-retired-by-later-work* ]] && printf 'ok\n' || printf 'superseded stage alerted\n')"

# ---------------------------------------------------------------------------
printf '== 6. the alert-worthy set has exactly one definition ==\n' >&2

# Every file in scripts/ bar this one and the definition itself: does any of
# them still carry its own enumeration of the alert-worthy statuses?
literal_copies="$(grep -rln 'verifier_failed"[,)]\|"verifier_failed" or' \
  "$repo_root_real/scripts" 2>/dev/null |
  grep -v -e 'superseded-status-smoke.sh' -e 'alert-statuses.sh' -e '\-smoke.sh$' || true)"
printf '  files still enumerating the set: %s\n' "${literal_copies:-none}" >&2
check "no renderer spells the list out for itself any more" \
  "$(eq "" "$literal_copies")"

# Change it in the one place, and every renderer follows. The edit is made to
# a copy of the tree so the smoke test cannot leave the real definition moved.
patched="$tmp_root/patched-scripts"
cp -R "$repo_root_real/scripts" "$patched"
sed -i.bak 's/^AUTOMETTA_ALERT_STAGE_STATUSES=(failed verifier_failed stalled)$/AUTOMETTA_ALERT_STAGE_STATUSES=(failed verifier_failed stalled superseded)/' \
  "$patched/alert-statuses.sh"
rm -f "$patched/alert-statuses.sh.bak"
check "the one definition was actually edited in the copy" \
  "$([[ "$("$patched/alert-statuses.sh")" == *superseded* ]] && printf 'ok\n' || printf 'edit did not take\n')"

patched_fleet="$("$patched/aggregate-dashboard.sh" >/dev/null 2>&1; \
  PHAT_CONTROLLER_FLEET_ONCE=true "$patched/attach.sh" --fleet-ticker 2>/dev/null | sed -n '/^ALERTS/,$p')"
patched_ticker="$("$patched/agent-ticker.sh" "$alert_repo" --once 2>/dev/null | sed -n '/^ALERTS/,/^$/p')"

check "one edit makes the fleet pane alert on superseded" \
  "$([[ "$patched_fleet" == *14-retired-by-later-work* ]] && printf 'ok\n' || printf 'fleet pane did not follow\n')"
check "the same edit makes the per-repo ticker alert on it" \
  "$([[ "$patched_ticker" == *14-retired-by-later-work* ]] && printf 'ok\n' || printf 'ticker did not follow\n')"
check "the shipped definition is unchanged" \
  "$(eq '["failed","verifier_failed","stalled"]' "$("$script_dir/alert-statuses.sh")")"

# ---------------------------------------------------------------------------
printf '== 7. the operator procedure clears four alerts and leaves the rest standing ==\n' >&2

# An emergence-lab-shaped ledger: the four stages the operator retired on
# 2026-08-23, plus a genuine failure and a pending stage that must be
# untouched by the procedure. This is a fixture, not that repo: retiring a
# subscriber's real stages is the operator's decision, not this test's.
retire_repo="$tmp_root/emergence-lab-shaped"
mkdir -p "$retire_repo/state/logs" "$retire_repo/state/handoffs" "$retire_repo/state/verifiers"
cat > "$retire_repo/state/state.yaml" <<'YAML'
version: 1
current_stage: null
last_tick_at: "2026-08-23T19:35:00Z"
tick_count: 91
clock_tick_budget_remaining: 120
stages:
  - id: 05-math-formula-rendering
    status: verifier_failed
    worker: "Worker <worker@local>"
    verifier: "Verifier <verifier@local>"
  - id: 14-fractal-colour-cycle-pacing
    status: verifier_failed
    worker: "Worker <worker@local>"
    verifier: "Verifier <verifier@local>"
  - id: 15-boids-density-motion-tuning
    status: stalled
    worker: "Worker <worker@local>"
    verifier: "Verifier <verifier@local>"
  - id: 16-sandpile-larger-slower
    status: failed
    worker: "Worker <worker@local>"
    verifier: "Verifier <verifier@local>"
  - id: 21-genuine-failure
    status: failed
    worker: "Worker <worker@local>"
    verifier: "Verifier <verifier@local>"
  - id: 22-still-queued
    status: pending
    worker: "Worker <worker@local>"
    verifier: "Verifier <verifier@local>"
YAML
cat > "$retire_repo/state/budget.json" <<'JSON'
{
  "tokens_spent": 0,
  "token_cap_total": 1000000,
  "halted": false,
  "halt_reason": null,
  "consecutive_failures": 2,
  "consecutive_failure_cap": 3
}
JSON
printf '%s\n' "You've hit your session limit, resets 11:10pm (Europe/London)" \
  > "$retire_repo/state/logs/22-still-queued-worker.log"
rm -f "$PHAT_CONTROLLER_HOME/subscribers/alerts-fixture.yaml"
cat > "$PHAT_CONTROLLER_HOME/subscribers/emergence-lab-shaped.yaml" <<YAML
enabled: true
repo_path: "$retire_repo"
manifest_path: ""
YAML

alerts_now() {
  "$script_dir/aggregate-dashboard.sh" >/dev/null 2>&1
  PHAT_CONTROLLER_FLEET_ONCE=true "$script_dir/attach.sh" --fleet-ticker 2>/dev/null |
    sed -n '/^ALERTS/,$p'
  "$script_dir/agent-ticker.sh" "$retire_repo" --once 2>/dev/null |
    sed -n '/^ALERTS/,/^$/p'
}

before="$(alerts_now)"
for id in 05-math-formula-rendering 14-fractal-colour-cycle-pacing \
          15-boids-density-motion-tuning 16-sandpile-larger-slower; do
  check "before: $id alerts" \
    "$([[ "$before" == *"$id"* ]] && printf 'ok\n' || printf 'no alert to clear\n')"
done

# The procedure from docs/dispatch-contract.md, steps 3 and 4, run verbatim.
# Step 1 (write the reason on the card) and step 2 (stop anything running)
# have no ledger effect to assert here; step 5 is the confirmation below.
for id in 05-math-formula-rendering 14-fractal-colour-cycle-pacing \
          15-boids-density-motion-tuning 16-sandpile-larger-slower; do
  tmp="$(mktemp)"
  yq -o=json '.' "$retire_repo/state/state.yaml" | jq --arg id "$id" '
    .current_stage = (if .current_stage == $id then null else .current_stage end)
    | (.stages[] | select(.id == $id)).status = "superseded"' | yq -P '.' > "$tmp"
  mv "$tmp" "$retire_repo/state/state.yaml"
done
jq '.consecutive_failures = 0' "$retire_repo/state/budget.json" > "$retire_repo/state/budget.json.tmp"
mv "$retire_repo/state/budget.json.tmp" "$retire_repo/state/budget.json"

check "the retired ledger still validates against the schema" \
  "$(validate_state "$retire_repo/state/state.yaml")"

after="$(alerts_now)"
printf '  alerts after the procedure:\n%s\n' "$(printf '%s\n' "$after" | sed 's/^/    /')" >&2
for id in 05-math-formula-rendering 14-fractal-colour-cycle-pacing \
          15-boids-density-motion-tuning 16-sandpile-larger-slower; do
  check "after: $id raises no alert" \
    "$([[ "$after" != *"$id"* ]] && printf 'ok\n' || printf 'still alerting\n')"
done
check "the unrelated genuine failure still alerts" \
  "$([[ "$after" == *21-genuine-failure* ]] && printf 'ok\n' || printf 'silenced an alert it should not have\n')"
check "the provider limit alert still stands" \
  "$([[ "$after" == *"session limit"* ]] && printf 'ok\n' || printf 'provider alert lost\n')"
check "the pending stage is untouched" \
  "$(eq pending "$(yq -o=json '.' "$retire_repo/state/state.yaml" | jq -r '.stages[] | select(.id == "22-still-queued") | .status')")"

# ---------------------------------------------------------------------------
if (( fail == 0 )); then
  printf 'PASS superseded status: schema, tick, budget, requeue, alerts, one definition, retirement procedure\n'
else
  printf 'FAIL superseded status smoke\n' >&2
fi
exit "$fail"
