#!/usr/bin/env bash
# cap-resolution-smoke.sh — offline check that the token cap is resolved from
# the host down, never fails open, and that a drain expires by itself.
#
# The defect this guards (card 47): token_cap_total was written per repo by
# subscribe-repo.sh and never revisited, so five subscribers carried
# 3,000,000 / 8,000,000 / 100,000,000 / 150,000,000 between them with nothing
# recording why any of them held its number. On 2026-08-23 emergence-lab spent
# 104,942,068 against a 100,000,000 cap during a deliberate weekly-token
# drain: the gate refused a verifier dispatch at 00:01 with a finished worker
# sitting on a passing envelope, and the run resumed only when the midnight
# window reset zeroed the counter an hour later. The cap was doing its job;
# the number simply did not describe the intent.
#
# Everything below runs against temporary budget files and a temporary
# controller home. No auth, no network, no live agent, no spend. It asserts:
#
#   1. A repo with no cap of its own inherits the host default.
#   2. A repo carrying its own cap keeps it.
#   3. A repo with neither is capped at the floor, not unlimited.
#   4. A drain raises the cap for one run and reports itself as the source.
#   5. An expired drain stops binding and the resting cap comes back.
#   6. With no drain and spend above the cap, the gate still refuses.
#
# Exit 0 on all-pass, 1 on any assertion failure.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./budget.sh
source "$script_dir/budget.sh"

fail=0

check() {
  local desc="$1"
  local cond="$2"
  if [[ "$cond" == "ok" ]]; then
    printf '  PASS: %s\n' "$desc" >&2
  else
    printf '  FAIL: %s (%s)\n' "$desc" "$cond" >&2
    fail=1
  fi
}

eq() { [[ "$1" == "$2" ]] && printf 'ok\n' || printf 'expected %q, got %q\n' "$1" "$2"; }

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

export PHAT_CONTROLLER_HOME="$tmp_root/controller"
mkdir -p "$PHAT_CONTROLLER_HOME"

# make_repo <name> <token_cap_total|none> <tokens_spent>
make_repo() {
  local name="$1" cap="$2" spent="$3"
  local dir="$tmp_root/$name"
  mkdir -p "$dir/state"
  local cap_line=""
  [[ "$cap" != "none" ]] && cap_line="  \"token_cap_total\": $cap,"
  cat > "$dir/state/budget.json" <<JSON
{
  "version": 1,
$cap_line
  "tokens_spent": $spent,
  "wall_clock_cap_seconds": 3600,
  "wall_clock_elapsed_seconds": 0,
  "clock_tick_cap": 100,
  "clock_ticks_used": 0,
  "consecutive_failure_cap": 3,
  "consecutive_failures": 0,
  "halted": false,
  "halt_reason": null,
  "halted_at": null
}
JSON
  printf '%s' "$dir"
}

printf '1. host default inherited by a repo with no cap of its own\n' >&2
printf 'version: 1\ntoken_cap_total: 40000000\n' > "$PHAT_CONTROLLER_HOME/config.yaml"
inherit_repo="$(make_repo inherit none 0)"
check "effective cap is the host default" \
  "$(eq 40000000 "$(budget_effective_token_cap "$inherit_repo")")"
check "cap source reads host-default" \
  "$(eq host-default "$(budget_cap_source "$inherit_repo")")"

printf '2. an explicit per-repo cap wins over the host default\n' >&2
own_repo="$(make_repo own 8000000 0)"
check "effective cap is the repo's own" \
  "$(eq 8000000 "$(budget_effective_token_cap "$own_repo")")"
check "cap source reads repo" \
  "$(eq repo "$(budget_cap_source "$own_repo")")"

printf '3. neither cap present is capped at the floor, not unlimited\n' >&2
mv "$PHAT_CONTROLLER_HOME/config.yaml" "$PHAT_CONTROLLER_HOME/config.yaml.parked"
floor_repo="$(make_repo floor none "$(( AUTOMETTA_TOKEN_CAP_FLOOR + 1 ))")"
check "effective cap is the floor" \
  "$(eq "$AUTOMETTA_TOKEN_CAP_FLOOR" "$(budget_effective_token_cap "$floor_repo")")"
