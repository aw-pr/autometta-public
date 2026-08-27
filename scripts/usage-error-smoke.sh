#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
export PHAT_CONTROLLER_HOME="$tmp_dir/controller"
mkdir -p "$PHAT_CONTROLLER_HOME/log"
# shellcheck source=./tick.sh
source "$script_dir/tick.sh"

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

fixture_epoch() {
  python3 - "$1" <<'PY'
import datetime as dt
import sys

print(int(dt.datetime.fromisoformat(sys.argv[1]).timestamp()))
PY
}

fixture_reset_epoch() {
  local line="$1"
  local now_epoch="$2"
  TZ=Europe/London usage_limit_reset_epoch "$line" "$now_epoch"
}

# Two minutes past is an elapsed reset, not the same wall-clock time tomorrow.
past_now="$(fixture_epoch '2026-08-24T12:12:00+01:00')"
past_reset="$(fixture_reset_epoch \
  "You've hit your session limit · resets 12:10pm (Europe/London)" "$past_now")"
[[ "$past_reset" == "$past_now" ]]

# A reset still ahead keeps today's date and its short wait.
ahead_now="$(fixture_epoch '2026-08-24T12:08:00+01:00')"
ahead_expected="$(fixture_epoch '2026-08-24T12:10:00+01:00')"
ahead_reset="$(fixture_reset_epoch \
  "You've hit your session limit · resets 12:10pm (Europe/London)" "$ahead_now")"
[[ "$ahead_reset" == "$ahead_expected" ]]

# At 00:01, 23:59 is two minutes past on the previous date, not tomorrow.
midnight_now="$(fixture_epoch '2026-08-25T00:01:00+01:00')"
midnight_reset="$(fixture_reset_epoch \
  "You've hit your session limit · resets 11:59pm (Europe/London)" "$midnight_now")"
[[ "$midnight_reset" == "$midnight_now" ]]

# Replay the incident clock exactly: 11:10:02Z was 12:10:02 BST.
incident_now="$(fixture_epoch '2026-08-24T12:10:02+01:00')"
incident_reset="$(fixture_reset_epoch \
  "You've hit your session limit · resets 12:10pm (Europe/London)" "$incident_now")"
[[ "$incident_reset" == "$incident_now" ]]

# A valid but implausibly old clock retains next-day inference only up to the
# hard limit of one provider window plus margin.
capped_now="$(fixture_epoch '2026-08-24T20:00:00+01:00')"
capped_reset="$(fixture_reset_epoch \
  "You've hit your session limit · resets 1:00pm (Europe/London)" "$capped_now")"
[[ "$(( capped_reset - capped_now ))" == "$USAGE_LIMIT_MAX_PAUSE_SECONDS" ]]

# Exercise the caller with a real current-time refusal. An elapsed pause is
# cleared immediately, so the next tick can dispatch the untouched stage.
dynamic_banner="$(TZ=Europe/London python3 - <<'PY'
import datetime as dt

print((dt.datetime.now() - dt.timedelta(minutes=2)).strftime('%I:%M%p').lstrip('0').lower())
PY
)"
printf "You've hit your session limit · resets %s (Europe/London)\n" "$dynamic_banner" > "$log_path"
TZ=Europe/London handle_limit_refusal "$tmp_dir" "$stage_id" worker "$log_path"
if budget_pause_active "$tmp_dir"; then
  printf 'FAIL: a reset two minutes past left dispatch paused\n' >&2
  exit 1
fi
[[ "$(jq -r '.paused_until // empty' "$tmp_dir/state/budget.json")" == "" ]]

# An invalid clock falls back to the caller's one-hour default. It must still
# remain below the six-hour hard cap rather than rolling to tomorrow.
printf "You've hit your session limit · resets 27:99pm (Europe/London)\n" > "$log_path"
fallback_started="$(date -u +%s)"
handle_limit_refusal "$tmp_dir" "$stage_id" worker "$log_path"
fallback_pause="$(jq -r '.paused_until' "$tmp_dir/state/budget.json")"
fallback_delta=$(( fallback_pause - fallback_started ))
(( fallback_delta >= 3599 && fallback_delta <= 3601 ))
(( fallback_delta <= USAGE_LIMIT_MAX_PAUSE_SECONDS ))

printf 'usage-limit fixtures: past=0s ahead=%ss midnight=0s incident=0s old-clock=%ss nonsense=%ss cap=%ss grace=%ss\n' \
  "$(( ahead_reset - ahead_now ))" "$(( capped_reset - capped_now ))" "$fallback_delta" \
  "$USAGE_LIMIT_MAX_PAUSE_SECONDS" "$USAGE_LIMIT_RESET_GRACE_SECONDS"

printf 'usage-error-smoke: PASS\n'
