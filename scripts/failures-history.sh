#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# failures-history.sh: the failures history as a command, not a pane
# (card 63). scripts/repo-ticker.sh's live view carries only the SPEND AND
# LOSS summary (today, today's loss, 7d loss, cap); the itemised list of
# every non-pass dispatch and every terminal-status stage lives here,
# on-demand, so it stops competing for space in a bounded pane.
#
# Args: <repo_root> [--json]
#
# Reads the same one walker the ticker does (`aggregate-dashboard.sh
# --repo`), so the two never disagree about a figure.

if [[ $# -lt 1 || $# -gt 2 ]]; then
  printf 'usage: %s <repo_root> [--json]\n' "$(basename "$0")" >&2
  exit 1
fi

repo_root="$1"
json_out=false
if [[ "${2:-}" == "--json" ]]; then
  json_out=true
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./alert-statuses.sh
. "$script_dir/alert-statuses.sh"
alert_statuses_json="$(alert_stage_statuses_json)"

payload="$("$script_dir/aggregate-dashboard.sh" --repo "$repo_root" 2>/dev/null)" || {
  printf 'failures-history: %s is not an enabled subscriber, or the aggregator failed\n' "$repo_root" >&2
  exit 1
}

if "$json_out"; then
  printf '%s\n' "$payload" | jq -c --argjson statuses "$alert_statuses_json" '{
    name, repo_path,
    stage_failures: [.stages[]? | select(.status as $s | $statuses | index($s)) |
      {id, status, verifier_attempts, wip_branch, wip_commit, stall_marker, event_at:(.completed_at // .started_at)}],
    dispatch_failures: (.spend.failures // [])
  }'
  exit 0
fi

name="$(printf '%s' "$payload" | jq -r '.name')"
printf 'Failures history: %s (%s)\n\n' "$name" "$repo_root"

printf 'STAGE FAILURES (terminal: %s)\n' "$(printf '%s' "$alert_statuses_json" | jq -r 'join(", ")')"
stage_rows="$(printf '%s' "$payload" | jq -r --argjson statuses "$alert_statuses_json" '
  [.stages[]? | select(.status as $s | $statuses | index($s))] as $rows |
  if ($rows | length) == 0 then empty
  else $rows[] | [.id, .status, (.verifier_attempts // 0), (.wip_branch // "-"), (.completed_at // .started_at // "-")] | @tsv
  end')"
if [[ -z "$stage_rows" ]]; then
  printf '  (none)\n'
else
  printf '%s\n' "$stage_rows" | while IFS=$'\t' read -r id status attempts wip at; do
    printf '  %-40s %-16s attempts:%-3s wip:%-50s %s\n' "$id" "$status" "$attempts" "$wip" "$at"
  done
fi

printf '\nDISPATCH FAILURES (non-pass, last 6 days, tokens lost)\n'
dispatch_rows="$(printf '%s' "$payload" | jq -r '.spend.failures[]? | [.ts, .stage_id, .role, .result, .tokens_lost, .cost_usd_est] | @tsv')"
if [[ -z "$dispatch_rows" ]]; then
  printf '  (none)\n'
else
  printf '%s\n' "$dispatch_rows" | while IFS=$'\t' read -r ts stage_id role result tokens_lost cost; do
    printf '  %-21s %-34s %-9s %-9s tokens:%-10s $%.2f\n' "$ts" "$stage_id" "$role" "$result" "$tokens_lost" "$cost"
  done
fi

lost_sum="$(printf '%s' "$payload" | jq -r '[.spend.failures[]?.tokens_lost] | add // 0')"
printf '\nTotal tokens lost (6d): %s\n' "$lost_sum"
