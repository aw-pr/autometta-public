#!/usr/bin/env bash
# budget-cap-smoke.sh — offline check that a spend cap actually stops dispatch.
#
# The defect this guards (card 31): budget_check_caps was consulted exactly
# once per tick, at the top of _process_repo_locked, and never again. A single
# tick then reaps a finished agent -- charging its tokens through
# budget_account_tokens_from_log -- and goes on to dispatch the next role
# against a budget read taken before that charge. Nothing in the dispatch path
# ever asked whether there was budget left.
#
# On emergence-lab-gpu (2026-08-15) that let 149,752,682 tokens through a
# token_cap_total of 1,000,000. The comparison was never wrong; it was in the
# wrong place. The mean dispatch cost 4,830,731 tokens and 18 of the 31
# dispatches individually exceeded the entire cap, so a budget consulted only
# between ticks could not bind however correct its arithmetic.
#
# Assertions run against temporary budget files, so nothing here needs auth,
# network, a live agent, or any spend. It asserts:
#
#   1. Replay of the real 2026-08-15 dispatch sequence halts at the cap.
#   2. Tokens charged mid-tick gate the dispatch that follows in that tick.
#   3. clock_ticks_used at clock_tick_cap halts with tick-cap, dispatches
#      nothing further, and is not masked by a simultaneous token breach.
#   4. A healthy repo under its caps still dispatches.
#   5. A window reset preserves the evidence of the breach it clears.
#   6. requeue-stage.sh refuses to unlatch a halt whose spend cap is blown.
#   7. A Codex transcript alone charges cached usage and blows the token cap.
#
# Exit 0 on all-pass, 1 on any assertion failure.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Cap resolution consults the live controller home (host default, drain
# mode), so an active drain on the real host would unblow every fixture
# cap here. Pin the controller home to an empty sandbox first.
PHAT_CONTROLLER_HOME="$(mktemp -d)"
export PHAT_CONTROLLER_HOME

# shellcheck source=./budget.sh
source "$script_dir/budget.sh"

fail=0

check() {
  local desc="$1"
  local cond="$2"
  if [[ "$cond" == "ok" ]]; then
    printf '  PASS: %s\n' "$desc" >&2
  else
    printf '  FAIL: %s\n' "$desc" >&2
    fail=1
  fi
}

eq() { [[ "$1" == "$2" ]] && printf 'ok\n' || printf 'no: expected %q, got %q\n' "$1" "$2"; }

# Against a pre-fix checkout budget.sh defines no budget_gate_dispatch,
# because pre-fix nothing consulted the budget at the point of spend. Stand in
# the pre-fix dispatch path -- which allowed every dispatch unconditionally --
# so the assertions below still run and report the behaviour rather than
# bailing out on a missing symbol. The numbers they print are then the
# incident's own.
if ! declare -F budget_gate_dispatch >/dev/null 2>&1; then
  printf 'NOTE: budget.sh defines no budget_gate_dispatch (pre-fix checkout).\n' >&2
  printf '      Standing in the pre-fix dispatch path: no check before a spawn.\n\n' >&2
  budget_gate_dispatch() { return 0; }
fi

# A budget file with the caps emergence-lab-gpu actually ran under.
# Reproduced from ~/.phat-controller/archive/emergence-lab-gpu-state-2026-08-16.tgz.
new_budget() {
  local dir="$1"; shift
  mkdir -p "$dir/state"
  jq -n '{
    version: 1,
    token_cap_total: 1000000,
    tokens_spent: 0,
    wall_clock_cap_seconds: 3600,
    wall_clock_elapsed_seconds: 0,
    clock_tick_cap: 400,
    clock_ticks_used: 0,
    consecutive_failure_cap: 3,
    consecutive_failures: 0,
    halted: false,
    halt_reason: null,
    halted_at: null,
    window_started_at: null
  }' > "$dir/state/budget.json"
}

# ---------------------------------------------------------------------------
printf '== 1. replay of the 2026-08-15 emergence-lab-gpu sequence ==\n' >&2

# The 31 dispatches of the 2026-08-15 window in chronological order, tokens
# per dispatch (input+output), taken verbatim from that repo's
# state/cost-log.jsonl. Their sum is 149,752,682 -- the tokens_spent the
# incident budget.json carried against a 1,000,000 cap.
RUNS_2026_08_15=(
  77124 5599240 174625 7585045 127189 18165943 125432 95050
  123321 13604309 97589 0 0 822144 6271544 104046 11184174
  8672912 9067935 2908625 4502728 2003714 894845 3738841 6343213
  936975 3924435 19019631 4845743 16699506 2036804
)

