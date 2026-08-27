#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-root.sh
. "$script_dir/resolve-root.sh"
controller_home="$(autometta_controller_home)"
subscribers_dir="$controller_home/subscribers"
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

usage() {
  printf 'Usage: %s [repo-path] [--dry-run] [--ensure]\n' "$(basename "$0")" >&2
  printf '       %s --detach [repo-path] | --detach-all | --fleet-ticker | --fleet-refresh\n' "$(basename "$0")" >&2
  exit 1
}

shell_quote() { printf '%q' "$1"; }

resolve_path() {
  local input_path="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$input_path"
  else
    python3 - "$input_path" <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
  fi
}

read_field() {
  local file_path="$1" key="$2" raw
  raw="$(sed -n "s/^${key}:[[:space:]]*//p" "$file_path" 2>/dev/null | head -n1)"
  raw="${raw%\"}"; raw="${raw#\"}"
  raw="${raw%\'}"; raw="${raw#\'}"
  printf '%s' "$raw"
}

# shellcheck source=./session-slug.sh
source "$script_dir/session-slug.sh"
# shellcheck source=./alert-statuses.sh
source "$script_dir/alert-statuses.sh"
alert_statuses_json="$(alert_stage_statuses_json)"

fleet_columns() {
  # Deprecated for one release: PHAT_CONTROLLER_FLEET_COLUMNS.
  local columns="${AUTOMETTA_FLEET_COLUMNS:-${PHAT_CONTROLLER_FLEET_COLUMNS:-}}"
  if [[ -z "$columns" ]]; then
    columns="$(tput cols 2>/dev/null || printf 80)"
  fi
  [[ "$columns" =~ ^[0-9]+$ ]] || columns=80
  (( columns >= 40 )) || columns=40
  printf '%s' "$columns"
}

# render_fleet_once <scope>: draws one frame of the fleet page. Empty scope
# renders the fleet-wide page (every enabled subscriber); a repo path scopes
# it to that one repo's TOTALS and ESCALATIONS, with no REPOS table (card 66
# deliverable 6). One process, scripts/lib/fleet-ticker-render.py, does the
# drawing -- this function only gathers the already-aggregated JSON and calls
# it, the same division scripts/repo-ticker.sh uses for its own page.
render_fleet_once() {
  local scope="${1:-}"
  local data_path="$controller_home/dashboard/data.json"
  local stale_seconds="${AUTOMETTA_FLEET_STALE_SECONDS:-${PHAT_CONTROLLER_FLEET_STALE_SECONDS:-600}}"
  local width height mode payload
  width="$(fleet_columns)"
  height="${AUTOMETTA_FLEET_ROWS:-${LINES:-$(tput lines 2>/dev/null || printf 24)}}"
  if [[ -n "$scope" ]]; then
    mode=repo
    payload="$("$script_dir/aggregate-dashboard.sh" --repo "$scope" 2>/dev/null)" || payload=""
  else
    mode=fleet
    payload=""
    [[ -s "$data_path" ]] && payload="$(cat "$data_path")"
  fi
  AUTOMETTA_FLEET_PAYLOAD="$payload" AUTOMETTA_ALERT_STATUSES_JSON="$alert_statuses_json" \
    AUTOMETTA_BUILD_SHA="$build_sha" AUTOMETTA_BUILD_WARNING="$build_warning" \
    python3 "$script_dir/lib/fleet-ticker-render.py" "$mode" "$scope" "$width" "$height" "$stale_seconds"
  printf '\n'
}

fleet_refresher() {
  # Deprecated for one release: PHAT_CONTROLLER_FLEET_REFRESH_INTERVAL and PHAT_CONTROLLER_FLEET_SESSION.
  local interval="${AUTOMETTA_FLEET_REFRESH_INTERVAL:-${PHAT_CONTROLLER_FLEET_REFRESH_INTERVAL:-120}}"
  local session="${AUTOMETTA_FLEET_SESSION:-${PHAT_CONTROLLER_FLEET_SESSION:-}}"
  trap 'exit 0' INT TERM
  while true; do
    if [[ -n "$session" ]] && ! tmux has-session -t "$session" 2>/dev/null; then
      return 0
    fi
    "$script_dir/aggregate-dashboard.sh" >/dev/null 2>&1 || true
    sleep "$interval"
  done
}

