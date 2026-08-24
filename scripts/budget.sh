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

# ---------------------------------------------------------------------------
# Token-cap resolution
#
# The daily token cap is a host decision, not a per-repo accident. Five
# subscribers carried 3,000,000 / 8,000,000 / 100,000,000 / 150,000,000
# between them and nothing recorded why any of them held its number; the
# spread was accumulated history. So a repo's own token_cap_total is now
# optional, and the cap that actually binds is resolved in this order, first
# hit wins:
#
#   1. an active drain      $PHAT_CONTROLLER_HOME/drain.json, while unexpired
#   2. the repo's own cap   state/budget.json .token_cap_total, when present
#   3. the host default     token_cap_total: in the controller config.yaml
#   4. the floor            $AUTOMETTA_TOKEN_CAP_FLOOR
#
# Rule 4 is why there is no unlimited resting state. A repo with no cap of
# its own, on a host whose config predates this card, still gets a number;
# the floor is deliberately small enough to be noticed rather than large
# enough to be harmless.
#
# Only the drain can raise a cap above the resting one, and a drain expires
# by itself (see budget_drain_active).
AUTOMETTA_TOKEN_CAP_FLOOR="${AUTOMETTA_TOKEN_CAP_FLOOR:-20000000}"

# The ceiling a --lift drain resolves to. "Lifted" still has to be an
# integer: every cap comparison in this file is a jq numeric test, and a null
# cap would make `tokens_spent >= null` the thing standing between a runaway
# and the provider. A billion tokens is above any provider window a single
# overnight run can reach, so it lifts the local cap in practice while
# leaving the arithmetic total.
AUTOMETTA_DRAIN_LIFT_CAP="${AUTOMETTA_DRAIN_LIFT_CAP:-1000000000}"

# Longest drain the operator may ask for, in seconds. A drain that outlives
# the night it was opened for is just an unlimited cap with extra steps.
AUTOMETTA_DRAIN_MAX_SECONDS="${AUTOMETTA_DRAIN_MAX_SECONDS:-43200}"

budget_controller_home() {
  printf '%s' "${PHAT_CONTROLLER_HOME:-$HOME/.phat-controller}"
}

budget_drain_file() {
  printf '%s/drain.json' "$(budget_controller_home)"
}

_budget_is_positive_int() {
  [[ "${1:-}" =~ ^[0-9]+$ && "${1:-0}" -gt 0 ]]
}

# _budget_host_cap_declared: the host default exactly as declared, empty when
# the host has not declared one. Split out from budget_host_token_cap so
# budget_cap_source can tell "the host said 20,000,000" from "nobody said
# anything and this is the floor".
_budget_host_cap_declared() {
  local value=""
  if [[ -n "${AUTOMETTA_HOST_TOKEN_CAP:-}" ]]; then
    value="$AUTOMETTA_HOST_TOKEN_CAP"
  else
    local config_file
    config_file="$(budget_controller_home)/config.yaml"
    if [[ -f "$config_file" ]]; then
      value="$(sed -n 's/^token_cap_total:[[:space:]]*//p' "$config_file" | head -n 1)"
      value="${value%%#*}"
      value="${value//[\"\'\ \	]/}"
    fi
  fi
  printf '%s' "$value"
}

# budget_host_token_cap: the host default, or the floor when the host has no
# opinion. Always prints a positive integer.
budget_host_token_cap() {
  local value
  value="$(_budget_host_cap_declared)"
  if _budget_is_positive_int "$value"; then
    printf '%s' "$value"
  else
    printf '%s' "$AUTOMETTA_TOKEN_CAP_FLOOR"
  fi
}