check "cap source reads floor" "$(eq floor "$(budget_cap_source "$floor_repo")")"
gate_rc=0
budget_gate_dispatch "$floor_repo" worker 2>/dev/null || gate_rc=$?
check "gate refuses a repo over the floor" "$(eq 1 "$gate_rc")"
check "halted on token-cap, not left unlimited" \
  "$(eq token-cap "$(jq -r '.halt_reason' "$floor_repo/state/budget.json")")"
mv "$PHAT_CONTROLLER_HOME/config.yaml.parked" "$PHAT_CONTROLLER_HOME/config.yaml"

printf '4. a drain raises the cap for one run\n' >&2
drain_repo="$(make_repo drained 100000000 104942068)"
gate_rc=0
budget_gate_dispatch "$drain_repo" verifier 2>/dev/null || gate_rc=$?
check "before the drain, 104,942,068 against 100,000,000 is refused" "$(eq 1 "$gate_rc")"
"$script_dir/drain.sh" start --cap 400000000 --hours 8 --reason "smoke" >/dev/null
# A drain raises the cap; it does not unlatch a halt that was correctly
# taken. Recovering the repo stays the operator's explicit decision.
gate_rc=0
budget_gate_dispatch "$drain_repo" verifier 2>/dev/null || gate_rc=$?
check "a latched halt survives the drain" "$(eq 1 "$gate_rc")"
check "and keeps its original reason" \
  "$(eq token-cap "$(jq -r '.halt_reason' "$drain_repo/state/budget.json")")"
jq '.halted = false | .halt_reason = null | .halt_reasons = null | .halted_at = null' \
  "$drain_repo/state/budget.json" > "$drain_repo/state/budget.json.tmp"
mv "$drain_repo/state/budget.json.tmp" "$drain_repo/state/budget.json"
check "effective cap is the drain's" \
  "$(eq 400000000 "$(budget_effective_token_cap "$drain_repo")")"
check "cap source reads drain" "$(eq drain "$(budget_cap_source "$drain_repo")")"
gate_rc=0
budget_gate_dispatch "$drain_repo" verifier 2>/dev/null || gate_rc=$?
check "the same dispatch is allowed under the drain" "$(eq 0 "$gate_rc")"
check "the repo's own budget.json was not edited to do it" \
  "$(eq 100000000 "$(jq -r '.token_cap_total' "$drain_repo/state/budget.json")")"

printf '5. the drain expires by itself\n' >&2
drain_file="$(budget_drain_file)"
jq --argjson past "$(( $(date -u +%s) - 60 ))" '.expires_at = $past' "$drain_file" \
  > "$drain_file.tmp"
mv "$drain_file.tmp" "$drain_file"
check "effective cap is back to the resting one" \
  "$(eq 100000000 "$(budget_effective_token_cap "$drain_repo")")"
check "the drain file was retired, not left in place" \
  "$([[ ! -f "$drain_file" && -f "${drain_file%.json}.expired.json" ]] && printf 'ok\n' || printf 'drain.json still present\n')"
gate_rc=0
budget_gate_dispatch "$drain_repo" verifier 2>/dev/null || gate_rc=$?
check "the dispatch is refused again once the drain has gone" "$(eq 1 "$gate_rc")"

printf '6. with no drain, an over-cap repo is still refused\n' >&2
over_repo="$(make_repo over 8000000 8000001)"
gate_rc=0
budget_gate_dispatch "$over_repo" worker 2>/dev/null || gate_rc=$?
check "gate refuses" "$(eq 1 "$gate_rc")"
check "breach recorded against the cap that bound" \
  "$(eq 8000000 "$(jq -r '.breaches[-1].token_cap_total' "$over_repo/state/budget.json")")"

if [[ "$fail" -eq 0 ]]; then
  printf 'PASS cap-resolution-smoke\n' >&2
else
  printf 'FAIL cap-resolution-smoke\n' >&2
fi
exit "$fail"
