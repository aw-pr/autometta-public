#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "$3" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "$3" ;; *) ;; esac; }

ago() {
  python3 - "$1" <<'PY'
import datetime as dt
import sys

stamp = dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=int(sys.argv[1]))
print(stamp.strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
}

controller_home="$fixture_root/controller"
fixture_repo="$fixture_root/fleet-fixture"
idle_repo="$fixture_root/idle-fixture"
mkdir -p "$controller_home/subscribers" "$fixture_repo/state/active-agents" \
  "$fixture_repo/state/logs" "$fixture_repo/state/handoffs" \
  "$fixture_repo/state/verifiers" "$idle_repo/state"

printf 'enabled: true\nrepo_path: "%s"\nmanifest_path: ""\n' "$fixture_repo" \
  > "$controller_home/subscribers/fleet-fixture.yaml"
printf 'enabled: true\nrepo_path: "%s"\nmanifest_path: ""\n' "$idle_repo" \
  > "$controller_home/subscribers/idle-fixture.yaml"

fresh="$(ago 480)"
old="$(ago 259200)"
started="$(ago 240)"
cat > "$fixture_repo/state/state.yaml" <<EOF
current_stage: long-running-stage-that-needs-truncation
stages:
  - id: long-running-stage-that-needs-truncation
    status: in_progress
    started_at: $started
  - id: queued-stage-with-a-deliberately-long-name-for-the-eighty-column-capture
    status: pending
  - id: fresh-failure
    status: failed
    completed_at: $fresh
  - id: old-failure
    status: verifier_failed
    completed_at: $old
  - id: stalled-stage
    status: stalled
    completed_at: $fresh
  - id: retired-stage
    status: superseded
    completed_at: $old
EOF
cat > "$idle_repo/state/state.yaml" <<'EOF'
current_stage: null
stages: []
EOF
cat > "$fixture_repo/state/budget.json" <<'EOF'
{"tokens_spent":12345678,"token_cap_total":100000000,"halted":false,"consecutive_failures":0,"consecutive_failure_cap":3}
EOF
cat > "$idle_repo/state/budget.json" <<'EOF'
{"tokens_spent":0,"token_cap_total":1000000,"halted":false,"consecutive_failures":0,"consecutive_failure_cap":3}
EOF
printf 'worker output still streams here\n' > "$fixture_repo/state/logs/live-worker.log"
cat > "$fixture_repo/state/active-agents/$$.json" <<EOF
{"pid":$$,"role":"worker","family":"codex","identity":"Codex fixture","card_path":"$fixture_repo/long-running-stage-that-needs-truncation.md","log_path":"$fixture_repo/state/logs/live-worker.log","started_at":"$started"}
EOF
printf '%s\n' "You've hit your session limit · resets 6:50pm" \
  > "$fixture_repo/state/logs/provider-worker.log"

PHAT_CONTROLLER_HOME="$controller_home" "$script_dir/aggregate-dashboard.sh" >/dev/null

mkdir -p "$fixture_root/bin"
checkout_sha="$(git -C "$script_dir/.." rev-parse --short HEAD)"
printf '#!/usr/bin/env sh\nprintf "autometta %s\\n"\n' "$checkout_sha" > "$fixture_root/bin/autometta"
chmod +x "$fixture_root/bin/autometta"
fixture_path="$fixture_root/bin:$PATH"

capture_80="$(PATH="$fixture_path" NO_COLOR=1 PHAT_CONTROLLER_FLEET_COLUMNS=80 PHAT_CONTROLLER_HOME="$controller_home" \
  PHAT_CONTROLLER_FLEET_ONCE=true "$script_dir/attach.sh" --fleet-ticker)"
capture_120="$(PATH="$fixture_path" NO_COLOR=1 PHAT_CONTROLLER_FLEET_COLUMNS=120 PHAT_CONTROLLER_HOME="$controller_home" \
  PHAT_CONTROLLER_FLEET_ONCE=true "$script_dir/attach.sh" --fleet-ticker)"

for width_capture in "80:$capture_80" "120:$capture_120"; do
  width="${width_capture%%:*}"
  capture="${width_capture#*:}"
  max_width="$(printf '%s\n' "$capture" | awk '{ if (length > max) max=length } END { print max+0 }')"
  (( max_width <= width )) || fail "$width-column capture contains a $max_width-column line"
done

