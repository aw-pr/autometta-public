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

# Trailing args are forwarded to jq, so callers can pass values with --arg /
# --argjson rather than interpolating them into the filter.
budget_write_atomic() {
  local repo_root="$1"
  local jq_filter="$2"
  shift 2
  local budget_path tmp_path
  budget_path="$(budget_file "$repo_root")"
  tmp_path="${budget_path}.tmp.$$"
  jq "$@" "$jq_filter" "$budget_path" > "$tmp_path"
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
#
# BUDGET_CHECK_ALL_HITS carries *every* cap that was over on this read, as a
# space-separated list in the same priority order. halt_reason keeps the
# first hit for backward compatibility, but the loop must record all of them:
# emergence-lab-gpu halted on 2026-08-16 with clock_ticks_used 470 against a
# clock_tick_cap of 400 and the file said only "token-cap", because the token
# comparison came first and the function returned before reaching the tick
# one. A breach that is never named is a breach nobody fixes.
BUDGET_CHECK_LAST_HIT=""
BUDGET_CHECK_ALL_HITS=""

budget_check_caps() {
  local repo_root="$1"
  local budget_path
  budget_path="$(budget_file "$repo_root")"

  BUDGET_CHECK_LAST_HIT=""
  BUDGET_CHECK_ALL_HITS=""

  local halted token_hit wall_hit tick_hit fail_hit
  halted="$(jq -r '.halted // false' "$budget_path")"

  if [[ "$halted" == "true" ]]; then
    return 2
  fi

  token_hit="$(jq -r '.tokens_spent >= .token_cap_total' "$budget_path")"
  wall_hit="$(jq -r '.wall_clock_elapsed_seconds >= .wall_clock_cap_seconds' "$budget_path")"
  tick_hit="$(jq -r '.clock_ticks_used >= .clock_tick_cap' "$budget_path")"
  fail_hit="$(jq -r '.consecutive_failures >= .consecutive_failure_cap' "$budget_path")"

  local hits=""
  [[ "$token_hit" == "true" ]] && hits="${hits}token-cap "
  [[ "$wall_hit"  == "true" ]] && hits="${hits}wall-clock-cap "
  [[ "$tick_hit"  == "true" ]] && hits="${hits}tick-cap "
  [[ "$fail_hit"  == "true" ]] && hits="${hits}failure-cap "
  hits="${hits% }"

  if [[ -n "$hits" ]]; then
    BUDGET_CHECK_ALL_HITS="$hits"
    BUDGET_CHECK_LAST_HIT="${hits%% *}"
    return 1
  fi

  return 0
}

# budget_gate_dispatch: the cap check that guards a spawn, as opposed to the
# one that guards a tick. Call it immediately before every worker or verifier
# dispatch.
#
# The distinction is the whole fix. budget_check_caps used to be consulted
# once, at the top of _process_repo_locked, and one tick can then reap a
# finished agent (charging its tokens via budget_account_tokens_from_log) and
# go on to dispatch the next role without ever looking at the budget again.
# On emergence-lab-gpu a single dispatch averaged 4.8M tokens against a
# 1,000,000 token cap and 18 of 31 dispatches individually exceeded the whole
# cap, so a budget consulted only between ticks could never bind.
#
# Returns 0 to allow the dispatch, 1 to refuse it. On a fresh cap hit it
# halts the repo before returning, so the caller only has to not dispatch.
# Fails closed: any unexpected return code from budget_check_caps refuses.
budget_gate_dispatch() {
  local repo_root="$1"
  local what="${2:-dispatch}"
  local rc=0
  budget_check_caps "$repo_root" || rc=$?
  case "$rc" in
    0)
      return 0
      ;;
    2)
      local existing
      existing="$(jq -r '.halt_reason // "unknown"' "$(budget_file "$repo_root")")"
      printf 'budget_gate_dispatch: refusing %s for %s (already halted: %s)\n' \
        "$what" "$repo_root" "$existing" >&2
      return 1
      ;;
    1)
      budget_halt "$repo_root" "$BUDGET_CHECK_LAST_HIT"
      printf 'budget_gate_dispatch: refusing %s for %s, halted on %s\n' \
        "$what" "$repo_root" "${BUDGET_CHECK_ALL_HITS:-$BUDGET_CHECK_LAST_HIT}" >&2
      return 1
      ;;
    *)
      printf 'budget_gate_dispatch: refusing %s for %s, budget_check_caps returned %s\n' \
        "$what" "$repo_root" "$rc" >&2
      return 1
      ;;
  esac
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

