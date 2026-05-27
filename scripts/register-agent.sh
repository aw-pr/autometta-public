#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# register-agent.sh: write a per-agent liveness entry into
# state/active-agents/<pid>.json. Idempotent on the same pid.
#
# Args:
#   <repo_root> <pid> <role> <family> <identity> <card_path> <log_path> [<budget_seconds>]
#
# role:   worker | verifier
# family: codex | claude
#
# The ticker (scripts/agent-ticker.sh) and the heartbeat watchdog
# (scripts/heartbeat.sh) read these files.

if [[ $# -lt 7 || $# -gt 8 ]]; then
  printf 'usage: %s <repo_root> <pid> <role> <family> <identity> <card_path> <log_path> [<budget_seconds>]\n' \
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

if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
  printf 'refusing to register non-numeric pid: %s\n' "$pid" >&2
  exit 1
fi

case "$role" in
  worker|verifier) ;;
  *) printf 'refusing unknown role: %s\n' "$role" >&2; exit 1 ;;
esac

active_dir="$repo_root/state/active-agents"
mkdir -p "$active_dir"

started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
agent_id="${pid}-$(date +%s)"

tmp="$(mktemp)"
python3 - "$tmp" "$pid" "$role" "$family" "$identity" "$card_path" "$log_path" \
  "$budget_seconds" "$started_at" "$agent_id" <<'PY'
import json
import sys

(out, pid, role, family, identity, card_path, log_path,
 budget_seconds, started_at, agent_id) = sys.argv[1:]

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
}
with open(out, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
mv "$tmp" "$active_dir/${pid}.json"
printf '%s\n' "$active_dir/${pid}.json"
