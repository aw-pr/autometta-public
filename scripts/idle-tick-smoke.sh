#!/usr/bin/env bash
# idle-tick-smoke.sh — offline check that the tick budget bounds work, not
# polling, and that --reset-halt actually recovers a capped repo.
#
# The defect this guards (card 37): budget_increment_tick was called on the
# unconditional fall-through at the end of every per-repo tick as well as on
# the early returns above it, so clock_ticks_used advanced whether or not an
# agent was dispatched. clock_tick_cap is documented -- in schemas/budget.json
# and in docs/phat-controller.md -- as the primary safety bounding work, but
# what it actually capped was elapsed polling. A repo with an empty queue
# reached its cap on a fixed schedule no matter what.
#
# Read at 2026-08-23T10:50Z, five of the six enabled subscribers were halted
# on tick-cap having spent zero tokens and zero wall-clock seconds.
# aegis-guardrails holds exactly one stage, that stage is completed, and it
# burned 400 ticks establishing there was nothing to dispatch. The window
# reset at midnight, the fleet spent the allowance through the small hours,
# and every subscriber was halted before the 22:00 window opened.
#
# Defect C, the same day: --reset-halt cleared .halted, .halt_reason and
# .halted_at and left clock_ticks_used at the cap that caused the halt, so all
# seven subscribers were back to halted/tick-cap inside one tick interval,
# still reading 400/400.
#
# Everything below runs against temporary budget files. No auth, no network,
# no live agent, no spend. It asserts:
#
#   1. A simulated full day of idle polling does not halt an empty-queue repo.
#   2. Work ticks still halt at the cap -- the cap is not decorative.
#   3. idle_tick_cap, when an operator sets one, does halt idle polling.
#   4. --reset-halt leaves a tick-capped repo able to tick again; the
#      assertion is on the counter, not the flag.
#   5. --reset-halt does not silently clear real spend, and says so.
#   6. health-check.sh fails on a second loaded launchd tick job and passes
#      on one.
#
# Exit 0 on all-pass, 1 on any assertion failure.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source=./budget.sh
source "$script_dir/budget.sh"

fail=0

check() {
  local desc="$1"
  local cond="$2"
  if [[ "$cond" == "ok" ]]; then
    printf '  PASS: %s\n' "$desc" >&2
  else
    printf '  FAIL: %s (%s)\n' "$desc" "$cond" >&2
    fail=1
  fi
}

eq() { [[ "$1" == "$2" ]] && printf 'ok\n' || printf 'expected %q, got %q\n' "$1" "$2"; }

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

# A subscriber budget with aegis-guardrails' caps: one stage, that stage
# completed, nothing to dispatch, 400 ticks a day available.
make_repo() {
  local name="$1"
  local dir="$tmp_root/$name"
  mkdir -p "$dir/state"
  cat > "$dir/state/budget.json" <<JSON
{
  "version": 1,
  "token_cap_total": 1000000,
  "tokens_spent": 0,
  "wall_clock_cap_seconds": 86400,
  "wall_clock_elapsed_seconds": 0,
  "clock_tick_cap": 400,
  "clock_ticks_used": 0,
  "consecutive_failure_cap": 3,
  "consecutive_failures": 0,
  "halted": false,
  "window_started_at": "$(date -u +%F)"
}
JSON
  printf '%s' "$dir"
}

b() { jq -r "$2" "$1/state/budget.json"; }

# One tick of the loop's budget bookkeeping, as _process_repo_locked performs
# it: check the caps, halt if any is over, otherwise charge the tick as the
# caller classified it.
simulate_tick() {
  local dir="$1" kind="$2" rc=0
  budget_check_caps "$dir" || rc=$?
  case "$rc" in
    0) budget_increment_tick "$dir" "$kind" ;;
    1) budget_halt "$dir" "$BUDGET_CHECK_LAST_HIT" ;;
    2) ;;
  esac
}

# ---------------------------------------------------------------------------
printf '== 1. a full day of idle polling against an empty queue ==\n' >&2

idle_dir="$(make_repo idle)"
# 288 fires a day at the fleet job's 300s interval, doubled to 576 to cover
# the duplicate-job rate the fleet was actually running at on 2026-08-23.
for _ in $(seq 1 576); do
  simulate_tick "$idle_dir" idle