replay_dir="$(mktemp -d)"
new_budget "$replay_dir"

dispatched=0
for tokens in "${RUNS_2026_08_15[@]}"; do
  # The loop asks for permission before each dispatch, exactly as tick.sh now
  # does at both spawn sites.
  if ! budget_gate_dispatch "$replay_dir" "replay run" 2>/dev/null; then
    break
  fi
  dispatched=$((dispatched + 1))
  # The dispatch runs and its log is reaped, charging its tokens.
  budget_add_tokens "$replay_dir" "$tokens"
done

replay_spent="$(jq -r '.tokens_spent' "$replay_dir/state/budget.json")"
replay_halted="$(jq -r '.halted' "$replay_dir/state/budget.json")"
replay_reason="$(jq -r '.halt_reason' "$replay_dir/state/budget.json")"
actual_total=0
for tokens in "${RUNS_2026_08_15[@]}"; do actual_total=$((actual_total + tokens)); done

printf '  replayed: halted after %s of %s dispatches at %s tokens (cap 1000000)\n' \
  "$dispatched" "${#RUNS_2026_08_15[@]}" "$replay_spent" >&2
printf '  incident: ran all %s dispatches to %s tokens\n' \
  "${#RUNS_2026_08_15[@]}" "$actual_total" >&2

check "replay halts instead of draining the queue" "$(eq true "$replay_halted")"
check "replay halts on token-cap" "$(eq token-cap "$replay_reason")"
check "replay stops after 2 dispatches (was 31)" "$(eq 2 "$dispatched")"
check "replay stops at 5676364 tokens (was 149752682)" "$(eq 5676364 "$replay_spent")"
# The bound the design can offer: one dispatch's overshoot, no more. Run 2 was
# a 5,599,240-token verifier, so crossing the cap at all costs that much. What
# it must never do is keep going afterwards.
check "overshoot is bounded by the one dispatch that crossed the cap" \
  "$( [[ "$replay_spent" -le $((1000000 + 5599240)) ]] && printf 'ok\n' || printf 'no: %s\n' "$replay_spent" )"
rm -rf "$replay_dir"

# ---------------------------------------------------------------------------
printf '== 2. tokens charged mid-tick gate the next dispatch in that tick ==\n' >&2

mid_dir="$(mktemp -d)"
new_budget "$mid_dir"
jq '.tokens_spent = 900000' "$mid_dir/state/budget.json" > "$mid_dir/b" \
  && mv "$mid_dir/b" "$mid_dir/state/budget.json"

# Top of tick: under cap, so the tick proceeds. This is the only check the
# pre-fix code made.
top_rc=0; budget_check_caps "$mid_dir" || top_rc=$?
check "tick starts under cap" "$(eq 0 "$top_rc")"

# The tick reaps a finished worker and charges it. Now over cap.
budget_add_tokens "$mid_dir" 250000

# Pre-fix, the verifier spawn happened here with no further check.
gate_rc=0; budget_gate_dispatch "$mid_dir" "verifier" 2>/dev/null || gate_rc=$?
check "gate refuses the dispatch that follows the reap" "$(eq 1 "$gate_rc")"
check "gate latched the repo" "$(eq true "$(jq -r '.halted' "$mid_dir/state/budget.json")")"
check "gate recorded token-cap" "$(eq token-cap "$(jq -r '.halt_reason' "$mid_dir/state/budget.json")")"
rm -rf "$mid_dir"

# ---------------------------------------------------------------------------
printf '== 3. the tick cap gets its own answer ==\n' >&2

tick_dir="$(mktemp -d)"
new_budget "$tick_dir"
jq '.clock_ticks_used = 400' "$tick_dir/state/budget.json" > "$tick_dir/b" \
  && mv "$tick_dir/b" "$tick_dir/state/budget.json"

tick_rc=0; budget_gate_dispatch "$tick_dir" "worker" 2>/dev/null || tick_rc=$?
check "ticks at cap refuse dispatch" "$(eq 1 "$tick_rc")"
check "ticks at cap halt with tick-cap" "$(eq tick-cap "$(jq -r '.halt_reason' "$tick_dir/state/budget.json")")"

