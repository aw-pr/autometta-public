#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# failures-history.sh: the failures history as a command, not a pane
# (card 63). scripts/repo-ticker.sh's live view carries only the SPEND AND
# LOSS summary (today, today's loss, 7d loss, cap); the itemised list of
# every non-pass dispatch and every terminal-status stage lives here,
# on-demand, so it stops competing for space in a bounded pane. Card 66
# extends the same command to cover the fleet, so the fleet page's live view
# can drop FAILURES entirely rather than fork a second itemised list.
#
# Args: (<repo_root> | --fleet) [--json]
#
# Per-repo mode reads the same one walker the ticker does
# (`aggregate-dashboard.sh --repo`); fleet mode reads the fleet-wide walker
# (`aggregate-dashboard.sh`, no --repo), so no path ever disagrees with the
# live pane it reports for.

if [[ $# -lt 1 || $# -gt 2 ]]; then
  printf 'usage: %s (<repo_root> | --fleet) [--json]\n' "$(basename "$0")" >&2
  exit 1
fi

target="$1"
json_out=false
if [[ "${2:-}" == "--json" ]]; then
  json_out=true
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./alert-statuses.sh
. "$script_dir/alert-statuses.sh"
alert_statuses_json="$(alert_stage_statuses_json)"

is_fleet=false
[[ "$target" != --fleet ]] || is_fleet=true

if "$is_fleet"; then
  # shellcheck source=resolve-root.sh
  . "$script_dir/resolve-root.sh"
  controller_home="$(autometta_controller_home)"
  data_path="$controller_home/dashboard/data.json"
  "$script_dir/aggregate-dashboard.sh" >/dev/null || {
    printf 'failures-history: the fleet aggregator failed\n' >&2
    exit 1
  }
  payload="$(jq -c --argjson statuses "$alert_statuses_json" '{
    name:"fleet", repo_path:null,
    stage_failures: [.repos[]? | select(.enabled) as $r | $r.stages[]? |
      select(.status as $s | $statuses | index($s)) |
      {repo:$r.name, id, status, verifier_attempts, wip_branch, wip_commit, stall_marker,
       event_at:(.completed_at // .started_at)}],
    dispatch_failures: (.spend.failures // [])
  }' "$data_path")"
else
  payload="$("$script_dir/aggregate-dashboard.sh" --repo "$target" 2>/dev/null)" || {
    printf 'failures-history: %s is not an enabled subscriber, or the aggregator failed\n' "$target" >&2
    exit 1
  }
  payload="$(printf '%s' "$payload" | jq -c --argjson statuses "$alert_statuses_json" '{
    name, repo_path,
    stage_failures: [.stages[]? | select(.status as $s | $statuses | index($s)) |
      {id, status, verifier_attempts, wip_branch, wip_commit, stall_marker, event_at:(.completed_at // .started_at)}],
    dispatch_failures: (.spend.failures // [])
  }')"
fi

if "$json_out"; then
  printf '%s\n' "$payload"
  exit 0
fi

if "$is_fleet"; then
  printf 'Failures history: fleet\n\n'
else
  name="$(printf '%s' "$payload" | jq -r '.name')"
  printf 'Failures history: %s (%s)\n\n' "$name" "$target"
fi

# Fleet mode carries a leading repo column throughout; per-repo mode omits it,
# since the header line above already names the one repo every row is about.
repo_field=''; repo_fmt=''
"$is_fleet" && { repo_field='.repo,'; repo_fmt='%-24s '; }

printf 'STAGE FAILURES (terminal: %s)\n' "$(printf '%s' "$alert_statuses_json" | jq -r 'join(", ")')"
stage_rows="$(printf '%s' "$payload" | jq -r "
  .stage_failures[]? | [$repo_field .id, .status, (.verifier_attempts // 0), (.wip_branch // \"-\"), (.event_at // \"-\")] | @tsv")"
if [[ -z "$stage_rows" ]]; then
  printf '  (none)\n'
elif "$is_fleet"; then
  printf '%s\n' "$stage_rows" | while IFS=$'\t' read -r repo id status attempts wip at; do
    printf "  ${repo_fmt}%-40s %-16s attempts:%-3s wip:%-50s %s\n" "$repo" "$id" "$status" "$attempts" "$wip" "$at"
  done
else
  printf '%s\n' "$stage_rows" | while IFS=$'\t' read -r id status attempts wip at; do
    printf '  %-40s %-16s attempts:%-3s wip:%-50s %s\n' "$id" "$status" "$attempts" "$wip" "$at"
  done
fi

printf '\nDISPATCH FAILURES (non-pass, last 6 days, tokens lost)\n'
dispatch_rows="$(printf '%s' "$payload" | jq -r "
  .dispatch_failures[]? | [$repo_field .ts, .stage_id, .role, .result, .tokens_lost, .cost_usd_est] | @tsv")"
if [[ -z "$dispatch_rows" ]]; then
  printf '  (none)\n'
elif "$is_fleet"; then
  printf '%s\n' "$dispatch_rows" | while IFS=$'\t' read -r repo ts stage_id role result tokens_lost cost; do
    printf "  ${repo_fmt}%-21s %-34s %-9s %-9s tokens:%-10s \$%.2f\n" "$repo" "$ts" "$stage_id" "$role" "$result" "$tokens_lost" "$cost"
  done
else
  printf '%s\n' "$dispatch_rows" | while IFS=$'\t' read -r ts stage_id role result tokens_lost cost; do
    printf '  %-21s %-34s %-9s %-9s tokens:%-10s $%.2f\n' "$ts" "$stage_id" "$role" "$result" "$tokens_lost" "$cost"
  done
fi

lost_sum="$(printf '%s' "$payload" | jq -r '[.dispatch_failures[]?.tokens_lost] | add // 0')"
printf '\nTotal tokens lost (6d): %s\n' "$lost_sum"