done

printf '  after 576 idle ticks: halted=%s clock_ticks_used=%s idle_ticks_used=%s tokens_spent=%s\n' \
  "$(b "$idle_dir" .halted)" "$(b "$idle_dir" .clock_ticks_used)" \
  "$(b "$idle_dir" '.idle_ticks_used // 0')" "$(b "$idle_dir" .tokens_spent)" >&2

check "an empty-queue repo is not halted by a full day of polling" \
  "$(eq false "$(b "$idle_dir" .halted)")"
check "idle polling leaves halt_reason unset" \
  "$(eq null "$(b "$idle_dir" .halt_reason)")"
check "idle polling does not advance clock_ticks_used" \
  "$(eq 0 "$(b "$idle_dir" .clock_ticks_used)")"
check "idle polling is counted, in its own counter" \
  "$(eq 576 "$(b "$idle_dir" '.idle_ticks_used // 0')")"

# ---------------------------------------------------------------------------
printf '\n== 2. the other direction: work ticks still halt at the cap ==\n' >&2

work_dir="$(make_repo work)"
for _ in $(seq 1 576); do
  simulate_tick "$work_dir" work
done

printf '  after 576 work ticks: halted=%s reason=%s clock_ticks_used=%s/%s\n' \
  "$(b "$work_dir" .halted)" "$(b "$work_dir" .halt_reason)" \
  "$(b "$work_dir" .clock_ticks_used)" "$(b "$work_dir" .clock_tick_cap)" >&2

check "a working repo still halts" "$(eq true "$(b "$work_dir" .halted)")"
check "it halts on tick-cap" "$(eq tick-cap "$(b "$work_dir" .halt_reason)")"
check "it halts at the cap, not past it" \
  "$(eq 400 "$(b "$work_dir" .clock_ticks_used)")"
check "the halt records a breach" \
  "$(eq 1 "$(b "$work_dir" '[.breaches[]? | select(.cleared_by == "halt")] | length')")"

# ---------------------------------------------------------------------------
printf '\n== 3. an operator who does want a polling bound can set one ==\n' >&2

bounded_dir="$(make_repo bounded)"
jq '.idle_tick_cap = 50' "$bounded_dir/state/budget.json" > "$bounded_dir/b" \
  && mv "$bounded_dir/b" "$bounded_dir/state/budget.json"
for _ in $(seq 1 60); do
  simulate_tick "$bounded_dir" idle
done

check "idle_tick_cap halts idle polling when set" \
  "$(eq true "$(b "$bounded_dir" .halted)")"
check "and names itself distinctly from tick-cap" \
  "$(eq idle-tick-cap "$(b "$bounded_dir" .halt_reason)")"
check "an absent idle_tick_cap is the default" \
  "$(eq null "$(b "$idle_dir" '.idle_tick_cap // null')")"

# ---------------------------------------------------------------------------
printf '\n== 4. --reset-halt recovers a tick-capped repo ==\n' >&2

# work_dir is halted on tick-cap at 400/400, which is the state all seven
# subscribers were in when --reset-halt reported success and changed nothing.
budget_reset_halt "$work_dir" false >/dev/null

printf '  after --reset-halt: halted=%s clock_ticks_used=%s consecutive_failures=%s\n' \
  "$(b "$work_dir" .halted)" "$(b "$work_dir" .clock_ticks_used)" \
  "$(b "$work_dir" .consecutive_failures)" >&2

check "the flag is cleared" "$(eq false "$(b "$work_dir" .halted)")"
check "the counter that caused the halt is cleared" \
  "$(eq 0 "$(b "$work_dir" .clock_ticks_used)")"
check "consecutive_failures is cleared" \
  "$(eq 0 "$(b "$work_dir" .consecutive_failures)")"
check "the reset preserves the evidence it erased" \
  "$(eq 1 "$(b "$work_dir" '[.breaches[]? | select(.cleared_by == "reset-halt")] | length')")"

# The assertion that matters: it can tick again without immediately re-halting.
simulate_tick "$work_dir" work
check "the repo ticks again without re-halting" \
  "$(eq false "$(b "$work_dir" .halted)")"
