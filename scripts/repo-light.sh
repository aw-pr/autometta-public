#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

repo_light_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./alert-statuses.sh
source "$repo_light_script_dir/alert-statuses.sh"

# repo_light <repo-json> [now-epoch]
# Prints: green|amber|red<TAB>reason. Rules are evaluated in severity order;
# within a severity, the first rule in the dashboard contract wins.
repo_light() {
  local repo_json="$1"
  local now="${2:-$(date -u +%s)}"
  local fresh_hours="${FLEET_FRESH_FAILURE_HOURS:-24}"
  local alert_statuses
  alert_statuses="$(alert_stage_statuses_json)"

  # The row arrives on stdin, not in argv. A subscriber with a few thousand
  # cost-log rows builds a payload past ARG_MAX, and --argjson made that an
  # "Argument list too long" from jq: the caller's read then set an empty
  # light and an empty reason, so the repo's traffic light went blank on the
  # one repo busy enough to need it. printf is a builtin and a pipe has no
  # such limit.
  printf '%s' "$repo_json" | jq -nr \
    --argjson now "$now" \
    --argjson fresh_hours "$fresh_hours" \
    --argjson alert_statuses "$alert_statuses" '
    input as $repo |
    def epoch:
      if . == null or . == "" then 0
      elif type == "number" then .
      else try fromdateiso8601 catch 0 end;
    def failure_stages:
      [$repo.stages[]? |
        select(.status as $s | $alert_statuses | index($s)) |
        . + {event_epoch: ((.event_at // .completed_at // .started_at) | epoch)}];
    def recent_provider:
      any($repo.alerts[]?;
        ((.occurred_at | epoch) > 0) and
        ($now - (.occurred_at | epoch) < 86400));
    def agent_flag($flag):
      any($repo.agents[]?; any(.flags[]?; . == $flag));
    def answer($light; $reason): [$light, $reason] | @tsv;
    (failure_stages) as $failures |
    if ($repo.halted // false) then
      answer("red"; "budget halted")
    elif (($repo.consecutive_failure_cap // 0) > 0 and
          ($repo.consecutive_failures // 0) >= ($repo.consecutive_failure_cap // 0)) then
      answer("red"; "consecutive failure cap reached")
    elif agent_flag("over-budget") then
      answer("red"; "agent over budget")
    elif any($failures[]?;
          .event_epoch > 0 and
          ($now - .event_epoch) < ($fresh_hours * 3600)) then
      answer("red"; "fresh terminal failure")
    elif ($repo.state_error // null) != null then
      answer("red"; "state unreadable")
    elif (($repo.consecutive_failures // 0) > 0) then
      answer("amber"; "consecutive failures")
    elif recent_provider then
      answer("amber"; "recent provider limit")
    elif (($repo.token_cap_total // 0) > 0 and
          (($repo.tokens_spent // 0) / $repo.token_cap_total) >= 0.85) then
      answer("amber"; "85% of token cap")
    elif any($failures[]?;
          .event_epoch == 0 or
          ($now - .event_epoch) >= ($fresh_hours * 3600)) then
      answer("amber"; "historic terminal failure")
    elif ($repo.drain_active // false) then
      answer("amber"; "drain active")
    elif (($repo.in_flight // 0) > 0 and
          (($repo.heartbeat_checked_at | epoch) == 0 or
           ($now - ($repo.heartbeat_checked_at | epoch)) > 600)) then
      answer("amber"; "heartbeat stale with work in flight")
    else
      answer("green"; "no dashboard rule fired")
    end
  '
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ $# -ne 1 || ! -f "$1" ]]; then
    printf 'usage: %s <data.json>\n' "$(basename "$0")" >&2
    exit 2
  fi
  while IFS= read -r repo_json; do
    name="$(printf '%s' "$repo_json" | jq -r '.name // "unknown"')"
    printf '%s\t%s\n' "$name" "$(repo_light "$repo_json")"
  done < <(jq -c '.repos[]?' "$1")
fi