# A second attempt must stay refused rather than re-halting over the top of
# the recorded reason.
tick_rc2=0; budget_gate_dispatch "$tick_dir" "worker" 2>/dev/null || tick_rc2=$?
check "an already-halted repo stays refused" "$(eq 1 "$tick_rc2")"
check "the original halt reason is preserved" \
  "$(eq tick-cap "$(jq -r '.halt_reason' "$tick_dir/state/budget.json")")"
rm -rf "$tick_dir"

# The incident file: 470 ticks against a cap of 400 AND 149,752,682 tokens
# against a cap of 1,000,000, recorded as halt_reason "token-cap" alone. The
# caps are tested in a fixed order and the first hit used to be the only one
# written, so the tick breach was invisible in the artefact.
both_dir="$(mktemp -d)"
new_budget "$both_dir"
jq '.tokens_spent = 149752682 | .clock_ticks_used = 470' "$both_dir/state/budget.json" \
  > "$both_dir/b" && mv "$both_dir/b" "$both_dir/state/budget.json"
budget_gate_dispatch "$both_dir" "worker" 2>/dev/null || true
check "halt_reason keeps the first hit for compatibility" \
  "$(eq token-cap "$(jq -r '.halt_reason' "$both_dir/state/budget.json")")"
check "halt_reasons names the masked tick breach too" \
  "$(eq 'token-cap tick-cap' "$(jq -r '.halt_reasons | join(" ")' "$both_dir/state/budget.json")")"
rm -rf "$both_dir"

# ---------------------------------------------------------------------------
printf '== 4. a healthy repo still dispatches ==\n' >&2

ok_dir="$(mktemp -d)"
new_budget "$ok_dir"
jq '.tokens_spent = 400000 | .clock_ticks_used = 12 | .consecutive_failures = 1' \
  "$ok_dir/state/budget.json" > "$ok_dir/b" && mv "$ok_dir/b" "$ok_dir/state/budget.json"

ok_rc=0; budget_gate_dispatch "$ok_dir" "worker" 2>/dev/null || ok_rc=$?
check "under every cap, the gate allows dispatch" "$(eq 0 "$ok_rc")"
check "an allowed dispatch does not halt the repo" \
  "$(eq false "$(jq -r '.halted' "$ok_dir/state/budget.json")")"
check "an allowed dispatch writes no breach" \
  "$(eq 0 "$(jq -r '.breaches // [] | length' "$ok_dir/state/budget.json")")"

# Right up to the boundary: one token short of the cap still dispatches.
jq '.tokens_spent = 999999' "$ok_dir/state/budget.json" > "$ok_dir/b" \
  && mv "$ok_dir/b" "$ok_dir/state/budget.json"
edge_rc=0; budget_gate_dispatch "$ok_dir" "worker" 2>/dev/null || edge_rc=$?
check "one token under the cap still dispatches" "$(eq 0 "$edge_rc")"
rm -rf "$ok_dir"

# ---------------------------------------------------------------------------
printf '== 5. the window reset preserves the evidence it clears ==\n' >&2

win_dir="$(mktemp -d)"
new_budget "$win_dir"
jq '.tokens_spent = 149752682 | .lifetime_tokens_spent = 154382214
    | .clock_ticks_used = 470 | .halted = true | .halt_reason = "token-cap"
    | .window_started_at = "2026-08-15"' \
  "$win_dir/state/budget.json" > "$win_dir/b" && mv "$win_dir/b" "$win_dir/state/budget.json"

budget_ensure_window "$win_dir" 2>/dev/null

check "the new window resumes the repo" \
  "$(eq false "$(jq -r '.halted' "$win_dir/state/budget.json")")"
check "the new window zeroes the window counter" \
  "$(eq 0 "$(jq -r '.tokens_spent' "$win_dir/state/budget.json")")"
check "caps are untouched by the reset" \
  "$(eq 1000000 "$(jq -r '.token_cap_total' "$win_dir/state/budget.json")")"
check "lifetime spend survives the reset" \
  "$(eq 154382214 "$(jq -r '.lifetime_tokens_spent' "$win_dir/state/budget.json")")"
check "the breach survives the reset" \
  "$(eq 1 "$(jq -r '.breaches | length' "$win_dir/state/budget.json")")"
check "the breach records the token overrun it erased" \
  "$(eq 149752682 "$(jq -r '.breaches[0].tokens_spent' "$win_dir/state/budget.json")")"
