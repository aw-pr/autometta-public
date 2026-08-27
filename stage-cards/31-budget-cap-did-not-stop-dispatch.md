# Stage card 31-budget-cap-did-not-stop-dispatch: the token cap overran by 150x before anything halted

## Metadata

- **Authored:** 2026-08-16
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Claude Opus 5 <claude-opus-5@local>
- **Verifier:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Pairing rationale:** cross-family. The Claude worker reasons about the
  counterfactual the card demands — would this cap have stopped the run that
  actually happened — and a Codex verifier is free of the assumptions that
  let the overrun through.

## Objective

`emergence-lab-gpu` spent 149,752,682 tokens against a `token_cap_total` of
1,000,000 and used 470 clock ticks against a `clock_tick_cap` of 100. The loop
halted at 2026-08-16T07:23:13Z, long after both caps were meaningless.

Make a cap stop dispatch at the cap.

## Reported by

Found on 2026-08-16 while reviewing repo state, not by any alarm — nothing
surfaced this at the time it was happening. `state/budget.json` in
`emergence-lab-gpu`:

```json
{
  "token_cap_total": 1000000,
  "tokens_spent": 149752682,
  "clock_tick_cap": 100,
  "clock_ticks_used": 470,
  "halted": true,
  "halt_reason": "token-cap",
  "halted_at": "2026-08-16T07:23:13Z",
  "window_started_at": "2026-08-16"
}
```

The estimated spend, summed from that repo's `state/cost-log.jsonl`:

| Day | Runs | Tokens | `cost_usd_est` |
|---|---|---|---|
| 2026-08-14 | 7 | 4,629,532 | 69.44 |
| 2026-08-15 | 31 | 149,752,682 | 1,175.99 |

The loop drained its queue — stages 34 through 39c all completed, and the work
is good. That is what makes this the dangerous kind of failure: the run looks
like a success, and the only evidence that the safety mechanism did nothing is
in a file nobody reads while it is working.

