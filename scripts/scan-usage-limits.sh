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

repo_root="${1:?usage: scan-usage-limits.sh <repo-root> [max-age-hours]}"
max_age_hours="${2:-24}"
logs_dir="$repo_root/state/logs"

[[ -d "$logs_dir" ]] || exit 0

pattern='usage[ _-]limit|rate[ _-]limit|limit reached|too many requests|overloaded_error|quota exceeded|credit balance|insufficient credit|at capacity|HTTP 429|status 429|"code": *429'

while IFS= read -r log_path; do
  [[ -n "$log_path" ]] || continue
  first_hit="$(grep -m1 -iE "$pattern" "$log_path" 2>/dev/null || true)"
  [[ -n "$first_hit" ]] || continue
  printf '%s\t%s\n' "$log_path" "$first_hit"
done < <(find "$logs_dir" -name '*.log' -mmin "-$((max_age_hours * 60))" 2>/dev/null | sort -r)
