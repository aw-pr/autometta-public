#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
controller_home="${PHAT_CONTROLLER_HOME:-$HOME/.phat-controller}"
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

render_fleet_once() {
  local data_path="$controller_home/dashboard/data.json"
  local stale_seconds="${PHAT_CONTROLLER_FLEET_STALE_SECONDS:-600}"
  printf 'autometta %s fleet: %s\n\n' "$build_sha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ ! -s "$data_path" ]] || ! jq -e '.generated_at and (.repos | type == "array")' "$data_path" >/dev/null 2>&1; then
    printf 'FLEET DATA MISSING\n  Run `autometta dashboard`; an empty fleet is not assumed healthy.\n'
    return 0
  fi

  local now generated_epoch age
  now="$(date -u +%s)"
  generated_epoch="$(jq -r 'try (.generated_at | fromdateiso8601) catch 0' "$data_path")"
  age=$(( now - generated_epoch ))
  local generated_at
  generated_at="$(jq -r '.generated_at' "$data_path")"
  printf 'Data generated: %s (%ss ago)\n' "$generated_at" "$age"
  if (( generated_epoch == 0 || age > stale_seconds )); then
    printf 'FLEET DATA STALE: generated %ss ago (limit %ss)\n' "$age" "$stale_seconds"
    printf '  The scheduled refresh is not running; stale data is not rendered as healthy.\n'
  fi
  printf '\n'

  printf 'TOTALS\n'
  local totals
  totals="$(jq -r '
    (.fleet_totals // {}) as $t |
    [($t.enabled_repos // ([.repos[] | select(.enabled)] | length)),
     ($t.today_tokens // 0), ($t.today_cost_usd_est // 0),
     ($t.window_tokens_spent // 0), ($t.window_token_cap_total // 0)] | @tsv
  ' "$data_path")"
  local total_enabled total_today_tokens total_today_cost total_window_spent total_window_cap
  IFS=$'\t' read -r total_enabled total_today_tokens total_today_cost total_window_spent total_window_cap <<<"$totals"
  printf '  enabled: %s  today: %s tokens / $%.2f est  window: %s / %s tokens\n' \
    "$total_enabled" "$total_today_tokens" "$total_today_cost" "$total_window_spent" "$total_window_cap"
  printf '\nREPOS\n'
  printf '  %-26s %-8s %-22s %-9s %-18s %-16s %s\n' \
    'subscriber' 'enabled' 'state' 'queue' 'today' 'window' 'last dispatch'
  jq -r --argjson now "$now" '
    def short_tokens:
      if . >= 1000000000 then (((. / 100000000 | round) / 10 | tostring) + "B")
      elif . >= 1000000 then (((. / 100000 | round) / 10 | tostring) + "M")
      elif . >= 1000 then (((. / 100 | round) / 10 | tostring) + "K")
      else tostring end;
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
      (.today_tokens // 0 | short_tokens), (.today_cost_usd_est // 0),
      ((.tokens_spent // 0 | short_tokens) + "/" + (.token_cap_total // 0 | short_tokens)),
      ((.last_dispatch_at // "") | age) ] | @tsv' "$data_path" |
    while IFS=$'\t' read -r name enabled state queue today_tokens today_cost window last_dispatch; do
      printf '  %-26s %-8s %-22s %-9s %7s/$%-9.2f %-16s %s\n' \
        "$name" "$enabled" "$state" "$queue" "$today_tokens" "$today_cost" "$window" "$last_dispatch"
    done

  printf '\nALERTS (fleet union)\n'
  local alert_count
  local alert_statuses
  alert_statuses="$(alert_stage_statuses_json)"
  alert_count="$(jq --argjson alert_statuses "$alert_statuses" '[.repos[] | select(.enabled) |
    (if .halted then 1 else 0 end),
    (if (.consecutive_failures // 0) > 0 then 1 else 0 end),
    (if ((.queue_depth // 0) == 0 and (.in_flight // 0) == 0) then 1 else 0 end),
    ([.stages[]? | select(.status as $s | $alert_statuses | index($s))] | length),
    (.alerts[]? | 1)] | add // 0' "$data_path")"
  if [[ -n "$build_warning" ]]; then
    printf '  %s\n' "$build_warning"
  fi
  if (( alert_count == 0 )) && [[ -z "$build_warning" ]]; then
    printf '  (none)\n'
  else
    printf '  %-26s %-44s %-18s %s\n' 'repo' 'stage/card' 'kind' 'detail'
    jq -r --argjson alert_statuses "$alert_statuses" '
      def log_stage:
        (.log // "" | split("/")[-1]
         | sub("-(worker|verifier)(\\.attempt-[0-9]+)?\\.log$"; "")) as $id |
        if $id == "" then "repo" else $id end;
      [ .repos[] | select(.enabled) as $r |
        (if $r.halted then {repo:$r.name, subject:"repo", kind:"halt", detail:($r.halt_reason // "unknown")} else empty end),
        (if ($r.consecutive_failures // 0) > 0 then {repo:$r.name, subject:"repo", kind:"failures", detail:((($r.consecutive_failures | tostring) + "/" + ($r.consecutive_failure_cap | tostring)))} else empty end),
        (if (($r.queue_depth // 0) == 0 and ($r.in_flight // 0) == 0) then {repo:$r.name, subject:"repo", kind:"queue", detail:"empty"} else empty end),
        ($r.stages[]? | select(.status as $s | $alert_statuses | index($s)) | {repo:$r.name, subject:.id, kind:"stage", detail:.status}),
        ($r.alerts[]? | {repo:$r.name, subject:log_stage, kind:"provider-limit", detail:(.line // tostring)})
      ] | sort_by(.repo, .subject, .kind, .detail)[] |
      [.repo, .subject, .kind, .detail] | @tsv' "$data_path" |
      while IFS=$'\t' read -r alert_repo alert_subject alert_kind alert_detail; do
        printf '  %-26s %-44s %-18s %s\n' \
          "$alert_repo" "$alert_subject" "$alert_kind" "$alert_detail"
      done
  fi

  local overlap
  overlap="$(jq -r '[.repos[] | select(.enabled and (.name | startswith("emergence-lab"))) | .name] | if length > 1 then join(", ") else empty end' "$data_path")"
  if [[ -n "$overlap" ]]; then
    printf '\nOVERLAP\n  emergence-lab subscribers enabled together: %s\n' "$overlap"
  fi
}

fleet_refresher() {
  local interval="${PHAT_CONTROLLER_FLEET_REFRESH_INTERVAL:-120}"
  local session="${PHAT_CONTROLLER_FLEET_SESSION:-}"
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
  local interval="${PHAT_CONTROLLER_STATUS_TICKER_INTERVAL:-5}"
  if [[ "${PHAT_CONTROLLER_FLEET_ONCE:-false}" == true ]]; then
    refresh_build_status
    render_fleet_once
    return 0
  fi
  trap 'exit 0' INT TERM
  while true; do
    refresh_build_status
    printf '\033[H'
    render_fleet_once
    printf '\nRefresh: %ss\033[J\n' "$interval"
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
  fleet_ticker
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
session_name_q="$(shell_quote "$session_name")"
fleet_refresh_cmd="cd $autometta_root_q && PHAT_CONTROLLER_FLEET_SESSION=$session_name_q scripts/attach.sh --fleet-refresh"

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
    tmux run-shell -b -t "$session_name" "$fleet_refresh_cmd"
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