# budget_drain_active <repo-root>: succeed (0) when a drain is in force for
# this repo, printing the cap it grants. Fails (1) and prints nothing
# otherwise.
#
# Expiry is enforced on read rather than by anything that has to remember to
# run: the first caller past expires_at moves drain.json aside to
# drain.expired.json and reports no drain. That is the whole reason a drain
# cannot silently become the permanent setting -- there is no path where the
# file keeps binding after its own clock.
budget_drain_active() {
  local repo_root="${1:-}"
  local drain_path
  drain_path="$(budget_drain_file)"
  [[ -f "$drain_path" ]] || return 1
  local expires
  expires="$(jq -r '.expires_at // empty' "$drain_path" 2>/dev/null || true)"
  if ! [[ "$expires" =~ ^[0-9]+$ ]]; then
    printf 'budget_drain_active: %s has no usable expires_at, ignoring it\n' "$drain_path" >&2
    return 1
  fi
  local now
  now="$(date -u +%s)"
  if (( now >= expires )); then
    mv "$drain_path" "${drain_path%.json}.expired.json" 2>/dev/null || rm -f "$drain_path"
    printf 'budget_drain_active: drain expired at %s, cap back to the resting value\n' \
      "$(date -r "$expires" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || printf '%s' "$expires")" >&2
    return 1
  fi
  # An empty or absent repos[] means every subscriber; a populated one is an
  # allow-list of absolute repo paths.
  local scoped
  scoped="$(jq -r --arg repo "$repo_root" '
    if ((.repos // []) | length) == 0 then "all"
    elif ((.repos // []) | index($repo)) != null then "listed"
    else "excluded" end
  ' "$drain_path" 2>/dev/null || printf 'excluded')"
  [[ "$scoped" == "excluded" ]] && return 1
  local cap
  cap="$(jq -r '.token_cap_total // empty' "$drain_path" 2>/dev/null || true)"
  if ! _budget_is_positive_int "$cap"; then
    printf 'budget_drain_active: %s has no usable token_cap_total, ignoring it\n' "$drain_path" >&2
    return 1
  fi
  printf '%s' "$cap"
  return 0
}

# budget_effective_token_cap <repo-root>: the cap that actually binds, as a
# positive integer. Every token comparison in this file goes through it, so
# there is one resolution order rather than one per call site.
budget_effective_token_cap() {
  local repo_root="$1"
  local drain_cap
  if drain_cap="$(budget_drain_active "$repo_root" 2>/dev/null)" && [[ -n "$drain_cap" ]]; then
    printf '%s' "$drain_cap"
    return 0
  fi
  local budget_path own=""
  budget_path="$(budget_file "$repo_root")"
  if [[ -f "$budget_path" ]]; then
    own="$(jq -r '.token_cap_total // empty' "$budget_path" 2>/dev/null || true)"
  fi
  if _budget_is_positive_int "$own"; then
    printf '%s' "$own"
    return 0
  fi
  budget_host_token_cap
}

# budget_cap_source <repo-root>: which rule won, for the log and the
# dashboard. Never branches anything.
budget_cap_source() {
  local repo_root="$1"
  if budget_drain_active "$repo_root" >/dev/null 2>&1; then
    printf 'drain'
    return 0
  fi
  local own="" budget_path
  budget_path="$(budget_file "$repo_root")"
  if [[ -f "$budget_path" ]]; then
    own="$(jq -r '.token_cap_total // empty' "$budget_path" 2>/dev/null || true)"
  fi
  if _budget_is_positive_int "$own"; then
    printf 'repo'
  elif _budget_is_positive_int "$(_budget_host_cap_declared)"; then
    printf 'host-default'
  else
    printf 'floor'
  fi
}

# budget_check_caps: inspect the per-repo budget.json and decide whether
# the tick loop should proceed.
#
# Return codes:
#   0 — no halt condition; caller may proceed.
#   1 — a real cap was hit on this read. The specific cap name is written
#       to the global BUDGET_CHECK_LAST_HIT (one of: token-cap,
#       wall-clock-cap, tick-cap, idle-tick-cap, failure-cap). The caller is
#       expected to pass that value to budget_halt as the halt_reason.
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

  local halted token_hit wall_hit tick_hit idle_hit fail_hit token_cap
  halted="$(jq -r '.halted // false' "$budget_path")"

  if [[ "$halted" == "true" ]]; then
    return 2
  fi

  # The cap that binds is resolved, not read: a repo may carry no cap of its
  # own and inherit the host default, and a drain may be raising it tonight.
  token_cap="$(budget_effective_token_cap "$repo_root")"
  token_hit="$(jq -r --argjson cap "$token_cap" '.tokens_spent >= $cap' "$budget_path")"
  wall_hit="$(jq -r '.wall_clock_elapsed_seconds >= .wall_clock_cap_seconds' "$budget_path")"
  tick_hit="$(jq -r '.clock_ticks_used >= .clock_tick_cap' "$budget_path")"
  # idle_tick_cap is absent by default and an absent cap never binds: an idle
  # repo must be able to sit through a whole window without halting. Written
  # with an explicit null test because jq compares null against a number
  # rather than erroring, and `null >= null` is true.
  idle_hit="$(jq -r '(.idle_tick_cap // null) != null and ((.idle_ticks_used // 0) >= .idle_tick_cap)' "$budget_path")"
  fail_hit="$(jq -r '.consecutive_failures >= .consecutive_failure_cap' "$budget_path")"

  local hits=""
  [[ "$token_hit" == "true" ]] && hits="${hits}token-cap "
  [[ "$wall_hit"  == "true" ]] && hits="${hits}wall-clock-cap "
  [[ "$tick_hit"  == "true" ]] && hits="${hits}tick-cap "
  [[ "$idle_hit"  == "true" ]] && hits="${hits}idle-tick-cap "
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

# budget_spend_caps_blown: print the space-separated names of every spend cap
# currently exhausted, or nothing when the repo has budget left. Empty output
# is the "safe to dispatch" answer.
#
# Deliberately excludes failure-cap. The three caps here bound spend, and no
# operator action short of raising a cap or waiting for the window can make
# them true again; consecutive_failures is a judgement about whether the work
# is going anywhere, and re-queueing is exactly the operator saying it is.
# scripts/requeue-stage.sh refuses to unlatch a halt while this is non-empty,
# and tick.sh --repair skips such a repo entirely rather than spending repair
# attempts on stages that cannot dispatch.
budget_spend_caps_blown() {
  local repo_root="$1"
  local budget_path
  budget_path="$(budget_file "$repo_root")"
  [[ -f "$budget_path" ]] || return 0
  jq -r --argjson cap "$(budget_effective_token_cap "$repo_root")" '
    [ (if .tokens_spent >= $cap then "token-cap" else empty end),
      (if .wall_clock_elapsed_seconds >= .wall_clock_cap_seconds then "wall-clock-cap" else empty end),
      (if .clock_ticks_used >= .clock_tick_cap then "tick-cap" else empty end)
    ] | join(" ")
  ' "$budget_path"
}

# budget_should_log_halt: dedupe the "still halted" tick log line.
#
# A halted repo is re-read on every tick and the log line that says so used
# to be emitted every time, forever. A whole month of ~/.phat-controller/log
# can be one repeated sentence, which buries every line that was worth
# reading. Returns 0 (log it) the first time a given reason is seen, on any
# change of reason, and again once PHAT_CONTROLLER_HALT_LOG_INTERVAL seconds
# (default 3600) have elapsed since the last emission for that same reason.
# Returns 1 to suppress. Stamps halt_logged_at/halt_logged_reason on every
# rc-0 return.
#
# This decides what is written to the log and nothing else. It never clears a
# halt: budget_ensure_window is the single mechanism that does that.
budget_should_log_halt() {
  local repo_root="$1"
  local reason="$2"
  local budget_path
  budget_path="$(budget_file "$repo_root")"
  [[ -f "$budget_path" ]] || return 0

  local interval="${PHAT_CONTROLLER_HALT_LOG_INTERVAL:-3600}"
  local last_epoch last_reason now_epoch
  last_epoch="$(jq -r '.halt_logged_at // empty' "$budget_path")"
  last_reason="$(jq -r '.halt_logged_reason // empty' "$budget_path")"
  now_epoch="$(date -u +%s)"

  if [[ -n "$last_epoch" && "$last_reason" == "$reason" && "$last_epoch" =~ ^[0-9]+$ ]]; then
    if (( now_epoch - last_epoch < interval )); then
      return 1
    fi
  fi

  budget_write_atomic "$repo_root" \
    '.halt_logged_at = ($now | tonumber) | .halt_logged_reason = $reason' \
    --arg now "$now_epoch" --arg reason "$reason"
  return 0
}

# budget_increment_tick: charge one tick against the repo, as either work or
# idle polling. kind is "work" (the default) or "idle".
#
# The split is the whole of card 37. schemas/budget.json has always described
# clock_ticks_used as "ticks that have done work on this repo", but the
# counter was advanced on the unconditional fall-through at the end of the
# per-repo tick as well as on the early returns above it, so it advanced
# whether or not an agent was dispatched. A repo with an empty queue then
# reached clock_tick_cap on a fixed schedule no matter what: on 2026-08-23
# five of six enabled subscribers were halted on tick-cap having spent zero
# tokens and zero wall-clock seconds, and aegis-guardrails -- which holds one
# stage, and that stage is completed -- burned 400 ticks establishing there
# was nothing to dispatch. The window then reset at midnight, the fleet spent
# the allowance through the small hours, and every subscriber was halted
# before the evening window opened. A cap whose only reachable effect is to
# halt an idle repo converts "nothing to do" into "cannot work when there
# is".
#
# idle_ticks_used is an odometer, not a cap: it answers "how much of this
# window went on polling nothing" without halting anything. It binds only if
# the operator sets idle_tick_cap, which is absent by default.
#
# Unknown kinds charge as work. Fail-safe rather than fail-open: a caller
# added later that forgets to classify itself is bounded, not unbounded.
budget_increment_tick() {
  local repo_root="$1"
  local kind="${2:-work}"
  case "$kind" in
    idle)
      budget_write_atomic "$repo_root" '.idle_ticks_used = ((.idle_ticks_used // 0) + 1)'
      ;;
    work)
      budget_write_atomic "$repo_root" '.clock_ticks_used += 1'
      ;;
    *)
      printf 'budget_increment_tick: unknown kind %q for %s, charging as work\n' \
        "$kind" "$repo_root" >&2
      budget_write_atomic "$repo_root" '.clock_ticks_used += 1'
      ;;
  esac
}

# budget_status_is_failure: does this terminal stage status count against the
# consecutive-failure cap? Everything terminal does except superseded, which
# records an operator decision that the card should not run. Counting a
# decision as a failure walks the fleet toward a halt for work nobody wanted
# done; on 2026-08-23 three retired emergence-lab cards did exactly that,
# because failed was the only terminal status available.
budget_status_is_failure() {
  case "${1:-}" in
    superseded) return 1 ;;
    *) return 0 ;;
  esac
}

