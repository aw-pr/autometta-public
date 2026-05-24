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

budget_check_caps() {
  local repo_root="$1"
  local budget_path
  budget_path="$(budget_file "$repo_root")"

  local halted token_hit wall_hit tick_hit fail_hit
  halted="$(jq -r '.halted // false' "$budget_path")"
  token_hit="$(jq -r '.tokens_spent >= .token_cap_total' "$budget_path")"
  wall_hit="$(jq -r '.wall_clock_elapsed_seconds >= .wall_clock_cap_seconds' "$budget_path")"
  tick_hit="$(jq -r '.clock_ticks_used >= .clock_tick_cap' "$budget_path")"
  fail_hit="$(jq -r '.consecutive_failures >= .consecutive_failure_cap' "$budget_path")"

  if [[ "$halted" == "true" || "$token_hit" == "true" || "$wall_hit" == "true" || "$tick_hit" == "true" || "$fail_hit" == "true" ]]; then
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