running_line="$(printf '%s\n' "$capture_80" | grep -n '^RUNNING$' | cut -d: -f1)"
queue_line="$(printf '%s\n' "$capture_80" | grep -n '^QUEUE$' | cut -d: -f1)"
actions_line="$(printf '%s\n' "$capture_80" | grep -n '^REQUIRED ACTIONS$' | cut -d: -f1)"
failures_line="$(printf '%s\n' "$capture_80" | grep -n '^FAILURES$' | cut -d: -f1)"
limits_line="$(printf '%s\n' "$capture_80" | grep -n '^LIMITS$' | cut -d: -f1)"
(( running_line < queue_line && queue_line < actions_line && actions_line < failures_line && failures_line < limits_line )) \
  || fail 'section order changed'

assert_contains "$capture_80" 'codex' 'live agent family missing from RUNNING'
assert_contains "$capture_80" 'worker' 'live agent role missing from RUNNING'
assert_contains "$capture_80" 'log:' 'log-size fallback missing from RUNNING'
assert_contains "$capture_80" '4m' 'live agent elapsed time missing'
assert_contains "$capture_80" 'empty' 'idle queue is not represented as a value'
assert_contains "$capture_80" 'fresh-failure' 'fresh failure missing'
assert_contains "$capture_80" 'old-failure' 'old failure missing'
assert_contains "$capture_80" '8m' 'fresh failure age missing'
assert_contains "$capture_80" '3d' 'old failure age missing'
assert_contains "$capture_80" '...' '80-column capture did not truncate a cell with an ellipsis'
assert_not_contains "$capture_80" 'retired-stage' 'superseded stage appeared in the pane'

queue_block="$(printf '%s\n' "$capture_80" | sed -n '/^QUEUE$/,/^REQUIRED ACTIONS$/p')"
actions_block="$(printf '%s\n' "$capture_80" | sed -n '/^REQUIRED ACTIONS$/,/^FAILURES$/p')"
failure_block="$(printf '%s\n' "$capture_80" | sed -n '/^FAILURES$/,/^LIMITS$/p')"
limits_block="$(printf '%s\n' "$capture_80" | sed -n '/^LIMITS$/,/^REPOS$/p')"
assert_contains "$queue_block" 'empty' 'queue-empty value missing from QUEUE'
assert_contains "$actions_block" 'no operator action required' 'quiet REQUIRED ACTIONS form missing'
assert_not_contains "$failure_block" 'empty' 'queue-empty leaked into FAILURES'
assert_not_contains "$limits_block" 'idle-fixture' 'queue-empty leaked into LIMITS'

# Exercise the non-empty REQUIRED ACTIONS path after capturing its quiet form.
jq '.repos[0].halted = true | .repos[0].halt_reason = "manual reset required"' \
  "$controller_home/dashboard/data.json" > "$controller_home/dashboard/data.json.tmp"
mv "$controller_home/dashboard/data.json.tmp" "$controller_home/dashboard/data.json"

# Pin both locales so style selection tests the renderer, not the caller's
# inherited charmap: UTF-8 permits box drawing; C requires the ASCII fallback.
colour_capture="$(PATH="$fixture_path" TERM=xterm-256color LC_ALL=en_GB.UTF-8 NO_COLOR='' PHAT_CONTROLLER_FLEET_STYLE=colour \
  PHAT_CONTROLLER_FLEET_COLUMNS=120 PHAT_CONTROLLER_HOME="$controller_home" \
  PHAT_CONTROLLER_FLEET_ONCE=true "$script_dir/attach.sh" --fleet-ticker)"
plain_capture="$(PATH="$fixture_path" LC_ALL=C NO_COLOR=1 PHAT_CONTROLLER_FLEET_STYLE=colour \
  PHAT_CONTROLLER_FLEET_COLUMNS=120 PHAT_CONTROLLER_HOME="$controller_home" \
  PHAT_CONTROLLER_FLEET_ONCE=true "$script_dir/attach.sh" --fleet-ticker)"
assert_contains "$colour_capture" '┌' 'colour capture did not use box drawing'
assert_contains "$colour_capture" "$(tput setaf 1)" 'failure rows are not red'
assert_contains "$colour_capture" "$(tput setaf 2)" 'running rows are not green'
assert_contains "$colour_capture" "$(tput setaf 3)" 'stalled or limit rows are not yellow'
assert_contains "$colour_capture" 'manual reset required' 'halt missing from REQUIRED ACTIONS'
assert_contains "$plain_capture" '+' 'plain capture did not use ASCII borders'
assert_not_contains "$plain_capture" $'\033[' 'NO_COLOR capture contains terminal colour escapes'
assert_not_contains "$plain_capture" '┌' 'NO_COLOR capture contains box drawing'

printf 'PASS fleet pane sections, ages, queue classification, 80/120 fit, colour and fallbacks\n'
