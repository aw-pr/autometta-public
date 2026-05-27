#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# heartbeat.sh: walk state/active-agents/, check liveness, log mtime
# staleness, and budget overrun. Surface findings to state/heartbeat.json.
# Move dead entries to state/recent-agents/ with outcome=exited.
#
# This is a watchdog, not a gate. It never kills, retries, or escalates.
# Exit is always 0 so it cannot break a tick.

if [[ $# -ne 1 ]]; then
  printf 'usage: %s <repo_root>\n' "$(basename "$0")" >&2
  exit 1
fi

repo_root="$1"
active_dir="$repo_root/state/active-agents"
recent_dir="$repo_root/state/recent-agents"
heartbeat_path="$repo_root/state/heartbeat.json"
stall_seconds="${PHAT_CONTROLLER_HEARTBEAT_STALL:-300}"

mkdir -p "$active_dir" "$recent_dir"

# Build the heartbeat report in a tmp file, atomic-rename at end.
tmp_report="$(mktemp)"

python3 - "$active_dir" "$recent_dir" "$tmp_report" "$stall_seconds" <<'PY'
import json
import os
import sys
import time

active_dir, recent_dir, out_path, stall_str = sys.argv[1:]
stall_seconds = int(stall_str)
now = int(time.time())

entries = []
for name in sorted(os.listdir(active_dir)):
    if not name.endswith(".json"):
        continue
    path = os.path.join(active_dir, name)
    try:
        with open(path, "r", encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        continue

    pid = doc.get("pid")
    alive = False
    if isinstance(pid, int):
        try:
            os.kill(pid, 0)
            alive = True
        except OSError:
            alive = False

    flags = []
    log_path = doc.get("log_path") or ""
    if log_path and os.path.exists(log_path):
        try:
            mtime = int(os.path.getmtime(log_path))
            if now - mtime > stall_seconds:
                flags.append("silent")
            doc["log_size"] = os.path.getsize(log_path)
            doc["log_mtime_age_seconds"] = now - mtime
        except OSError:
            pass

    started_at = doc.get("started_at")
    elapsed = None
    if started_at:
        try:
            import datetime
            ts = datetime.datetime.strptime(started_at, "%Y-%m-%dT%H:%M:%SZ").replace(
                tzinfo=datetime.timezone.utc
            )
            elapsed = now - int(ts.timestamp())
            doc["elapsed_seconds"] = elapsed
        except ValueError:
            pass

    budget = doc.get("budget_seconds") or 0
    if isinstance(budget, int) and budget > 0 and elapsed is not None and elapsed > budget:
        flags.append("over-budget")

    doc["alive"] = alive
    doc["flags"] = flags

    if not alive:
        # Move to recent-agents with outcome=exited; the real outcome
        # gets set by the tick reaper if it has better information.
        doc.setdefault("outcome", "exited")
        doc["exited_at"] = "%dZ" % now
        # Re-stamp using ISO format
        import datetime as dt2
        doc["exited_at"] = dt2.datetime.fromtimestamp(now, tz=dt2.timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        )
        stage = doc.get("card_path") or ""
        slug = os.path.basename(stage).rsplit(".", 1)[0] or "unknown"
        target = os.path.join(recent_dir, "%d-%s.json" % (pid or 0, slug))
        try:
            with open(target, "w", encoding="utf-8") as fh:
                json.dump(doc, fh, indent=2, sort_keys=True)
                fh.write("\n")
            os.remove(path)
        except OSError:
            pass
        continue

    entries.append(doc)

report = {
    "checked_at": "%sZ" % time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(now)),
    "stall_threshold_seconds": stall_seconds,
    "active_count": len(entries),
    "entries": entries,
}
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(report, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY

mv "$tmp_report" "$heartbeat_path"
exit 0
