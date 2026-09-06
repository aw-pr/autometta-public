#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./tick.sh
source "$script_dir/tick.sh"

tmp="$(mktemp -d)"
wrapper_pid=""
child_pid=""
cleanup() {
  [[ -z "$wrapper_pid" ]] || kill -KILL "$wrapper_pid" 2>/dev/null || true
  [[ -z "$child_pid" ]] || kill -KILL "$child_pid" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

export AUTOMETTA_CLAUDE_PROJECTS_DIR="$tmp/projects"
now_epoch="$(date -u +%s)"
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

write_transcript() {
  local work_dir="$1" mode="$2" transcript_dir transcript
  transcript_dir="$AUTOMETTA_CLAUDE_PROJECTS_DIR/${work_dir//\//-}"
  mkdir -p "$transcript_dir"
  transcript="$transcript_dir/session.jsonl"
  : > "$transcript"
  for _ in 1 2 3 4 5 6; do
    printf '{"type":"system","subtype":"api_error","timestamp":"%s","cwd":"%s"}\n' \
      "$now_iso" "$work_dir" >> "$transcript"
  done
  if [[ "$mode" == "with-tool" ]]; then
    printf '{"type":"assistant","timestamp":"%s","cwd":"%s","message":{"content":[{"type":"tool_use","name":"Bash"}]}}\n' \
      "$now_iso" "$work_dir" >> "$transcript"
  fi
}

errors_only="$tmp/errors-only"
errors_and_tool="$tmp/errors-and-tool"
missing="$tmp/missing"
write_transcript "$errors_only" errors-only
write_transcript "$errors_and_tool" with-tool

# AUTOMETTA-CONTRACT-BEGIN card=stage-cards/109-a-worker-retrying-a-dead-api-is-not-working.md
[[ "$(claude_api_error_stall_count "$errors_only" 10 "$now_epoch")" == "6" ]]
[[ "$(claude_api_error_stall_count "$errors_and_tool" 10 "$now_epoch")" == "0" ]]
[[ "$(claude_api_error_stall_count "$missing" 10 "$now_epoch")" == "0" ]]

marker="autometta-stall-kill-smoke-$$"
bash -c 'marker="$1"; sleep 60 & child=$!; printf "%s\n" "$child" > "$2"; wait "$child"' \
  stall-wrapper "$marker" "$tmp/child.pid" &
wrapper_pid="$!"
for _ in 1 2 3 4 5; do
  [[ -s "$tmp/child.pid" ]] && break
  sleep 0.1
done
child_pid="$(cat "$tmp/child.pid")"
terminate_process_tree "$wrapper_pid"
wait "$wrapper_pid" 2>/dev/null || true
! kill -0 "$wrapper_pid" 2>/dev/null
! kill -0 "$child_pid" 2>/dev/null
! pgrep -f "$marker" >/dev/null 2>&1
# AUTOMETTA-CONTRACT-END

wrapper_pid=""
child_pid=""
printf 'stall-kill-smoke: PASS\n'
