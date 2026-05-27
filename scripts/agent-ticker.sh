#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# agent-ticker.sh: render a compact ACTIVE / RECENT / SCHEDULED view of
# dispatched agents and stage cards, suitable for the third tmux pane.
#
# Args:
#   <repo_root> [--once]
#
# Without --once, loops forever refreshing every $PHAT_CONTROLLER_TICKER_INTERVAL
# seconds (default 5). Quits cleanly on SIGINT/SIGTERM.

if [[ $# -lt 1 || $# -gt 2 ]]; then
  printf 'usage: %s <repo_root> [--once]\n' "$(basename "$0")" >&2
  exit 1
fi

repo_root="$1"
once=false
if [[ "${2:-}" == "--once" ]]; then
  once=true
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
refresh_interval="${PHAT_CONTROLLER_TICKER_INTERVAL:-5}"

render_once() {
  local active_dir="$repo_root/state/active-agents"
  local recent_dir="$repo_root/state/recent-agents"
  local heartbeat_path="$repo_root/state/heartbeat.json"
  local now_iso
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  printf 'Autometta agent ticker — %s\n' "$now_iso"
  printf 'Repo: %s\n' "$repo_root"
  printf '\n'

  printf 'ACTIVE\n'
  if [[ -f "$heartbeat_path" ]]; then
    python3 - "$heartbeat_path" <<'PY' || true
import json, sys
try:
    with open(sys.argv[1]) as fh:
        rep = json.load(fh)
except Exception:
    print("  (heartbeat.json unreadable)")
    sys.exit(0)
entries = rep.get("entries", [])
if not entries:
    print("  (none)")
else:
    for e in entries:
        flags = ",".join(e.get("flags", [])) or "fresh"
        print("  %-7s %-9s %-30s pid %-6s %5ss  log:%sB  %s" % (
            e.get("family", "?"),
            e.get("role", "?"),
            (e.get("card_path","")[-30:] or "-").lstrip("/"),
            e.get("pid", "?"),
            e.get("elapsed_seconds", "?"),
            e.get("log_size", "?"),
            flags,
        ))
PY
  else
    printf '  (no heartbeat yet — run scripts/heartbeat.sh %s)\n' "$repo_root"
  fi
  printf '\n'

  printf 'RECENT (last 5)\n'
  if [[ -d "$recent_dir" ]]; then
    python3 - "$recent_dir" <<'PY' || true
import json, os, sys
d = sys.argv[1]
files = []
try:
    for n in os.listdir(d):
        if n.endswith(".json"):
            p = os.path.join(d, n)
            files.append((os.path.getmtime(p), p))
except FileNotFoundError:
    pass
files.sort(reverse=True)
if not files:
    print("  (none)")
else:
    for _, p in files[:5]:
        try:
            with open(p) as fh:
                e = json.load(fh)
            print("  %-7s %-9s %-30s %-6s %ss" % (
                e.get("family","?"),
                e.get("role","?"),
                (e.get("card_path","")[-30:] or "-").lstrip("/"),
                e.get("outcome","?"),
                e.get("elapsed_seconds","?"),
            ))
        except Exception:
            pass
PY
  else
    printf '  (none)\n'
  fi
  printf '\n'

  printf 'SCHEDULED\n'
  if [[ -x "$script_dir/list-cards.sh" ]]; then
    pending="$("$script_dir/list-cards.sh" "$repo_root" 2>/dev/null \
      | awk -F'\t' '$2 == "pending" {print $1}' | head -5)"
    in_flight="$("$script_dir/list-cards.sh" "$repo_root" 2>/dev/null \
      | awk -F'\t' '$2 == "in_flight" {print $1}')"
    if [[ -n "$in_flight" ]]; then
      printf '%s\n' "$in_flight" | sed 's/^/  in_flight  /'
    fi
    if [[ -n "$pending" ]]; then
      printf '%s\n' "$pending" | sed 's/^/  pending    /'
    fi
    if [[ -z "$in_flight" && -z "$pending" ]]; then
      printf '  (no pending cards)\n'
    fi
  else
    printf '  (list-cards.sh missing)\n'
  fi
}

if "$once"; then
  render_once
  exit 0
fi

trap 'exit 0' INT TERM

while true; do
  clear
  render_once
  sleep "$refresh_interval"
done
