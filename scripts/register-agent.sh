#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# register-agent.sh: write a per-agent liveness entry into
# state/active-agents/<pid>.json. Idempotent on the same pid.
#
# Args:
#   <repo_root> <pid> <role> <family> <identity> <card_path> <log_path> [<budget_seconds>] [<working_dir>]
#
# role:   worker | verifier
# family: codex | claude
#
# The ticker (scripts/agent-ticker.sh) and the heartbeat watchdog
# (scripts/heartbeat.sh) read these files.

if [[ $# -lt 7 || $# -gt 9 ]]; then
  printf 'usage: %s <repo_root> <pid> <role> <family> <identity> <card_path> <log_path> [<budget_seconds>] [<working_dir>]\n' \
    "$(basename "$0")" >&2
  exit 1
fi

repo_root="$1"
pid="$2"
role="$3"
family="$4"
identity="$5"
card_path="$6"
log_path="$7"
budget_seconds="${8:-0}"
working_dir="${9:-$repo_root}"
log_streams="${AUTOMETTA_LOG_STREAMS:-}"

if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
  printf 'refusing to register non-numeric pid: %s\n' "$pid" >&2
  exit 1
fi

case "$role" in
  worker|verifier|controller) ;;
  *) printf 'refusing unknown role: %s\n' "$role" >&2; exit 1 ;;
esac

active_dir="$repo_root/state/active-agents"
mkdir -p "$active_dir"

started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# A Codex plan without a session limit has nothing to stop one runaway
# dispatch but the weekly window. Stamp where that window stood at start and
# how far this run may move it (window_reserve.pace.run_cap_slots slot
# allowances); heartbeat.sh kills the run once it has. Empty when pace is off.
quota_start=""
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$family" == codex ]]; then
  quota_start="$(
    # shellcheck source=./quota-window.sh
    source "$script_dir/quota-window.sh" 2>/dev/null || exit 0
    AUTOMETTA_QUOTA_TICK_JSON=""
    verdict="$(quota_pace_reading codex 2>/dev/null)" || exit 0
    printf '%s' "$verdict" | jq -c --arg slots "$(quota_pace_mandate run_cap_slots 1)" '
      ($slots | tonumber? // 0) as $n
      | select(.used != null and .allowance != null and $n > 0)
      | {used, week_resets_at, run_cap_percent: ((.allowance * $n * 100 | round) / 100)}' 2>/dev/null
  )" || quota_start=""
fi
agent_id="${pid}-$(date +%s)"

tmp="$(mktemp)"
python3 - "$tmp" "$pid" "$role" "$family" "$identity" "$card_path" "$log_path" \
  "$budget_seconds" "$started_at" "$agent_id" "$working_dir" "$log_streams" "$quota_start" "$script_dir" "$repo_root" <<'PY'
import json
import sys

(out, pid, role, family, identity, card_path, log_path,
 budget_seconds, started_at, agent_id, working_dir, log_streams, quota_start, script_dir, repo_root) = sys.argv[1:]

doc = {
    "agent_id": agent_id,
    "pid": int(pid),
    "role": role,
    "family": family,
    "identity": identity,
    "card_path": card_path,
    "log_path": log_path,
    "budget_seconds": int(budget_seconds),
    "started_at": started_at,
    "working_dir": working_dir,
}
if log_streams == "1":
    doc["log_streams"] = True
if quota_start:
    doc["quota_start"] = json.loads(quota_start)
try:
    import importlib.util
    spec = importlib.util.spec_from_file_location("subscription_usage", script_dir + "/lib/subscription-usage.py")
    usage = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(usage)
    usage.capture(doc, repo_root)
except Exception as exc:
    print(f"subscription observation unavailable: {exc}", file=sys.stderr)
with open(out, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
mv "$tmp" "$active_dir/${pid}.json"
python3 - "$script_dir" "$repo_root" "$active_dir/${pid}.json" <<'PY'
import json
import sys
try:
    sys.path.insert(0, sys.argv[1] + "/lib")
    from lifecycle_events import agent_event
    with open(sys.argv[3]) as source:
        agent_event(sys.argv[2], json.load(source))
except Exception:
    pass
PY
printf '%s\n' "$active_dir/${pid}.json"
