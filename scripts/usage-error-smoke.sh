#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./tick.sh
source "$script_dir/tick.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/state/logs" "$tmp_dir/state/verifiers"

stage_id="35-usage-error-should-not-burn-a-retry"
log_path="$tmp_dir/state/logs/${stage_id}-verifier.log"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf "error: unknown option '--effort high'\n" > "$log_path"

cat > "$tmp_dir/state/state.yaml" <<EOF
{
  "version": 1,
  "current_stage": "$stage_id",
  "stages": [{
    "id": "$stage_id",
    "status": "in_progress",
    "worker": "test worker",
    "verifier": "test verifier",
    "verifier_pid": 999999,
    "verifier_attempts": 1,
    "verifier_started_at": "$started_at"
  }],
  "last_tick_at": "$started_at",
  "tick_count": 0,
  "clock_tick_budget_remaining": 10
}
EOF

cat > "$tmp_dir/state/budget.json" <<EOF
{
  "token_cap_total": 1000,
  "tokens_spent": 0,
  "lifetime_tokens_spent": 0,
  "wall_clock_cap_seconds": 1000,
  "wall_clock_elapsed_seconds": 0,
  "clock_tick_cap": 100,
  "clock_ticks_used": 0,
  "consecutive_failure_cap": 3,
  "consecutive_failures": 0,
  "halted": false,
  "halt_reason": null,
  "halted_at": null,
  "breaches": []
}
EOF

if ! is_instant_dispatch_configuration_fault \
  "$log_path" "$started_at" "$tmp_dir/state/verifiers/${stage_id}.json"; then
  printf 'FAIL: real 38-byte usage-error log was not classified as a configuration fault\n' >&2
  exit 1
fi

halt_dispatch_configuration_fault "$tmp_dir" "$stage_id" verifier

[[ "$(yq -r '.stages[0].verifier_attempts' "$tmp_dir/state/state.yaml")" == "0" ]]
[[ "$(yq -r '.stages[0].status' "$tmp_dir/state/state.yaml")" == "stalled" ]]
[[ "$(yq -r '.stages[0].stall_marker' "$tmp_dir/state/state.yaml")" == "dispatch_configuration_fault:verifier" ]]
[[ "$(yq -r '.current_stage' "$tmp_dir/state/state.yaml")" == "null" ]]
[[ "$(jq -r '.halted' "$tmp_dir/state/budget.json")" == "true" ]]
[[ "$(jq -r '.halt_reason' "$tmp_dir/state/budget.json")" == "dispatch-configuration-fault" ]]

printf 'verifier completed normally but reported FAIL\n' > "$log_path"
if is_instant_dispatch_configuration_fault \
  "$log_path" "$started_at" "$tmp_dir/state/verifiers/${stage_id}.json"; then
  printf 'FAIL: genuine verifier failure was classified as a configuration fault\n' >&2
  exit 1
fi

# A genuine failure keeps the attempt reserved at dispatch time. The existing
# retry path therefore advances towards, and remains bounded by, the cap of 3.
yq -i '.stages[0].verifier_attempts = 1' "$tmp_dir/state/state.yaml"
[[ "$(yq -r '.stages[0].verifier_attempts' "$tmp_dir/state/state.yaml")" == "1" ]]
grep -q 'verifier_attempt_cap=3' "$script_dir/tick.sh"

# Workers have no retry counter, but the same dispatch fault must halt with a
# role-specific marker instead of being reported as a generic missing envelope.
STAGE_ID="$stage_id" yq -i \
  '.current_stage = strenv(STAGE_ID) | .stages[0].status = "in_progress" | .stages[0].worker_pid = 999999' \
  "$tmp_dir/state/state.yaml"
halt_dispatch_configuration_fault "$tmp_dir" "$stage_id" worker
[[ "$(yq -r '.stages[0].stall_marker' "$tmp_dir/state/state.yaml")" == "dispatch_configuration_fault:worker" ]]
[[ "$(yq -r '.stages[0].verifier_attempts' "$tmp_dir/state/state.yaml")" == "1" ]]

printf 'usage-error-smoke: PASS\n'