# budget_ensure_window: auto-reset a halted-or-at-cap budget at the start
# of a new run window (a UTC calendar day). If state/budget.json's
# window_started_at is not today, all counters (including
# consecutive_failures) are zeroed, halted/halt_reason/halted_at are
# cleared, caps are left untouched, and window_started_at is stamped to
# today. A log line is emitted only when a reset actually recovers a
# halted-or-at-cap budget, so a routine no-op day is silent.
#
# Within the same window this is a no-op: a halt or cap hit still holds for
# the rest of the window, and consecutive_failures keeps accumulating and
# can still halt the loop mid-window via budget_check_caps.
budget_ensure_window() {
  local repo_root="$1"
  local budget_path today stored
  budget_path="$(budget_file "$repo_root")"
  today="$(date -u +%F)"
  stored="$(jq -r '.window_started_at // empty' "$budget_path")"
  if [[ "$stored" == "$today" ]]; then
    return 0
  fi
  local recovered
  recovered="$(jq -r '
    (.halted == true)
    or (.tokens_spent >= .token_cap_total)
    or (.wall_clock_elapsed_seconds >= .wall_clock_cap_seconds)
    or (.clock_ticks_used >= .clock_tick_cap)
    or (.consecutive_failures >= .consecutive_failure_cap)
  ' "$budget_path")"

  # Preserve the evidence before the counters that carry it are zeroed. The
  # reset is legitimate -- a new day must be able to resume a repo that
  # halted for a real reason -- but it must not be the thing that destroys
  # the only record of how far the previous window overran. Recorded first
  # so a crash between here and the write leaves the breach on disk rather
  # than a clean-looking budget.
  if [[ "$recovered" == "true" ]]; then
    local over
    over="$(jq -r '
      [ (if .tokens_spent >= .token_cap_total then "token-cap" else empty end),
        (if .wall_clock_elapsed_seconds >= .wall_clock_cap_seconds then "wall-clock-cap" else empty end),
        (if .clock_ticks_used >= .clock_tick_cap then "tick-cap" else empty end),
        (if .consecutive_failures >= .consecutive_failure_cap then "failure-cap" else empty end)
      ] | join(" ")
    ' "$budget_path")"
    budget_record_breach "$repo_root" "window-reset" "$over"
  fi

  local tmp_path jq_filter
  tmp_path="${budget_path}.tmp.$$"
  if [[ "$recovered" == "true" ]]; then
    # Halted or at cap: this is the window boundary the reset exists for.
    jq_filter='
      .tokens_spent = 0
      | .wall_clock_elapsed_seconds = 0
      | .clock_ticks_used = 0
      | .consecutive_failures = 0
      | .halted = false
      | .halt_reason = null
      | .halt_reasons = null
      | .halted_at = null
      | .window_started_at = $today
    '
  else
    # Healthy budget crossing a window boundary mid-run: just stamp the
    # window, do not zero live counters out from under an in-progress run.
    jq_filter='.window_started_at = $today'
  fi
  jq --arg today "$today" "$jq_filter" "$budget_path" > "$tmp_path"
  json_check "$tmp_path"
  mv "$tmp_path" "$budget_path"
  if [[ "$recovered" == "true" ]]; then
    printf 'budget_ensure_window: new window (%s) for %s, auto-resetting halted/at-cap budget (caps unchanged); breach carried over: %s, lifetime tokens %s\n' \
      "$today" "$repo_root" "${over:-none}" \
      "$(jq -r '.lifetime_tokens_spent // 0' "$budget_path")" >&2
  fi
}

# How many breach records state/budget.json keeps. Bounded so the file does
# not grow without limit on a long-lived repo; the oldest are dropped first.
BUDGET_BREACH_RETAIN="${BUDGET_BREACH_RETAIN:-50}"