fleet_ticker() {
  # Deprecated for one release: PHAT_CONTROLLER_STATUS_TICKER_INTERVAL and PHAT_CONTROLLER_FLEET_ONCE.
  local scope="${1:-}"
  local interval="${AUTOMETTA_STATUS_TICKER_INTERVAL:-${PHAT_CONTROLLER_STATUS_TICKER_INTERVAL:-5}}"
  if [[ "${AUTOMETTA_FLEET_ONCE:-${PHAT_CONTROLLER_FLEET_ONCE:-false}}" == true ]]; then
    refresh_build_status
    render_fleet_once "$scope"
    return 0
  fi
  trap 'exit 0' INT TERM
  while true; do
    refresh_build_status
    printf '\033[H'
    # Erase each line's tail as it is overwritten: home-and-repaint leaves
    # the old frame's longer lines showing through otherwise (REPOS over
    # agentic-rag-kimble rendered as REPOSntic-rag-kimble, 2026-08-24).
    render_fleet_once "$scope" | sed -e $'s/$/\033[K/'
    printf 'Refresh: %ss\033[K\033[J\n' "$interval"
    sleep "$interval"
  done
}

# viewer_sessions: the tmux sessions this tool owns, one per subscriber in the
# registry, enabled or disabled. A disabled subscriber's viewer is still ours
# to report and remove; a session that merely starts with "autometta-" is not.
#
# The prefix glob this replaces was a real hazard rather than a tidiness point.
# An operator's own shell or agent session can share the prefix -- on
# 2026-08-23 report_orphans flagged autometta-cl, an attached Claude Code
# session, as an orphaned viewer, and detach --all would have killed it on the
# strength of the same match. Killing a session because its name collides is
# unrecoverable, so ownership is established from the registry, never guessed
# from the name.
viewer_sessions() {
  local f base repo slug
  for f in "$subscribers_dir"/*.yaml "$subscribers_dir"/*.yaml.disabled; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f")"
    case "$base" in template.yaml|template.yaml.disabled) continue ;; esac
    repo="$(read_field "$f" repo_path)"
    [[ -n "$repo" ]] || continue
    slug="$(session_slug "$repo")"
    [[ -n "$slug" ]] || continue
    printf 'autometta-%s\n' "$slug"
  done
}

report_orphans() {
  command -v tmux >/dev/null 2>&1 || return 0
  local expected='' f enabled repo slug session
  for f in "$subscribers_dir"/*.yaml; do
    [[ -e "$f" ]] || continue
    [[ "$(basename "$f")" == template.yaml ]] && continue
    enabled="$(read_field "$f" enabled)"
    [[ "$enabled" == true ]] || continue
    repo="$(read_field "$f" repo_path)"
    [[ -n "$repo" ]] || continue
    slug="$(session_slug "$repo")"
    expected="${expected}autometta-${slug}"$'\n'
  done
  local owned
  owned="$(viewer_sessions)"
  while IFS= read -r session; do
    printf '%s' "$owned" | grep -Fqx "$session" || continue
    if ! printf '%s' "$expected" | grep -Fqx "$session"; then
      printf 'ORPHAN tmux viewer %s (subscriber disabled or gone; use `autometta detach --all` or `tmux kill-session -t %s`)\n' "$session" "$session" >&2
    fi
  done < <(tmux list-sessions -F '#S' 2>/dev/null || true)
}

reconcile_enabled_viewers() {
  local f enabled repo
  for f in "$subscribers_dir"/*.yaml; do
    [[ -e "$f" ]] || continue
    [[ "$(basename "$f")" == template.yaml ]] && continue
    enabled="$(read_field "$f" enabled)"
    [[ "$enabled" == true ]] || continue
    repo="$(read_field "$f" repo_path)"
    [[ -d "$repo" ]] || continue
    "$script_dir/attach.sh" --ensure "$repo" || true
  done
}

dry_run=false
ensure_only=false
mode=attach
repo_path="."
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run=true ;;
    --ensure) ensure_only=true ;;
    --fleet-ticker) mode=fleet ;;
    --detach) mode=detach ;;
    --detach-all) mode=detach_all ;;
    --fleet-refresh) mode=fleet_refresh ;;
    -*) usage ;;
    *)
      [[ "$repo_path" == "." ]] || usage
      repo_path="$1"
      ;;
  esac
  shift
done

if [[ "$mode" == fleet ]]; then
  fleet_scope=""
  [[ "$repo_path" == "." ]] || fleet_scope="$(resolve_path "$repo_path")"
  fleet_ticker "$fleet_scope"
  exit 0
fi
if [[ "$mode" == fleet_refresh ]]; then
  fleet_refresher
  exit 0
fi

if ! command -v tmux >/dev/null 2>&1; then
  if "$ensure_only"; then printf 'WARN tmux optional attach viewer unavailable\n' >&2; exit 0; fi
  printf 'MISSING tmux optional attach viewer requires tmux\n' >&2
  exit 1
fi

if [[ "$mode" == detach_all ]]; then
  removed=0
  owned="$(viewer_sessions)"
  while IFS= read -r session; do
    printf '%s' "$owned" | grep -Fqx "$session" || continue
    tmux kill-session -t "$session"
    printf 'PASS tmux viewer removed %s\n' "$session"
    removed=$(( removed + 1 ))
  done < <(tmux list-sessions -F '#S' 2>/dev/null || true)
  (( removed > 0 )) || printf 'NOOP no autometta viewers\n'
  exit 0
fi

repo_path="$(resolve_path "$repo_path")"
repo_slug="$(session_slug "$repo_path")"
[[ -n "$repo_slug" ]] || repo_slug=repo
# Deprecated for one release: PHAT_CONTROLLER_TMUX_SESSION.
session_name="${AUTOMETTA_TMUX_SESSION:-${PHAT_CONTROLLER_TMUX_SESSION:-autometta-$repo_slug}}"

if [[ "$mode" == detach ]]; then
  if tmux has-session -t "$session_name" 2>/dev/null; then
    tmux kill-session -t "$session_name"
    printf 'PASS tmux viewer removed %s\n' "$session_name"
  else
    printf 'NOOP tmux viewer absent %s\n' "$session_name"
  fi
  exit 0
fi

# shellcheck source=resolve-root.sh
. "$script_dir/resolve-root.sh"
# Resolved root, not the self root: the viewer's panes run autometta scripts,
# and a viewer reporting on a different tree than the tick executes is the
# split card 42 closed.
autometta_resolve_root "$(autometta_self_root "$script_dir")"
autometta_root="$AUTOMETTA_ROOT_RESOLVED"
autometta_root_q="$(shell_quote "$autometta_root")"
controller_log_q="$(shell_quote "$controller_home/log")"
repo_path_q="$(shell_quote "$repo_path")"
log_cmd="mkdir -p $controller_log_q; latest=''; for candidate in $controller_log_q/tick-*.log; do [ -e \"\$candidate\" ] || continue; latest=\"\$candidate\"; done; printf 'Project: $repo_slug\nRepo: $repo_path\n\n'; if [ -n \"\$latest\" ]; then printf '(showing only lines mentioning this repo; waiting for the first one)\\n'; tail -f \"\$latest\" | grep --line-buffered -F $repo_path_q; else printf 'No tick log yet in $controller_home/log\n'; exec \"\${SHELL:-/bin/sh}\"; fi"
# The repo window is one process, one pane: scripts/repo-ticker.sh (card 63).
# It used to share the window with a log pane and a separate status pane,
# splitting the terminal into quarters and truncating every column to
# whatever fraction of 119 the right-hand column happened to get. The log
# tail is still one keystroke away (`tmux next-window` / autometta attach's
# "log" window), it just no longer eats the ticker's width to sit beside it.
ticker_cmd="cd $autometta_root_q && scripts/repo-ticker.sh $repo_path_q"
# Window 0 in every session is the TUI (card 70+). It is the only view that
# answers "what is happening right now" in one page: run queue with the model
# pair per stage, live agents with their budget burn, card detail, escalations
# and the controller inbox. The ticker pages it landed in front of are still
# one keystroke away, they are just no longer what you arrive at. An operator
# reaching a session over ssh or from a phone wants the live page first, not a
# table they then have to navigate away from.
tui_cmd="cd $autometta_root_q && scripts/tui.sh $repo_path_q"
# Window 0 of the autometta-autometta session is the repo-scoped fleet page
# (TOTALS and ESCALATIONS for this one repo, no REPOS table -- card 66). The
# fleet-wide page (every subscriber) survives as a deliberately reached
# window, never the landing view: "I rarely if ever will want a fleet view"
# (operator feedback, 2026-08-25).
fleet_scoped_cmd="cd $autometta_root_q && scripts/attach.sh --fleet-ticker $repo_path_q"
fleet_cmd="cd $autometta_root_q && scripts/attach.sh --fleet-ticker"
session_name_q="$(shell_quote "$session_name")"
fleet_refresh_cmd="cd $autometta_root_q && AUTOMETTA_FLEET_SESSION=$session_name_q scripts/attach.sh --fleet-refresh"

report_orphans

if "$dry_run"; then
  printf 'tmux session: %s\nrepo: %s\n' "$session_name" "$repo_path"
  printf 'default window: tui (%s)\n' "$tui_cmd"
  if [[ "$repo_slug" == autometta ]]; then
    printf 'second window: repo (%s)\nthird window: status (%s)\nfourth window: fleet (%s)\n' \
      "$fleet_scoped_cmd" "$ticker_cmd" "$fleet_cmd"
  else
    printf 'second window: repo (%s)\n' "$ticker_cmd"
  fi
  printf 'log window: %s\n' "$log_cmd"
  exit 0
fi

if ! "$ensure_only"; then
  reconcile_enabled_viewers
fi

# An interactive re-attach replaces the viewer so long-running ticker loops
# pick up the installed scripts. --ensure remains non-disruptive for ticks.
if tmux has-session -t "$session_name" 2>/dev/null && ! "$ensure_only"; then
  tmux kill-session -t "$session_name"
  printf 'PASS tmux viewer refreshed %s\n' "$session_name"
fi

if ! tmux has-session -t "$session_name" 2>/dev/null; then
  if [[ "$repo_slug" == autometta ]]; then
    "$script_dir/aggregate-dashboard.sh" >/dev/null 2>&1 || true
    tmux new-session -d -s "$session_name" -n tui "$tui_cmd"
    tmux run-shell -b -t "$session_name" "$fleet_refresh_cmd"
    tmux new-window -d -t "$session_name" -n repo "$fleet_scoped_cmd"
    tmux new-window -d -t "$session_name" -n status "$ticker_cmd"
    tmux new-window -d -t "$session_name" -n fleet "$fleet_cmd"
    tmux new-window -d -t "$session_name" -n log "$log_cmd"
  else
    tmux new-session -d -s "$session_name" -n tui "$tui_cmd"
    tmux new-window -d -t "$session_name" -n repo "$ticker_cmd"
    tmux new-window -d -t "$session_name" -n log "$log_cmd"
  fi
  tmux select-window -t "$session_name":tui
  printf 'PASS tmux viewer created %s\n' "$session_name"
elif "$ensure_only"; then
  printf 'PASS tmux viewer exists %s\n' "$session_name"
fi

"$ensure_only" && exit 0
tmux attach-session -t "$session_name"