check "and the tick counted" "$(eq 1 "$(b "$work_dir" .clock_ticks_used)")"

# ---------------------------------------------------------------------------
printf '\n== 5. --reset-halt will not clear real spend unasked ==\n' >&2

spend_dir="$(make_repo spend)"
jq '.tokens_spent = 5921327 | .token_cap_total = 1000000' \
  "$spend_dir/state/budget.json" > "$spend_dir/b" \
  && mv "$spend_dir/b" "$spend_dir/state/budget.json"
simulate_tick "$spend_dir" work
check "a token breach halts" "$(eq token-cap "$(b "$spend_dir" .halt_reason)")"

still_over="$(budget_reset_halt "$spend_dir" false)"
check "the default reset leaves tokens_spent alone" \
  "$(eq 5921327 "$(b "$spend_dir" .tokens_spent)")"
check "and reports what is still over cap" "$(eq token-cap "$still_over")"
check "and keeps the halt latched rather than unlatching a live breach" \
  "$(eq true "$(b "$spend_dir" .halted)")"
check "re-stamped to the cap that is actually still over" \
  "$(eq token-cap "$(b "$spend_dir" .halt_reason)")"

still_over="$(budget_reset_halt "$spend_dir" true)"
check "--reset-tokens clears it on explicit request" \
  "$(eq 0 "$(b "$spend_dir" .tokens_spent)")"
check "leaving nothing over cap" "$(eq "" "$still_over")"
check "and the halt finally clears" "$(eq false "$(b "$spend_dir" .halted)")"
check "lifetime spend survives every reset" \
  "$(eq 0 "$(b "$spend_dir" '.lifetime_tokens_spent // 0')")"

# ---------------------------------------------------------------------------
printf '\n== 6. health-check.sh enforces one fleet tick job ==\n' >&2

if command -v plutil >/dev/null 2>&1; then
  fake_dir="$tmp_root/LaunchAgents"
  mkdir -p "$fake_dir"
  write_plist() {
    cat > "$fake_dir/$1.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$1</string>
  <key>ProgramArguments</key>
  <array><string>/opt/homebrew/bin/autometta</string><string>tick</string></array>
</dict>
</plist>
PLIST
  }
  write_plist com.autometta.tick.fleet

  rc=0
  ( cd "$repo_root" && AUTOMETTA_LAUNCHD_DIRS="$fake_dir" \
      AUTOMETTA_LAUNCHD_LOADED_LABELS="com.autometta.tick.fleet" \
      scripts/health-check.sh >/dev/null 2>&1 ) || rc=$?
  check "one loaded tick job passes" "$(eq 0 "$rc")"

  # The 2026-08-19 duplicate: named for one repo, but its ProgramArguments are
  # the argument-free fleet tick, so it ticked every subscriber a second time.
  write_plist com.autometta.tick.emergence-lab-surface-v2
  rc=0
  ( cd "$repo_root" && AUTOMETTA_LAUNCHD_DIRS="$fake_dir" \
      AUTOMETTA_LAUNCHD_LOADED_LABELS="com.autometta.tick.fleet com.autometta.tick.emergence-lab-surface-v2" \
      scripts/health-check.sh >/dev/null 2>&1 ) || rc=$?
  check "a second loaded tick job fails the health check" "$(eq 1 "$rc")"

  # An unloaded copy sitting in LaunchAgents is inert, not a fault.
  rc=0
  ( cd "$repo_root" && AUTOMETTA_LAUNCHD_DIRS="$fake_dir" \
      AUTOMETTA_LAUNCHD_LOADED_LABELS="com.autometta.tick.fleet" \
      scripts/health-check.sh >/dev/null 2>&1 ) || rc=$?
  check "an unloaded duplicate plist is not a fault" "$(eq 0 "$rc")"
else
  printf '  SKIP: plutil unavailable\n' >&2
fi

printf '\n' >&2
if (( fail == 0 )); then
  printf 'idle-tick-smoke: all assertions passed\n' >&2
  exit 0
fi
printf 'idle-tick-smoke: FAILURES above\n' >&2
exit 1
