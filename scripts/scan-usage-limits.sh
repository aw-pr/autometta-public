#!/usr/bin/env bash
# scan-usage-limits.sh — report-only scan of a subscriber repo's agent logs
# for provider limit errors the tick loop cannot see: subscription usage
# limits, rate limits, overload, and exhausted credit. A worker that hits
# one of these keeps its PID alive while its log goes quiet, so nothing in
# the reap path notices; this surfaces the evidence for the dashboard and
# for a manual-dispatch orchestrator deciding whether to switch workers.
#
# Usage: scan-usage-limits.sh <repo-root> [max-age-hours]
# Output: one "<log-path>\t<first matching line>\t<mtime>" per affected log,
# newest first. Empty output and exit 0 when nothing matched (or no logs exist).
set -euo pipefail
IFS=$'\n\t'

# Dashboard scanning is stricter than the tick's deliberately broad refusal
# detector. These are line-anchored CLI/API banners, not prose containing the
# words "rate limit" or "usage limit".
PROVIDER_LIMIT_BANNER_PATTERN="^[[:space:]]*(You've hit your (session|usage) limit|You have [0-9]+ weighted tokens left|Error:.*(rate limit|usage limit|quota exceeded|credit balance|too many requests|at capacity)|.*(overloaded_error|rate_limit_exceeded|insufficient_quota)|HTTP[/ ]*[0-9.]* 429|status( code)?:? 429)"

provider_banner_hit() {
  local log_path="$1" completion_signal="$2" hit
  [[ -f "$log_path" ]] || return 1
  [[ -z "$completion_signal" || ! -f "$completion_signal" ]] || return 1
  hit="$(grep -iE "$PROVIDER_LIMIT_BANNER_PATTERN" "$log_path" 2>/dev/null | head -n1 || true)"
  [[ -n "$hit" ]] || return 1
  printf '%s\n' "$hit"
}

file_mtime_iso() {
  python3 - "$1" <<'PY'
import datetime as dt
import os
import sys

stamp = dt.datetime.fromtimestamp(os.path.getmtime(sys.argv[1]), dt.timezone.utc)
print(stamp.strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
}

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
  first_hit="$(provider_banner_hit "$log_path" "$completion_signal" || true)"
  [[ -n "$first_hit" ]] || continue
  printf '%s\t%s\t%s\n' "$log_path" "$first_hit" "$(file_mtime_iso "$log_path")"
done < <(find "$logs_dir" -name '*.log' -mmin "-$((max_age_hours * 60))" 2>/dev/null | sort -r)