check "the breach records the tick overrun it erased" \
  "$(eq 470 "$(jq -r '.breaches[0].clock_ticks_used' "$win_dir/state/budget.json")")"
check "the breach says the reset cleared it" \
  "$(eq window-reset "$(jq -r '.breaches[0].cleared_by' "$win_dir/state/budget.json")")"
rm -rf "$win_dir"

# ---------------------------------------------------------------------------
printf '== 6. re-queue does not unlatch a blown spend cap ==\n' >&2

rq_dir="$(mktemp -d)"
mkdir -p "$rq_dir/state"
new_budget "$rq_dir"
jq '.tokens_spent = 149752682 | .halted = true | .halt_reason = "token-cap"' \
  "$rq_dir/state/budget.json" > "$rq_dir/b" && mv "$rq_dir/b" "$rq_dir/state/budget.json"
printf 'current_stage: null\nstages:\n  - id: 31-example-stage\n    status: verifier_failed\n' \
  > "$rq_dir/state/state.yaml"
git -C "$rq_dir" init -q 2>/dev/null || true

rq_rc=0
"$script_dir/requeue-stage.sh" "$rq_dir" 31-example-stage >/dev/null 2>&1 || rq_rc=$?
check "requeue exits non-zero when a spend cap is blown" \
  "$( [[ "$rq_rc" -ne 0 ]] && printf 'ok\n' || printf 'no: rc=%s\n' "$rq_rc" )"
check "requeue leaves the halt latched" \
  "$(eq true "$(jq -r '.halted' "$rq_dir/state/budget.json")")"

# The ordinary case it must not break: a failure-cap halt is exactly what a
# re-queue is for, and it clears.
jq '.tokens_spent = 400000 | .consecutive_failures = 3 | .halted = true
    | .halt_reason = "failure-cap"' \
  "$rq_dir/state/budget.json" > "$rq_dir/b" && mv "$rq_dir/b" "$rq_dir/state/budget.json"
"$script_dir/requeue-stage.sh" "$rq_dir" 31-example-stage >/dev/null 2>&1 || true
check "requeue still clears a failure-cap halt" \
  "$(eq false "$(jq -r '.halted' "$rq_dir/state/budget.json")")"
check "requeue clears the failure counter with it" \
  "$(eq 0 "$(jq -r '.consecutive_failures' "$rq_dir/state/budget.json")")"
rm -rf "$rq_dir"

# ---------------------------------------------------------------------------
printf '== 7. codex transcript spend reaches the cap by itself ==\n' >&2

codex_cap_dir="$(mktemp -d)"
new_budget "$codex_cap_dir"
codex_sessions="$codex_cap_dir/codex-sessions/2026/08/25"
codex_work_dir="$codex_cap_dir/worktree"
mkdir -p "$codex_sessions" "$codex_work_dir" "$codex_cap_dir/state/logs"
printf '%s\n' \
  "{\"timestamp\":\"2026-08-25T00:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"timestamp\":\"2026-08-25T00:00:00Z\",\"cwd\":\"$codex_work_dir\"}}" \
  '{"timestamp":"2026-08-25T00:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1200000,"cached_input_tokens":900000,"output_tokens":100000,"total_tokens":1300000}}}}' \
  > "$codex_sessions/cap.jsonl"
printf 'tokens used\n400000\n' > "$codex_cap_dir/state/logs/codex.log"

AUTOMETTA_CODEX_TRANSCRIPT_ROOTS="$codex_cap_dir/codex-sessions" \
  budget_account_tokens_from_dispatch "$codex_cap_dir" \
    "$codex_cap_dir/state/logs/codex.log" worker "$codex_work_dir" 0 codex 2>/dev/null

check "Codex budget charge includes fresh, cached and output tokens" \
  "$(eq 1300000 "$(jq -r '.tokens_spent' "$codex_cap_dir/state/budget.json")")"
check "budget_spend_caps_blown sees the Codex-only token breach" \
  "$(eq token-cap "$(budget_spend_caps_blown "$codex_cap_dir")")"
rm -rf "$codex_cap_dir"

# ---------------------------------------------------------------------------
if (( fail )); then
  printf '\nbudget-cap-smoke: FAIL\n' >&2
  exit 1
fi
printf '\nbudget-cap-smoke: all assertions passed\n' >&2
