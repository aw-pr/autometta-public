#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
controller_home="${PHAT_CONTROLLER_HOME:-$HOME/.phat-controller}"
subscribers_dir="$controller_home/subscribers"

usage() {
  printf 'Usage: %s [repo-path] [--dry-run] [--ensure]\n' "$(basename "$0")" >&2
  printf '       %s --detach [repo-path] | --detach-all | --fleet-ticker\n' "$(basename "$0")" >&2
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

render_fleet_once() {
  local data_path="$controller_home/dashboard/data.json"
  local stale_seconds="${PHAT_CONTROLLER_FLEET_STALE_SECONDS:-600}"
  printf 'Autometta fleet: %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ ! -s "$data_path" ]] || ! jq -e '.generated_at and (.repos | type == "array")' "$data_path" >/dev/null 2>&1; then
    printf 'FLEET DATA MISSING\n  Run `autometta dashboard`; an empty fleet is not assumed healthy.\n'
    return 0
  fi

  local now generated_epoch age
  now="$(date -u +%s)"
  generated_epoch="$(jq -r 'try (.generated_at | fromdateiso8601) catch 0' "$data_path")"
  age=$(( now - generated_epoch ))
  if (( generated_epoch == 0 || age > stale_seconds )); then
    printf 'FLEET DATA STALE: generated %ss ago (limit %ss)\n' "$age" "$stale_seconds"
    printf '  Run `autometta dashboard`; stale data is not rendered as a healthy fleet.\n\n'
  else
    printf 'Data age: %ss\n\n' "$age"
  fi

  printf 'TOTALS\n'
  jq -r '
    (.fleet_totals // {}) as $t |
    "  enabled: \($t.enabled_repos // ([.repos[] | select(.enabled)] | length))" +
    "  today: \($t.today_tokens // 0) tokens / $\($t.today_cost_usd_est // 0) est" +
    "  window: \($t.window_tokens_spent // 0) / \($t.window_token_cap_total // 0) tokens"
  ' "$data_path"
  printf '\nREPOS\n'
  printf '  %-26s %-8s %-22s %-9s %-18s %s\n' 'subscriber' 'enabled' 'state' 'queue' 'window' 'last dispatch'
  jq -r --argjson now "$now" '
    def age:
      (try (. | fromdateiso8601) catch 0) as $then |
      if $then == 0 then "never"
      elif ($now - $then) < 60 then ((($now - $then) | floor | tostring) + "s")
      elif ($now - $then) < 3600 then ((($now - $then) / 60 | floor | tostring) + "m")
      elif ($now - $then) < 86400 then ((($now - $then) / 3600 | floor | tostring) + "h")
      else ((($now - $then) / 86400 | floor | tostring) + "d") end;
    .repos[] | select(.enabled) |
    [ .name, "yes", (if .halted then "HALTED:" + (.halt_reason // "unknown") else "running" end),
      ((.queue_depth // 0 | tostring) + "/" + (.in_flight // 0 | tostring)),
      ((.tokens_spent // 0 | tostring) + "/" + (.token_cap_total // 0 | tostring)),
      ((.last_dispatch_at // "") | age) ] | @tsv' "$data_path" |
    while IFS=$'\t' read -r name enabled state queue window last_dispatch; do
      printf '  %-26s %-8s %-22s %-9s %-18s %s\n' \
        "$name" "$enabled" "$state" "$queue" "$window" "$last_dispatch"
    done

  printf '\nALERTS (fleet union)\n'
  local alert_count
  alert_count="$(jq '[.repos[] | select(.enabled) |
    (if .halted then 1 else 0 end),
    (if (.consecutive_failures // 0) > 0 then 1 else 0 end),
    (if ((.queue_depth // 0) == 0 and (.in_flight // 0) == 0) then 1 else 0 end),
    ([.stages[]? | select(.status == "failed" or .status == "verifier_failed" or .status == "stalled")] | length),
    (.alerts[]? | 1)] | add // 0' "$data_path")"
  if (( alert_count == 0 )); then
    printf '  (none)\n'
  else
    jq -r '.repos[] | select(.enabled) as $r |
      (if $r.halted then "  " + $r.name + ": halted, " + ($r.halt_reason // "unknown") else empty end),
      (if ($r.consecutive_failures // 0) > 0 then "  " + $r.name + ": consecutive failures " + ($r.consecutive_failures | tostring) + "/" + ($r.consecutive_failure_cap | tostring) else empty end),
      (if (($r.queue_depth // 0) == 0 and ($r.in_flight // 0) == 0) then "  " + $r.name + ": queue empty" else empty end),
      ($r.stages[]? | select(.status == "failed" or .status == "verifier_failed" or .status == "stalled") | "  " + $r.name + ": " + .id + " " + .status),
      ($r.alerts[]? | "  " + $r.name + ": " + (.line // tostring))' "$data_path"
  fi

  local overlap
  overlap="$(jq -r '[.repos[] | select(.enabled and (.name | startswith("emergence-lab"))) | .name] | if length > 1 then join(", ") else empty end' "$data_path")"
  if [[ -n "$overlap" ]]; then
    printf '\nOVERLAP\n  emergence-lab subscribers enabled together: %s\n' "$overlap"
  fi
}

fleet_ticker() {
  local interval="${PHAT_CONTROLLER_STATUS_TICKER_INTERVAL:-5}"
  if [[ "${PHAT_CONTROLLER_FLEET_ONCE:-false}" == true ]]; then
    render_fleet_once
    return 0
  fi
  trap 'exit 0' INT TERM
  while true; do
    clear
    render_fleet_once
    printf '\nRefresh: %ss\n' "$interval"
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
    -*) usage ;;
    *)
      [[ "$repo_path" == "." ]] || usage
      repo_path="$1"
      ;;
  esac
  shift
done

if [[ "$mode" == fleet ]]; then
  fleet_ticker
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
session_name="${PHAT_CONTROLLER_TMUX_SESSION:-autometta-$repo_slug}"

if [[ "$mode" == detach ]]; then
  if tmux has-session -t "$session_name" 2>/dev/null; then
    tmux kill-session -t "$session_name"
    printf 'PASS tmux viewer removed %s\n' "$session_name"
  else
    printf 'NOOP tmux viewer absent %s\n' "$session_name"
  fi
  exit 0
fi

autometta_root="$(cd "$script_dir/.." && pwd)"
autometta_root_q="$(shell_quote "$autometta_root")"
controller_log_q="$(shell_quote "$controller_home/log")"
repo_path_q="$(shell_quote "$repo_path")"
status_cmd="cd $autometta_root_q && scripts/status-ticker.sh --repo $repo_path_q"
log_cmd="mkdir -p $controller_log_q; latest=''; for candidate in $controller_log_q/tick-*.log; do [ -e \"\$candidate\" ] || continue; latest=\"\$candidate\"; done; printf 'Project: $repo_slug\nRepo: $repo_path\n\n'; if [ -n \"\$latest\" ]; then printf '(showing only lines mentioning this repo; waiting for the first one)\\n'; tail -f \"\$latest\" | grep --line-buffered -F $repo_path_q; else printf 'No tick log yet in $controller_home/log\n'; exec \"\${SHELL:-/bin/sh}\"; fi"
ticker_cmd="cd $autometta_root_q && scripts/agent-ticker.sh $repo_path_q"
fleet_cmd="cd $autometta_root_q && scripts/attach.sh --fleet-ticker"

report_orphans

if "$dry_run"; then
  printf 'tmux session: %s\nrepo: %s\n' "$session_name" "$repo_path"
  if [[ "$repo_slug" == autometta ]]; then printf 'default window: fleet (%s)\nsecond window: repo\n' "$fleet_cmd"; fi
  printf 'status pane: %s\nlog pane: %s\nticker pane: %s\n' "$status_cmd" "$log_cmd" "$ticker_cmd"
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
    tmux new-session -d -s "$session_name" -n fleet "$fleet_cmd"
    tmux new-window -d -t "$session_name" -n repo "$status_cmd"
    tmux split-window -h -t "$session_name":repo "$log_cmd"
    tmux split-window -v -t "$session_name":repo.1 "$ticker_cmd"
    tmux select-window -t "$session_name":fleet
  else
    tmux new-session -d -s "$session_name" "$status_cmd"
    tmux split-window -h -t "$session_name" "$log_cmd"
    tmux split-window -v -t "$session_name":0.1 "$ticker_cmd"
    tmux select-pane -t "$session_name":0.0
  fi
  printf 'PASS tmux viewer created %s\n' "$session_name"
elif "$ensure_only"; then
  printf 'PASS tmux viewer exists %s\n' "$session_name"
fi

"$ensure_only" && exit 0
tmux attach-session -t "$session_name"