**Budget file, not retries** is a load-bearing belief (`CLAUDE.md`, "Load-bearing
beliefs"). The budget file is the *only* safety in the design — there are
deliberately no circuit breakers and no backoff behind it. It did not hold.

## What the evidence already rules out

Token *accounting* worked. `tokens_spent` (149,752,682) equals the 2026-08-15
cost-log total exactly, to the token. Whatever went wrong, it was not that the
loop failed to notice the tokens; it noticed every one of them and dispatched
the next stage anyway. Do not spend the stage re-verifying the parser.

Two candidate mechanisms, both consistent with the artefacts, and settling
which one it is *is* the first deliverable:

1. **Enforcement runs too late in the tick.** Tokens are charged when
   `tick.sh` reaps a finished agent and calls `budget_account_tokens_from_log`
   (`scripts/budget.sh:236-254`). If `budget_check_caps` (`scripts/budget.sh:47`)
   is consulted before the reap rather than after, or a dispatch decision is
   taken on a budget that is one whole stage out of date, every stage costs one
   full overrun before the cap can see it. That explains a 2x overshoot. It does
   not obviously explain 150x.
2. **The check is not reached on every tick.** `clock_ticks_used` is 470
   against a cap of 100 with `halt_reason: token-cap`, not `tick-cap`. The tick
   counter passed its own cap 370 ticks earlier and no tick-cap halt fired.
   That points at `budget_check_caps` not being called on the path those ticks
   took, rather than at the comparison inside it being wrong.

The second is the more alarming reading and the tick counter is the cleanest
evidence for it, because that cap needs no token parsing to evaluate: it is one
integer against another.

Note also `window_started_at: 2026-08-16` with `tokens_spent` still holding the
2026-08-15 total. `budget_ensure_window` (`scripts/budget.sh:112-154`) zeroes
counters when it crosses a day boundary into a halted-or-at-cap budget, so an
at-cap budget that crossed midnight should read zero, not 149M. Either the
window function never ran before the halt, or it ran and took its `else`
branch. Whichever it is, the interaction between the daily reset and a cap that
is already blown needs stating explicitly in the report — a reset that clears a
cap breach without anyone seeing it is how a 150x overrun becomes invisible the
next morning.

## Inputs (read these in your own context)

- scripts/budget.sh — `budget_check_caps` (47), `budget_ensure_window` (112),
  `budget_halt` (156), `budget_account_tokens_from_log` (236)
- scripts/tick.sh — every call site of the four functions above, and the
  ordering of reap, account, check, dispatch within one tick
- schemas/budget.json — the cap fields and their intended semantics
- docs/phat-controller.md — what the budget is claimed to guarantee
- `~/repos/emergence-lab-gpu/state/budget.json` and `state/cost-log.jsonl` —
  the incident artefacts. Read them, do not just trust this card's table.

## Deliverables

1. A determination of which mechanism above (or which third one) let 149M
   tokens through a 1M cap, stated with evidence from the tick source and the
   incident artefacts rather than from reasoning about what the code ought to
   do.
2. A fix that halts dispatch at the cap. The test of the fix is the
   counterfactual: replay or simulate the 2026-08-15 sequence and show the loop
   stops within one stage's spend of the cap, not 150 stages later.
3. Specifically address the tick counter. 470 against a cap of 100 is a
   simpler failure than the token one and should have its own answer.
4. A regression test that fails against the pre-fix commit, asserting a
   cap-breaching sequence halts. Assert on the halt decision, not on a live
   dispatch, so it needs no auth or spend.
5. State whether the daily window reset can erase evidence of a breach, and if
   so, what should be preserved across it. A breach that self-clears at
   midnight is one the operator never learns about.
6. `docs/lessons.md` — add as a numbered gotcha. The gotcha worth recording is
   not "a cap was wrong"; it is that the loop's only safety failed silently
   while producing a clean-looking run.

## Constraints

- Do not raise the caps to make the symptom go away.
- Do not add retries, backoff or circuit breakers. The belief is one hard stop
  on bounded spend, and it stays that way (`CLAUDE.md`, load-bearing beliefs).
- The fix must apply to every subscribed repo, not just the one that broke.
- Do not weaken `budget_ensure_window`'s legitimate purpose: a new day should
  still be able to resume a repo that halted for a real reason.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. The repo's own acceptance suite is green.
2. The 2026-08-15 sequence, replayed or faithfully simulated against the fixed
   code, halts at or near the token cap. State the number it stops at.
3. A budget whose `clock_ticks_used` reaches `clock_tick_cap` halts with
   `tick-cap` and dispatches nothing further.
4. The regression test fails against the pre-fix commit. Check it out, run it,
   state the failure.
5. A healthy repo under its caps still dispatches normally — the fix must not
   halt work that has budget left.
6. The window-reset interaction is stated, with a decision on evidence
   retention.

## Contract test

- **Test file:** <<fill at dispatch>>
- **Assertions digest:** <<fill at dispatch>>

## Out of scope

- The cost-log attribution defects (`stage: null`, `family: null`, implausible
  per-run token totals) — that is card `32-cost-log-attribution-and-totals`.
  This card takes the totals at face value deliberately: even if every figure
  is inflated, the cap was blown by orders of magnitude.
- Re-running or repairing the `emergence-lab-gpu` stages. The work completed.
- Changing what the caps are set to.

## Budget

- **Worker wall-clock:** 60 minutes
- **Verifier wall-clock:** 45 minutes

## Verifier handoff

Worker reports: which mechanism let the spend through, with evidence; where the
cap is now enforced and why that point is early enough; the replayed
counterfactual and the number it halts at; the separate answer for the tick
counter; the regression test's failure output against the pre-fix commit; and
the decision on whether a breach survives the daily window reset.

## Family-specific notes

None. Nothing here needs a live dispatch — every artefact this card turns on is
already on disk.
