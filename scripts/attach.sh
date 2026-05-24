#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
controller_home="${PHAT_CONTROLLER_HOME:-$HOME/.phat-controller}"
session_name="${PHAT_CONTROLLER_TMUX_SESSION:-phat-controller}"

usage() {
  printf 'Usage: %s [--dry-run]\n' "$(basename "$0")" >&2
  exit 1
}

dry_run=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      dry_run=true
      ;;
    *)
      usage
      ;;
  esac
  shift
done

status_cmd="cd '$script_dir/..' && scripts/status.sh; printf '\\nRefresh with: scripts/status.sh\\n'; exec \"\${SHELL:-/bin/sh}\""
log_cmd="mkdir -p '$controller_home/log'; latest=''; for candidate in '$controller_home/log'/tick-*.log; do [ -e \"\$candidate\" ] || continue; latest=\"\$candidate\"; done; if [ -n \"\$latest\" ]; then tail -f \"\$latest\"; else printf 'No tick log yet in $controller_home/log\\n'; exec \"\${SHELL:-/bin/sh}\"; fi"

if "$dry_run"; then
  printf 'tmux session: %s\n' "$session_name"
  printf 'status pane: %s\n' "$status_cmd"
  printf 'log pane: %s\n' "$log_cmd"
  exit 0
fi

if ! command -v tmux >/dev/null 2>&1; then
  printf 'MISSING tmux optional attach viewer requires tmux\n' >&2
  exit 1
fi

if ! tmux has-session -t "$session_name" 2>/dev/null; then
  tmux new-session -d -s "$session_name" "$status_cmd"
  tmux split-window -h -t "$session_name" "$log_cmd"
  tmux select-pane -t "$session_name":0.0
fi

tmux attach-session -t "$session_name"
