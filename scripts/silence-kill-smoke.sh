#!/usr/bin/env bash
# AUTOMETTA-CONTRACT-NONE reason=operator-requested watchdog; no stage card freezes it
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./tick.sh
source "$script_dir/tick.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  printf 'FAIL: silence-kill-smoke: %s\n' "$1" >&2
  exit 1
}

export AUTOMETTA_CLAUDE_PROJECTS_DIR="$tmp/projects"
now_epoch="$(date -u +%s)"
repo="$tmp/repo"
work_dir="$tmp/run-worktree"
mkdir -p "$repo/state/active-agents" "$repo/state/logs" "$work_dir"
transcript_dir="$AUTOMETTA_CLAUDE_PROJECTS_DIR/${work_dir//\//-}"

set_mtime() {
  python3 -c 'import os, sys; t = int(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$1" "$2"
}

register() {
  local pid="$1" streams="$2"
  jq -n --arg log "$repo/state/logs/$pid.log" --arg wd "$work_dir" --argjson streams "$streams" \
    '{pid: 0, log_path: $log, working_dir: $wd} + (if $streams then {log_streams: true} else {} end)' \
    > "$repo/state/active-agents/$pid.json"
  : > "$repo/state/logs/$pid.log"
}

register 101 true
set_mtime "$repo/state/logs/101.log" "$((now_epoch - 1500))"
register 102 false
set_mtime "$repo/state/logs/102.log" "$((now_epoch - 1500))"

[[ "$(dispatch_silence_seconds "$repo" 101 "$now_epoch" "")" == "1500" ]] \
  || fail "a streaming log untouched for 1500s does not read as 1500s of silence"
[[ -z "$(dispatch_silence_seconds "$repo" 102 "$now_epoch" "")" ]] \
  || fail "a dispatch that does not stream its log was judged silent"
[[ -z "$(dispatch_silence_seconds "$repo" 999 "$now_epoch" "")" ]] \
  || fail "an unregistered pid was judged silent"
[[ "$(dispatch_silence_seconds "$repo" 101 "$now_epoch" "$((now_epoch - 100))")" == "100" ]] \
  || fail "a wake after the last write does not restart the count"
[[ "$(dispatch_silence_seconds "$repo" 101 "$now_epoch" "$((now_epoch - 3000))")" == "1500" ]] \
  || fail "a wake before the last write moved the count"

mkdir -p "$transcript_dir"
: > "$transcript_dir/session.jsonl"
set_mtime "$transcript_dir/session.jsonl" "$((now_epoch - 60))"
[[ "$(dispatch_silence_seconds "$repo" 101 "$now_epoch" "")" == "60" ]] \
  || fail "a recent transcript write does not count as activity"

[[ "$(dispatch_silence_limit_seconds)" == "1200" ]] || fail "the default limit is not 1200s"
[[ "$(AUTOMETTA_SILENCE_KILL_SECONDS=0 dispatch_silence_limit_seconds)" == "0" ]] \
  || fail "AUTOMETTA_SILENCE_KILL_SECONDS=0 does not turn the check off"
[[ "$(AUTOMETTA_SILENCE_KILL_SECONDS=soon dispatch_silence_limit_seconds)" == "1200" ]] \
  || fail "a non-numeric limit does not fall back to 1200s"

if [[ "$(uname)" == "Darwin" ]]; then
  [[ "$(system_wake_epoch)" =~ ^[0-9]+$ ]] || fail "kern.waketime did not parse to epoch seconds"
fi

printf 'silence-kill-smoke: PASS\n'