# budget_record_breach: append one immutable record of a cap breach to
# .breaches, capturing the counters and the caps as they stood.
#
# This exists because the counters that prove a breach do not survive.
# budget_ensure_window zeroes tokens_spent, clock_ticks_used and
# consecutive_failures at a UTC day boundary and clears halted with it, so by
# the morning after a 149x overrun state/budget.json reads like a healthy
# repo and the only trace is one stderr line in a rotated tick log. The
# breach record and lifetime_tokens_spent are what the operator still has.
#
# Args: repo_root, cleared_by (halt|window-reset), reasons (space-separated).
budget_record_breach() {
  local repo_root="$1"
  local cleared_by="$2"
  local reasons="${3:-}"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  budget_write_atomic "$repo_root" '
    .breaches = (((.breaches // []) + [{
        at: $ts,
        cleared_by: $cleared_by,
        reasons: ($reasons | split(" ") | map(select(. != ""))),
        window_started_at: .window_started_at,
        tokens_spent: .tokens_spent,
        token_cap_total: .token_cap_total,
        wall_clock_elapsed_seconds: .wall_clock_elapsed_seconds,
        wall_clock_cap_seconds: .wall_clock_cap_seconds,
        clock_ticks_used: .clock_ticks_used,
        clock_tick_cap: .clock_tick_cap,
        consecutive_failures: .consecutive_failures,
        consecutive_failure_cap: .consecutive_failure_cap
      }]) | .[-($retain | tonumber):])
  ' --arg ts "$ts" --arg cleared_by "$cleared_by" --arg reasons "$reasons" \
    --arg retain "$BUDGET_BREACH_RETAIN"
}

# budget_halt: latch the repo. reason is the first cap hit (kept as
# halt_reason for backward compatibility); halt_reasons carries every cap
# that was over. Only a cap halt records a breach -- an operational halt
# (yq-missing, state-corrupt, operator-pause) is not a budget breach.
#
# BUDGET_CHECK_ALL_HITS is only trusted when it agrees with reason, so a
# stale value left by an earlier check cannot be attached to an unrelated
# halt.
budget_halt() {
  local repo_root="$1"
  local reason="$2"
  local reasons="${3:-}"
  if [[ -z "$reasons" ]]; then
    if [[ "${BUDGET_CHECK_ALL_HITS:-}" == "$reason" || "${BUDGET_CHECK_ALL_HITS:-}" == "$reason "* ]]; then
      reasons="$BUDGET_CHECK_ALL_HITS"
    else
      reasons="$reason"
    fi
  fi
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  budget_write_atomic "$repo_root" '
    .halted = true
    | .halt_reason = $reason
    | .halt_reasons = ($reasons | split(" ") | map(select(. != "")))
    | .halted_at = $ts
  ' --arg reason "$reason" --arg reasons "$reasons" --arg ts "$ts"
  case "$reason" in
    token-cap|wall-clock-cap|tick-cap|failure-cap)
      budget_record_breach "$repo_root" "halt" "$reasons"
      ;;
  esac
}

# budget_add_tokens: increment .tokens_spent by an integer count.
# Non-numeric input is rejected silently (logs a warning, returns 0) so that
# a failed parse upstream is never fatal to the tick loop.
#
# .lifetime_tokens_spent is incremented in the same write and is never reset
# by anything, including budget_ensure_window. tokens_spent answers "how much
# of this window's cap is left"; lifetime_tokens_spent answers "what has this
# repo actually cost", which is the question nobody could answer for
# emergence-lab-gpu on the morning after.
budget_add_tokens() {
  local repo_root="$1"
  local tokens="$2"
  if [[ ! "$tokens" =~ ^[0-9]+$ ]]; then
    printf 'budget_add_tokens: rejecting non-numeric token count %q\n' "$tokens" >&2
    return 0
  fi
  budget_write_atomic "$repo_root" '
    .tokens_spent += ($n | tonumber)
    | .lifetime_tokens_spent = ((.lifetime_tokens_spent // 0) + ($n | tonumber))
  ' --arg n "$tokens"
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