# budget_record_failure <repo-root> [stage-status]
#
# The optional status lets a caller that is finalising a stage say which
# status it is recording. A non-failure terminal status (superseded) is a
# no-op: no increment, so it can never contribute to a failure-cap halt.
# Omitting it keeps the old behaviour for every caller that is recording a
# genuine casualty.
budget_record_failure() {
  local repo_root="$1" stage_status="${2:-}"
  if [ -n "$stage_status" ] && ! budget_status_is_failure "$stage_status"; then
    return 0
  fi
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
  local recovered token_cap
  token_cap="$(budget_effective_token_cap "$repo_root")"
  recovered="$(jq -r --argjson cap "$token_cap" '
    (.halted == true)
    or (.tokens_spent >= $cap)
    or (.wall_clock_elapsed_seconds >= .wall_clock_cap_seconds)
    or (.clock_ticks_used >= .clock_tick_cap)
    or ((.idle_tick_cap // null) != null and (.idle_ticks_used // 0) >= .idle_tick_cap)
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
    over="$(jq -r --argjson cap "$token_cap" '
      [ (if .tokens_spent >= $cap then "token-cap" else empty end),
        (if .wall_clock_elapsed_seconds >= .wall_clock_cap_seconds then "wall-clock-cap" else empty end),
        (if .clock_ticks_used >= .clock_tick_cap then "tick-cap" else empty end),
        (if (.idle_tick_cap // null) != null and (.idle_ticks_used // 0) >= .idle_tick_cap then "idle-tick-cap" else empty end),
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
      | .idle_ticks_used = 0
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

# budget_pause_until: suspend dispatch until an epoch second, because the
# provider refused for a limit reason rather than because anything failed.
#
# Distinct from budget_halt on purpose. A halt is terminal for the window and
# means a cap was breached; a pause means the work has not been attempted yet
# and the loop should pick it up by itself once the window resets. Nothing
# about the stage is marked bad, no failure is recorded, and no cap moves.
budget_pause_until() {
  local repo_root="$1"
  local until_epoch="$2"
  local reason="${3:-provider limit}"
  if [[ ! "$until_epoch" =~ ^[0-9]+$ ]]; then
    printf 'budget_pause_until: rejecting non-numeric epoch %q\n' "$until_epoch" >&2
    return 0
  fi
  budget_write_atomic "$repo_root" \
    ".paused_until = ${until_epoch} | .paused_reason = $(printf '%s' "$reason" | jq -Rs .)"
}

# budget_pause_active: succeed (0) when dispatch is currently suspended.
# Clears an elapsed pause on the way past so the loop self-heals without an
# operator, and prints nothing either way.
budget_pause_active() {
  local repo_root="$1"
  local budget_path paused now
  budget_path="$(budget_file "$repo_root")"
  paused="$(jq -r '.paused_until // empty' "$budget_path")"
  [[ -n "$paused" && "$paused" =~ ^[0-9]+$ ]] || return 1
  now="$(date -u +%s)"
  if (( now < paused )); then
    return 0
  fi
  budget_write_atomic "$repo_root" '.paused_until = null | .paused_reason = null'
  printf 'budget_pause_active: pause elapsed, resuming dispatch for %s\n' "$repo_root" >&2
  return 1
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
        token_cap_total: $cap,
        wall_clock_elapsed_seconds: .wall_clock_elapsed_seconds,
        wall_clock_cap_seconds: .wall_clock_cap_seconds,
        clock_ticks_used: .clock_ticks_used,
        clock_tick_cap: .clock_tick_cap,
        idle_ticks_used: (.idle_ticks_used // 0),
        idle_tick_cap: .idle_tick_cap,
        consecutive_failures: .consecutive_failures,
        consecutive_failure_cap: .consecutive_failure_cap
      }]) | .[-($retain | tonumber):])
  ' --arg ts "$ts" --arg cleared_by "$cleared_by" --arg reasons "$reasons" \
    --arg retain "$BUDGET_BREACH_RETAIN" \
    --argjson cap "$(budget_effective_token_cap "$repo_root")"
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
    | .halt_logged_at = null
    | .halt_logged_reason = null
  ' --arg reason "$reason" --arg reasons "$reasons" --arg ts "$ts"
  case "$reason" in
    token-cap|wall-clock-cap|tick-cap|idle-tick-cap|failure-cap)
      budget_record_breach "$repo_root" "halt" "$reasons"
      ;;
  esac
}

# budget_reset_halt: the operator's recovery command, as opposed to the
# window boundary's automatic one.
#
# It must clear the counters that cause a halt, not merely the flag. Before
# card 37 it wrote only `.halted = false | .halt_reason = null | .halted_at =
# null`, leaving clock_ticks_used at the cap that triggered the halt, so
# budget_check_caps re-halted the repo on the very next tick. Observed on
# 2026-08-23: a --reset-halt run reported "reset halt state" for all seven
# subscribers and all seven were back to halted with halt_reason tick-cap
# inside one tick interval, still reading 400/400. A recovery command that
# leaves the machine in the state it was rescued from is worse than none,
# because it reports success.
#
# tokens_spent is the one counter it will not clear by default: a polling
# artefact can be zeroed freely, but real spend against a real cap is the
# operator's decision to make explicitly. Pass reset_tokens="true" for that.
# While a spend cap is still over the halt stays latched and is re-stamped to
# the cap that is actually still breached, so the reset never briefly unlatches
# the only safety in the design. Prints the caps still over, empty when none
# are, so the caller can say so rather than let the operator discover it a tick
# later.
#
# The breach record is written first, for the same reason budget_ensure_window
# writes one: the counters that prove the breach are exactly the ones about to
# be zeroed.
budget_reset_halt() {
  local repo_root="$1"
  local reset_tokens="${2:-false}"
  local budget_path
  budget_path="$(budget_file "$repo_root")"

  local over token_cap
  token_cap="$(budget_effective_token_cap "$repo_root")"
  over="$(jq -r --argjson cap "$token_cap" '
    [ (if .tokens_spent >= $cap then "token-cap" else empty end),
      (if .wall_clock_elapsed_seconds >= .wall_clock_cap_seconds then "wall-clock-cap" else empty end),
      (if .clock_ticks_used >= .clock_tick_cap then "tick-cap" else empty end),
      (if (.idle_tick_cap // null) != null and (.idle_ticks_used // 0) >= .idle_tick_cap then "idle-tick-cap" else empty end),
      (if .consecutive_failures >= .consecutive_failure_cap then "failure-cap" else empty end)
    ] | join(" ")
  ' "$budget_path")"
  if [[ -n "$over" ]]; then
    budget_record_breach "$repo_root" "reset-halt" "$over"
  fi

  local token_clause=""
  if [[ "$reset_tokens" == "true" ]]; then
    token_clause=' | .tokens_spent = 0 | .wall_clock_elapsed_seconds = 0'
  fi
  budget_write_atomic "$repo_root" "
    .clock_ticks_used = 0
    | .idle_ticks_used = 0
    | .consecutive_failures = 0${token_clause}
  "

  # What is still over once the polling counters are gone. Only spend can be,
  # because everything else was just zeroed.
  local remaining
  remaining="$(jq -r --argjson cap "$token_cap" '
    [ (if .tokens_spent >= $cap then "token-cap" else empty end),
      (if .wall_clock_elapsed_seconds >= .wall_clock_cap_seconds then "wall-clock-cap" else empty end)
    ] | join(" ")
  ' "$budget_path")"

  if [[ -z "$remaining" ]]; then
    budget_write_atomic "$repo_root" \
      '.halted = false | .halt_reason = null | .halt_reasons = null | .halted_at = null'
  else
    # The halt stays latched, re-stamped to the cap that is actually still
    # over, so the flag never contradicts the counters. Unlatching a live
    # spend breach is not a recovery, it is manufacturing budget -- the same
    # line requeue-stage.sh draws.
    budget_write_atomic "$repo_root" '
      .halted = true
      | .halt_reason = ($reasons | split(" ") | .[0])
      | .halt_reasons = ($reasons | split(" ") | map(select(. != "")))
    ' --arg reasons "$remaining"
  fi

  printf '%s' "$remaining"
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

# budget_transcript_dir: map a dispatch working directory to the Claude Code
# transcript directory for that cwd. Claude Code slugifies the absolute path
# by replacing every non-alphanumeric character with '-'.
budget_transcript_dir() {
  local work_dir="$1"
  [[ -n "$work_dir" ]] || return 0
  local slug
  slug="$(printf '%s' "$work_dir" | LC_ALL=C tr -c 'A-Za-z0-9' '-')"
  printf '%s/.claude/projects/%s\n' "$HOME" "$slug"
}

# budget_parse_tokens_from_transcript: recover real token usage for a
# claude-family dispatch from its Claude Code transcript.
#
# `claude -p --output-format json` emits its usage object only on a clean
# exit, so a role killed at the dispatch timeout books zero tokens: the most
# expensive failure mode was the one that billed nothing, and no value of
# token_cap_total could ever fire. The transcript JSONL is appended per turn
# and survives the kill, so it is the ground truth for the claude family.
#
# Prints "INPUT CACHED OUTPUT" where INPUT folds cache creation in, matching
# costlog_parse_breakdown's triple. Prints nothing when no usage is found.
# Entries are deduplicated on requestId (a resumed or forked session repeats
# earlier turns verbatim) and filtered to those at or after since_epoch so a
# reused worktree does not re-bill a previous stage's spend.
budget_parse_tokens_from_transcript() {
  local work_dir="$1"
  local since_epoch="${2:-0}"
  local dir
  dir="$(budget_transcript_dir "$work_dir")"
  [[ -n "$dir" && -d "$dir" ]] || return 0
  python3 - "$dir" "$since_epoch" <<'PY'
import datetime as dt
import json
import os
import sys

root, since_raw = sys.argv[1], sys.argv[2]
try:
    since = int(since_raw)
except ValueError:
    since = 0

seen = set()
inp = cached = out = 0

for base, _dirs, files in os.walk(root):
    for name in files:
        if not name.endswith(".jsonl"):
            continue
        path = os.path.join(base, name)
        try:
            fh = open(path, encoding="utf-8", errors="replace")
        except OSError:
            continue
        with fh:
            for line in fh:
                if '"usage"' not in line:
                    continue
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                msg = rec.get("message") or {}
                usage = msg.get("usage") or {}
                if not usage:
                    continue
                ts = rec.get("timestamp")
                if ts and since:
                    try:
                        when = dt.datetime.fromisoformat(ts.replace("Z", "+00:00"))
                    except ValueError:
                        when = None
                    if when is not None and when.timestamp() < since:
                        continue
                key = rec.get("requestId") or msg.get("id")
                if key is not None:
                    if key in seen:
                        continue
                    seen.add(key)
                inp += usage.get("input_tokens", 0) or 0
                inp += usage.get("cache_creation_input_tokens", 0) or 0
                cached += usage.get("cache_read_input_tokens", 0) or 0
                out += usage.get("output_tokens", 0) or 0

if inp or cached or out:
    print(f"{inp} {cached} {out}")
PY
}

# budget_account_tokens_from_dispatch: account a finished role's spend,
# preferring the transcript and falling back to the log parser.
#
# work_dir/since_epoch are optional; without them (or for a codex-family
# role, which writes no Claude transcript) this degrades exactly to
# budget_account_tokens_from_log. Non-fatal throughout.
budget_account_tokens_from_dispatch() {
  local repo_root="$1"
  local log_path="$2"
  local label="${3:-log}"
  local work_dir="${4:-}"
  local since_epoch="${5:-0}"

  local triple=""
  if [[ -n "$work_dir" ]]; then
    triple="$(budget_parse_tokens_from_transcript "$work_dir" "$since_epoch")"
  fi
  if [[ -z "$triple" ]]; then
    budget_account_tokens_from_log "$repo_root" "$log_path" "$label"
    return 0
  fi

  local t_in t_cached t_out total
  IFS=' ' read -r t_in t_cached t_out <<<"$triple"
  total=$(( t_in + t_cached + t_out ))
  budget_add_tokens "$repo_root" "$total"
  printf 'budget_account_tokens_from_dispatch: recorded %s tokens (in=%s cached=%s out=%s) from transcript for %s (%s)\n' \
    "$total" "$t_in" "$t_cached" "$t_out" "$work_dir" "$label" >&2
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
