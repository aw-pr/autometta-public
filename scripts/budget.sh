#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

json_check() {
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1"
}

budget_file() {
  printf '%s/state/budget.json\n' "$1"
}

budget_read() {
  local repo_root="$1"
  local budget_path
  budget_path="$(budget_file "$repo_root")"
  jq '.' "$budget_path"
}

budget_write_atomic() {
  local repo_root="$1"
  local jq_filter="$2"
  local budget_path tmp_path
  budget_path="$(budget_file "$repo_root")"
  tmp_path="${budget_path}.tmp.$$"
  jq "$jq_filter" "$budget_path" > "$tmp_path"
  json_check "$tmp_path"
  mv "$tmp_path" "$budget_path"
}

# budget_check_caps: inspect the per-repo budget.json and decide whether
# the tick loop should proceed.
#
# Return codes:
#   0 — no halt condition; caller may proceed.
#   1 — a real cap was hit on this read. The specific cap name is written
#       to the global BUDGET_CHECK_LAST_HIT (one of: token-cap,
#       wall-clock-cap, tick-cap, failure-cap). The caller is expected to
#       pass that value to budget_halt as the halt_reason.
#   2 — the repo was already halted before this call. halt_reason is
#       preserved verbatim in budget.json; the caller MUST NOT call
#       budget_halt again or it will overwrite the original reason.
#
# BUDGET_CHECK_LAST_HIT is only meaningful when the function returned 1.
BUDGET_CHECK_LAST_HIT=""

budget_check_caps() {
  local repo_root="$1"
  local budget_path
  budget_path="$(budget_file "$repo_root")"

  BUDGET_CHECK_LAST_HIT=""

  local halted token_hit wall_hit tick_hit fail_hit
  halted="$(jq -r '.halted // false' "$budget_path")"

  if [[ "$halted" == "true" ]]; then
    return 2
  fi

  token_hit="$(jq -r '.tokens_spent >= .token_cap_total' "$budget_path")"
  wall_hit="$(jq -r '.wall_clock_elapsed_seconds >= .wall_clock_cap_seconds' "$budget_path")"
  tick_hit="$(jq -r '.clock_ticks_used >= .clock_tick_cap' "$budget_path")"
  fail_hit="$(jq -r '.consecutive_failures >= .consecutive_failure_cap' "$budget_path")"

  if [[ "$token_hit" == "true" ]]; then
    BUDGET_CHECK_LAST_HIT="token-cap"
    return 1
  fi
  if [[ "$wall_hit" == "true" ]]; then
    BUDGET_CHECK_LAST_HIT="wall-clock-cap"
    return 1
  fi
  if [[ "$tick_hit" == "true" ]]; then
    BUDGET_CHECK_LAST_HIT="tick-cap"
    return 1
  fi
  if [[ "$fail_hit" == "true" ]]; then
    BUDGET_CHECK_LAST_HIT="failure-cap"
    return 1
  fi

  return 0
}

budget_increment_tick() {
  local repo_root="$1"
  budget_write_atomic "$repo_root" '.clock_ticks_used += 1'
}

budget_record_failure() {
  local repo_root="$1"
  budget_write_atomic "$repo_root" '.consecutive_failures += 1'
}

budget_reset_failures() {
  local repo_root="$1"
  budget_write_atomic "$repo_root" '.consecutive_failures = 0'
}

budget_halt() {
  local repo_root="$1"
  local reason="$2"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  budget_write_atomic "$repo_root" ".halted = true | .halt_reason = \"${reason}\" | .halted_at = \"${ts}\""
}
