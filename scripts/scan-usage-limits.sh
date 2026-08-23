#!/usr/bin/env bash
# scan-usage-limits.sh — report-only scan of a subscriber repo's agent logs
# for provider limit errors the tick loop cannot see: subscription usage
# limits, rate limits, overload, and exhausted credit. A worker that hits
# one of these keeps its PID alive while its log goes quiet, so nothing in
# the reap path notices; this surfaces the evidence for the dashboard and
# for a manual-dispatch orchestrator deciding whether to switch workers.
#
# Usage: scan-usage-limits.sh <repo-root> [max-age-hours]
# Output: one "<log-path>\t<first matching line>" per affected log, newest
# first. Empty output and exit 0 when nothing matched (or no logs exist).
set -euo pipefail
IFS=$'\n\t'

_sul_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./usage-limit.sh
source "$_sul_script_dir/usage-limit.sh"

repo_root="${1:?usage: scan-usage-limits.sh <repo-root> [max-age-hours]}"
max_age_hours="${2:-24}"
logs_dir="$repo_root/state/logs"

[[ -d "$logs_dir" ]] || exit 0

while IFS= read -r log_path; do
  [[ -n "$log_path" ]] || continue
  log_name="$(basename "$log_path")"
  completion_signal=""
  case "$log_name" in
    *-worker.log)
      stage_id="${log_name%-worker.log}"
      completion_signal="$repo_root/state/handoffs/${stage_id}.json"
      ;;
    *-verifier.log|*-verifier.attempt-*.log)
      stage_id="${log_name%%-verifier*}"
      completion_signal="$repo_root/state/verifiers/${stage_id}.json"
      ;;
  esac
  first_hit="$(usage_limit_hit "$log_path" "$completion_signal" || true)"
  [[ -n "$first_hit" ]] || continue
  printf '%s\t%s\n' "$log_path" "$first_hit"
done < <(find "$logs_dir" -name '*.log' -mmin "-$((max_age_hours * 60))" 2>/dev/null | sort -r)
