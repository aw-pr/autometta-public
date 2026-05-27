#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# watch-agent.sh: poll a dispatched agent until it terminates or stalls
# past a grace window. Closes the loop on the registry + heartbeat
# surface: an agent that dies silently (no log output) or hangs past
# its budget produces a non-zero exit here, which surfaces to whoever
# is waiting on this script (orchestrator session, harness background
# task, cron tick — anywhere).
#
# Args:
#   <repo_root> <pid> [<label>]
#
# Defaults:
#   poll interval:  PHAT_CONTROLLER_WATCH_POLL=60 seconds
#   stall grace:    PHAT_CONTROLLER_WATCH_STALL_GRACE=120 seconds past
#                   the heartbeat-flagged 'silent' threshold before
#                   escalating to STUCK.
#
# Exit codes:
#   0  process exited cleanly (heartbeat will reap to recent-agents/)
#   2  STUCK — silent past grace window; caller should investigate
#   3  bad input (pid invalid, no registry entry, etc.)

if [[ $# -lt 2 || $# -gt 3 ]]; then
  printf 'usage: %s <repo_root> <pid> [<label>]\n' "$(basename "$0")" >&2
  exit 3
fi

repo_root="$1"
pid="$2"
label="${3:-pid-$pid}"

if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
  printf 'refusing non-numeric pid: %s\n' "$pid" >&2
  exit 3
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
poll_interval="${PHAT_CONTROLLER_WATCH_POLL:-60}"
stall_grace="${PHAT_CONTROLLER_WATCH_STALL_GRACE:-120}"

if [[ ! -x "$script_dir/heartbeat.sh" ]]; then
  printf 'heartbeat.sh missing at %s\n' "$script_dir/heartbeat.sh" >&2
  exit 3
fi

printf 'watch-agent: %s pid=%s repo=%s poll=%ss grace=%ss\n' \
  "$label" "$pid" "$repo_root" "$poll_interval" "$stall_grace"

stall_first_seen=0
while true; do
  if ! kill -0 "$pid" 2>/dev/null; then
    printf 'watch-agent: %s pid=%s exited\n' "$label" "$pid"
    # Final heartbeat pass to move the registry entry.
    "$script_dir/heartbeat.sh" "$repo_root" >/dev/null 2>&1 || true
    exit 0
  fi

  "$script_dir/heartbeat.sh" "$repo_root" >/dev/null 2>&1 || true

  # Pull this agent's row out of state/heartbeat.json
  status_line="$(python3 - "$repo_root/state/heartbeat.json" "$pid" <<'PY'
import json, sys
try:
    rep = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
pid = int(sys.argv[2])
for e in rep.get("entries", []):
    if e.get("pid") == pid:
        flags = ",".join(e.get("flags", [])) or "fresh"
        print("elapsed=%ss log_size=%sB flags=%s" % (
            e.get("elapsed_seconds", "?"),
            e.get("log_size", "?"),
            flags,
        ))
        break
PY
)"

  if [[ -z "$status_line" ]]; then
    status_line="(no heartbeat entry — agent may not be registered)"
  fi
  printf 'watch-agent: %s pid=%s %s\n' "$label" "$pid" "$status_line"

  if [[ "$status_line" == *silent* ]]; then
    now="$(date +%s)"
    if [[ "$stall_first_seen" -eq 0 ]]; then
      stall_first_seen="$now"
      printf 'watch-agent: %s pid=%s first silent observation, grace %ss\n' \
        "$label" "$pid" "$stall_grace"
    elif (( now - stall_first_seen > stall_grace )); then
      printf 'STUCK: %s pid=%s silent past grace window (%ss)\n' \
        "$label" "$pid" "$stall_grace" >&2
      exit 2
    fi
  else
    stall_first_seen=0
  fi

  sleep "$poll_interval"
done
