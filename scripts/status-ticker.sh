#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# status-ticker.sh: render the multi-repo `autometta status` table plus a
# COMPLETED panel (last N stages across all subscribed repos that ended with
# status: passed), in a refresh loop suitable for the left tmux pane.
#
# Args: [--once]

once=false
if [[ "${1:-}" == "--once" ]]; then
  once=true
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
controller_home="${PHAT_CONTROLLER_HOME:-$HOME/.phat-controller}"
subscribers_dir="$controller_home/subscribers"
refresh_interval="${PHAT_CONTROLLER_STATUS_TICKER_INTERVAL:-5}"
completed_limit="${PHAT_CONTROLLER_COMPLETED_LIMIT:-8}"

render_once() {
  printf 'Autometta status ticker — %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ -x "$script_dir/status.sh" ]]; then
    "$script_dir/status.sh" || true
  else
    printf 'status.sh unreachable at %s\n' "$script_dir/status.sh"
  fi

  printf '\nCOMPLETED (last %s passed)\n' "$completed_limit"
  if [[ ! -d "$subscribers_dir" ]]; then
    printf '  (no subscribers dir at %s)\n' "$subscribers_dir"
    return 0
  fi

  python3 - "$subscribers_dir" "$completed_limit" <<'PY' || true
import os, sys, re
from datetime import datetime, timezone

subscribers_dir, limit = sys.argv[1], int(sys.argv[2])

def read_field(path, key):
    try:
        with open(path) as fh:
            for line in fh:
                if line.startswith(key + ":"):
                    v = line.split(":", 1)[1].strip()
                    return v.strip('"').strip("'")
    except FileNotFoundError:
        return None
    return None

def parse_passed_stages(state_path, repo_name):
    # Minimal yaml-as-text parser: we only need id / status / completed_at
    # inside each `- id:` block. Avoids a yaml dep, matches the rest of the
    # repo's parsing style.
    try:
        with open(state_path) as fh:
            lines = fh.read().splitlines()
    except FileNotFoundError:
        return []
    out = []
    cur = {}
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("- id:"):
            if cur.get("status") == "passed":
                out.append((repo_name, cur.get("id"), cur.get("completed_at")))
            cur = {"id": stripped.split(":", 1)[1].strip()}
        elif stripped.startswith("status:") and cur:
            cur["status"] = stripped.split(":", 1)[1].strip()
        elif stripped.startswith("completed_at:") and cur:
            cur["completed_at"] = stripped.split(":", 1)[1].strip()
    if cur.get("status") == "passed":
        out.append((repo_name, cur.get("id"), cur.get("completed_at")))
    return out

now = datetime.now(timezone.utc)
def age(ts):
    if not ts or ts in ("null", "-", "~"):
        return "?"
    try:
        dt = datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except Exception:
        return "?"
    s = int((now - dt).total_seconds())
    if s < 60:    return f"{s}s ago"
    if s < 3600:  return f"{s//60}m ago"
    if s < 86400: return f"{s//3600}h{(s%3600)//60}m ago"
    return f"{s//86400}d ago"

rows = []
for n in sorted(os.listdir(subscribers_dir)):
    if not n.endswith(".yaml") or n == "template.yaml":
        continue
    sub = os.path.join(subscribers_dir, n)
    if read_field(sub, "enabled") != "true":
        continue
    repo_root = read_field(sub, "repo_path")
    if not repo_root:
        continue
    repo_name = os.path.basename(repo_root.rstrip("/"))
    state_path = os.path.join(repo_root, "state", "state.yaml")
    rows.extend(parse_passed_stages(state_path, repo_name))

def sort_key(row):
    _, _, ts = row
    if not ts or ts == "null":
        return ""
    return ts
rows.sort(key=sort_key, reverse=True)

if not rows:
    print("  (none)")
else:
    for repo_name, stage_id, ts in rows[:limit]:
        print("  %-24s %-34s passed %s" % (repo_name, (stage_id or "?")[:34], age(ts)))
PY
}

if "$once"; then
  render_once
  exit 0
fi

trap 'exit 0' INT TERM

while true; do
  clear
  render_once
  printf '\nRefresh: %ss  (Ctrl+C to drop to shell)\n' "$refresh_interval"
  sleep "$refresh_interval"
done
