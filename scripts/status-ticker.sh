#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# status-ticker.sh: render the multi-repo `autometta status` table plus a
# COMPLETED panel (last N stages across all subscribed repos that ended with
# status: passed), in a refresh loop suitable for the left tmux pane.
#
# Args: [--once] [--repo <path>]
#
# --repo scopes the status.sh table to a single subscriber (passed through
# verbatim); the COMPLETED panel stays global — it is cheap and useful
# context even when the pane is otherwise scoped to one repo.

once=false
repo_filter=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --once)
      once=true
      shift
      ;;
    --repo)
      [[ $# -ge 2 ]] || { printf 'usage: %s [--once] [--repo <path>]\n' "$(basename "$0")" >&2; exit 1; }
      repo_filter=(--repo "$2")
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-root.sh
. "$script_dir/resolve-root.sh"
controller_home="$(autometta_controller_home)"
subscribers_dir="$controller_home/subscribers"
# Deprecated for one release: PHAT_CONTROLLER_STATUS_TICKER_INTERVAL.
refresh_interval="${AUTOMETTA_STATUS_TICKER_INTERVAL:-${PHAT_CONTROLLER_STATUS_TICKER_INTERVAL:-5}}"
# Deprecated for one release: PHAT_CONTROLLER_COMPLETED_LIMIT.
completed_limit="${AUTOMETTA_COMPLETED_LIMIT:-${PHAT_CONTROLLER_COMPLETED_LIMIT:-8}}"
build_checked_at=0
build_sha="unknown"
installed_sha="unknown"
build_warning=""

refresh_build_status() {
  local now version
  now="$(date +%s)"
  (( now - build_checked_at < 60 )) && return 0
  build_checked_at="$now"
  build_sha="$(git -C "$script_dir/.." rev-parse --short HEAD 2>/dev/null || printf unknown)"
  version="$(autometta --version 2>/dev/null || true)"
  installed_sha="$(printf '%s' "$version" | grep -Eo '[0-9a-f]{7,40}' | head -n1 || true)"
  [[ -n "$installed_sha" ]] || installed_sha=unknown
  [[ "$installed_sha" == unknown ]] || installed_sha="${installed_sha:0:7}"
  build_warning=""
  if [[ "$build_sha" != unknown && "$installed_sha" != unknown && "$build_sha" != "$installed_sha" ]]; then
    build_warning="BUILD DRIFT: installed ${installed_sha}, checkout ${build_sha} (fallback comparison)"
  fi
}

render_full() {
  printf 'autometta %s status ticker — %s\n' "$build_sha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [[ -n "$build_warning" ]] && printf 'ALERTS\n  %s\n' "$build_warning"
  printf '\n'

  if [[ -x "$script_dir/status.sh" ]]; then
    "$script_dir/status.sh" "${repo_filter[@]}" || true
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

render_once() {
  local width height raw
  width="${AUTOMETTA_TICKER_COLUMNS:-${COLUMNS:-$(tput cols 2>/dev/null || printf 120)}}"
  height="${AUTOMETTA_TICKER_ROWS:-${LINES:-$(tput lines 2>/dev/null || printf 32)}}"
  raw="$(COLUMNS="$width" AUTOMETTA_TICKER_COLUMNS="$width" render_full)"
  AUTOMETTA_TICKER_FRAME="$raw" python3 - "$width" "$height" "$refresh_interval" <<'PY'
import os, sys
w, h, interval = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
lines = os.environ.get("AUTOMETTA_TICKER_FRAME", "").splitlines()
def fit(s): return s if len(s) <= w else s[:max(0, w - 1)] + ">"
room = max(0, h - 1)
if len(lines) > room:
    hidden = len(lines) - max(0, room - 1)
    lines = lines[:max(0, room - 1)] + ["COMPLETED: %d line(s) hidden" % hidden]
lines += [""] * max(0, room - len(lines))
lines.append("Refresh: %ss  Ctrl+C to quit" % interval)
sys.stdout.write("\n".join(fit(x) for x in lines[:h]))
PY
}

if "$once"; then
  refresh_build_status
  render_once
  exit 0
fi

printf '\033[?25l\033[2J'
trap 'printf "\033[?25h\n"; exit 0' INT TERM EXIT

while true; do
  refresh_build_status
  frame="$(render_once)"
  printf '\033[H%s\033[J' "$frame"
  sleep "$refresh_interval"
done
