#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
controller_home="${PHAT_CONTROLLER_HOME:-$HOME/.phat-controller}"

usage() {
  printf 'Usage: %s [repo-path] [--dry-run] [--ensure]\n' "$(basename "$0")" >&2
  exit 1
}

shell_quote() {
  printf '%q' "$1"
}

resolve_path() {
  local input_path="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$input_path"
  else
    python3 - "$input_path" <<'PY'
import os
import sys
print(os.path.realpath(sys.argv[1]))
PY
  fi
}

session_slug() {
  basename "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^[:alnum:]_.-]/-/g; s/^-*//; s/-*$//'
}

dry_run=false
ensure_only=false
repo_path="."

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      dry_run=true
      ;;
    --ensure)
      ensure_only=true
      ;;
    -*)
      usage
      ;;
    *)
      if [[ "$repo_path" != "." ]]; then
        usage
      fi
      repo_path="$1"
      ;;
  esac
  shift
done

repo_path="$(resolve_path "$repo_path")"
repo_slug="$(session_slug "$repo_path")"
if [[ -z "$repo_slug" ]]; then
  repo_slug="repo"
fi

session_name="${PHAT_CONTROLLER_TMUX_SESSION:-autometta-$repo_slug}"
autometta_root="$(cd "$script_dir/.." && pwd)"
autometta_root_q="$(shell_quote "$autometta_root")"
controller_log_q="$(shell_quote "$controller_home/log")"

repo_path_q="$(shell_quote "$repo_path")"
status_cmd="cd $autometta_root_q && scripts/status-ticker.sh"
log_cmd="mkdir -p $controller_log_q; latest=''; for candidate in $controller_log_q/tick-*.log; do [ -e \"\$candidate\" ] || continue; latest=\"\$candidate\"; done; printf 'Project: $repo_slug\nRepo: $repo_path\n\n'; if [ -n \"\$latest\" ]; then tail -f \"\$latest\"; else printf 'No tick log yet in $controller_home/log\\n'; exec \"\${SHELL:-/bin/sh}\"; fi"
ticker_cmd="cd $autometta_root_q && scripts/agent-ticker.sh $repo_path_q"

if "$dry_run"; then
  printf 'tmux session: %s\n' "$session_name"
  printf 'repo: %s\n' "$repo_path"
  printf 'status pane: %s\n' "$status_cmd"
  printf 'log pane: %s\n' "$log_cmd"
  printf 'ticker pane: %s\n' "$ticker_cmd"
  exit 0
fi

if ! command -v tmux >/dev/null 2>&1; then
  if "$ensure_only"; then
    printf 'WARN tmux optional attach viewer unavailable\n' >&2
    exit 0
  else
    printf 'MISSING tmux optional attach viewer requires tmux\n' >&2
    exit 1
  fi
fi

if ! tmux has-session -t "$session_name" 2>/dev/null; then
  tmux new-session -d -s "$session_name" "$status_cmd"
  tmux split-window -h -t "$session_name" "$log_cmd"
  tmux split-window -v -t "$session_name":0.1 "$ticker_cmd"
  tmux select-pane -t "$session_name":0.0
  printf 'PASS tmux viewer created %s\n' "$session_name"
else
  # Idempotent backfill: if the ticker pane is missing on an existing session,
  # add it. tmux pane indices are stable within a window; pane 0.2 only exists
  # once we have created it.
  pane_count="$(tmux list-panes -t "$session_name":0 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$pane_count" = "2" ]]; then
    tmux split-window -v -t "$session_name":0.1 "$ticker_cmd"
    tmux select-pane -t "$session_name":0.0
    printf 'PASS tmux ticker pane added to %s\n' "$session_name"
  elif "$ensure_only"; then
    printf 'PASS tmux viewer exists %s\n' "$session_name"
  fi
fi

if "$ensure_only"; then
  exit 0
fi

tmux attach-session -t "$session_name"
