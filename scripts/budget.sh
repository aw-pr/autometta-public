#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

json_check() {
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1"
}

budget_file() {
  printf '%s/state/budget.json\n' "$1"
}

budget_read() {
  local repo_root="$1"
  local budget_path
  budget_path="$(budget_file "$repo_root")"
  jq '.' "$budget_path"
}

budget_write_atomic() {
  local repo_root="$1"
  local jq_filter="$2"
  local budget_path tmp_path
  budget_path="$(budget_file "$repo_root")"
  tmp_path="${budget_path}.tmp.$$"
  jq "$jq_filter" "$budget_path" > "$tmp_path"
  json_check "$tmp_path"
  mv "$tmp_path" "$budget_path"
}

# budget_check_caps: inspect the per-repo budget.json and decide whether
# the tick loop should proceed.
#
# Return codes:
#   0 — no halt condition; caller may proceed.
#   1 — a real cap was hit on this read. The specific cap name is written
#       to the global BUDGET_CHECK_LAST_HIT (one of: token-cap,
#       wall-clock-cap, tick-cap, failure-cap). The caller is expected to
#       pass that value to budget_halt as the halt_reason.
#   2 — the repo was already halted before this call. halt_reason is
#       preserved verbatim in budget.json; the caller MUST NOT call
#       budget_halt again or it will overwrite the original reason.
#
# BUDGET_CHECK_LAST_HIT is only meaningful when the function returned 1.
BUDGET_CHECK_LAST_HIT=""

budget_check_caps() {
  local repo_root="$1"
  local budget_path
  budget_path="$(budget_file "$repo_root")"

  BUDGET_CHECK_LAST_HIT=""

  local halted token_hit wall_hit tick_hit fail_hit
  halted="$(jq -r '.halted // false' "$budget_path")"

  if [[ "$halted" == "true" ]]; then
    return 2
  fi

  token_hit="$(jq -r '.tokens_spent >= .token_cap_total' "$budget_path")"
  wall_hit="$(jq -r '.wall_clock_elapsed_seconds >= .wall_clock_cap_seconds' "$budget_path")"
  tick_hit="$(jq -r '.clock_ticks_used >= .clock_tick_cap' "$budget_path")"
  fail_hit="$(jq -r '.consecutive_failures >= .consecutive_failure_cap' "$budget_path")"

  if [[ "$token_hit" == "true" ]]; then
    BUDGET_CHECK_LAST_HIT="token-cap"
    return 1
  fi
  if [[ "$wall_hit" == "true" ]]; then
    BUDGET_CHECK_LAST_HIT="wall-clock-cap"
    return 1
  fi
  if [[ "$tick_hit" == "true" ]]; then
    BUDGET_CHECK_LAST_HIT="tick-cap"
    return 1
  fi
  if [[ "$fail_hit" == "true" ]]; then
    BUDGET_CHECK_LAST_HIT="failure-cap"
    return 1
  fi

  return 0
}

budget_increment_tick() {
  local repo_root="$1"
  budget_write_atomic "$repo_root" '.clock_ticks_used += 1'
}

budget_record_failure() {
  local repo_root="$1"
  budget_write_atomic "$repo_root" '.consecutive_failures += 1'
}

budget_reset_failures() {
  local repo_root="$1"
  budget_write_atomic "$repo_root" '.consecutive_failures = 0'
}

budget_halt() {
  local repo_root="$1"
  local reason="$2"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  budget_write_atomic "$repo_root" ".halted = true | .halt_reason = \"${reason}\" | .halted_at = \"${ts}\""
}

# budget_add_tokens: increment .tokens_spent by an integer count.
# Non-numeric input is rejected silently (logs a warning, returns 0) so that
# a failed parse upstream is never fatal to the tick loop.
budget_add_tokens() {
  local repo_root="$1"
  local tokens="$2"
  if [[ ! "$tokens" =~ ^[0-9]+$ ]]; then
    printf 'budget_add_tokens: rejecting non-numeric token count %q\n' "$tokens" >&2
    return 0
  fi
  budget_write_atomic "$repo_root" ".tokens_spent += ${tokens}"
}

# budget_parse_tokens_from_log: scan a worker/verifier log for token-usage
# lines and print the chosen integer to stdout (no trailing newline beyond
# printf default). Prints nothing and returns 0 on no match.
#
# Recognised formats:
#   Codex two-line: a line that is exactly "tokens used" (after trim),
#     followed by a line whose first whitespace-trimmed token is a number
#     (commas accepted): "117,339", "  142672", "117,339 prompt+output".
#   Claude inline:  any line containing "Total tokens:" followed by a
#     comma- or space-formatted integer run.
#
# Disambiguation: LAST-MATCH-WINS. If a worker retried or printed multiple
# usage lines, the most recent count is the authoritative one — earlier
# numbers are cumulative subtotals or aborted attempts.
#
# Pure awk; bash 3.2 compatible; no python / node.
budget_parse_tokens_from_log() {
  local log_path="$1"
  [[ -f "$log_path" ]] || return 0
  awk '
    function strip(s) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      return s
    }
    function digits_only(s,   out, i, c) {
      out = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c ~ /[0-9]/) out = out c
        else if (out != "" && c !~ /[0-9, ]/) break
      }
      return out
    }
    {
      line = strip($0)
    }
    pending_codex {
      n = digits_only(line)
      if (n ~ /^[0-9]+$/) last = n
      pending_codex = 0
      next
    }
    line == "tokens used" {
      pending_codex = 1
      next
    }
    /Total tokens:/ {
      tail = $0
      sub(/.*Total tokens:[[:space:]]*/, "", tail)
      n = digits_only(tail)
      if (n ~ /^[0-9]+$/) last = n
      next
    }
    END {
      if (last != "") print last
    }
  ' "$log_path"
}

# budget_account_tokens_from_log: parse the log and apply the result.
# Non-fatal: a missing log, missing match, or non-numeric parse logs a
# warning and returns 0 without touching budget.json.
budget_account_tokens_from_log() {
  local repo_root="$1"
  local log_path="$2"
  local label="${3:-log}"
  if [[ ! -f "$log_path" ]]; then
    printf 'budget_account_tokens_from_log: %s missing at %s, skipping\n' "$label" "$log_path" >&2
    return 0
  fi
  local tokens
  tokens="$(budget_parse_tokens_from_log "$log_path")"
  if [[ -z "$tokens" ]]; then
    printf 'budget_account_tokens_from_log: no token-usage line found in %s (%s)\n' "$log_path" "$label" >&2
    return 0
  fi
  budget_add_tokens "$repo_root" "$tokens"
  printf 'budget_account_tokens_from_log: recorded %s tokens from %s (%s)\n' "$tokens" "$log_path" "$label" >&2
}
