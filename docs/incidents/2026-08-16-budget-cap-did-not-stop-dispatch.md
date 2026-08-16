# Incident: the budget cap did not stop dispatch

**Repo:** `emergence-lab-gpu`
**Window:** 2026-08-14 to 2026-08-16
**Found:** 2026-08-16, reading `state/budget.json` for an unrelated reason. No alarm fired at any point.
**Card:** `examples/self-host/31-budget-cap-did-not-stop-dispatch.md`

## Headline

149,752,682 tokens against a `token_cap_total` of 1,000,000. 470 ticks against a `clock_tick_cap` of 400. An estimated 1,175.99 USD in a single day. The queue drained, stages 34 to 39c completed, and the work was good.

The cap arithmetic was never wrong. The check was in the wrong place, and what it produced was a latch that several things could quietly unlatch.

## Artefacts this rests on

The subscriber was disabled and the repo removed on 2026-08-16 at about 11:04 local, partway through this investigation. The state survives at `~/.phat-controller/archive/emergence-lab-gpu-state-2026-08-16.tgz`, and every figure below is taken from it or from the controller tick logs at `~/.phat-controller/log/tick-2026-08-1[3456].log`.

Two discrepancies against the card, both worth recording because the card asks for the artefacts to be read rather than trusted:

- The card quotes `clock_tick_cap: 100`. The file says **400**. The overrun is 470 against 400, not 470 against 100.
- The card's quoted JSON omits `version`, `wall_clock_cap_seconds` (3600), `wall_clock_elapsed_seconds` (0), `consecutive_failure_cap` (3) and `consecutive_failures` (0).

Neither changes the conclusion. Both caps were still breached.

## Determination

The card offers two candidate mechanisms. The answer is closest to the second, but neither as stated: the check was reached, it was correct, and it fired. What failed is that **it gated the tick rather than the dispatch, and the resulting halt was cleared repeatedly by mechanisms that never asked whether budget remained**.

### 1. The cap gated the tick, not the spend

`budget_check_caps` had exactly one call site in the entire tree, `tick.sh:710`, at the top of `_process_repo_locked`. `spawn-worker.sh` and `spawn-verifier.sh` both source `budget.sh` and neither calls it.

That check runs before the reap. Later in the same tick, `budget_account_tokens_from_log` charges a finished agent's tokens, and the tick then goes on to spawn the next role against a budget read taken before that charge. Nothing between the charge and the spawn asks whether there is budget left.

Whether that matters depends entirely on the size of one dispatch relative to the cap. On this repo:

| | tokens |
|---|---|
| `token_cap_total` | 1,000,000 |
| mean dispatch | 4,830,731 |
| largest dispatch | 19,019,631 |
| dispatches individually exceeding the whole cap | 18 of 31 |

A budget consulted only between dispatches cannot bind when one dispatch is worth five caps. This is the card's mechanism 1, and contrary to the card's estimate it does not cap the damage at a 2x overshoot: the overshoot is one dispatch, and one dispatch here was routinely several times the entire budget.

### 2. The check fired correctly, and then the halt was undone

The cap worked the first time, and the logs are precise about it. Cumulative spend for the 2026-08-15 window crossed 1,000,000 during the stage-35 verifier, which was reaped at 07:42:03Z taking the total to 5,676,364. The very next tick halted:

```
2026-08-15T07:47:04Z halted .../emergence-lab-gpu due to token-cap
```

By 08:07:10Z the loop was working stage 36 again. Across 2026-08-14 to 2026-08-16 the tick log records **nine** separate `halted ... due to` events (one token-cap, two tick-cap, four failure-cap on 08-15, one token-cap on 08-14, one on 08-16). Every one of them was followed by the loop resuming.

For the loop to resume, `halted` must be cleared *and* `tokens_spent` must be back under the cap. Three mechanisms in the tree clear one or both, and none of them consults remaining budget:

- **`budget_ensure_window`** (`budget.sh`) is the only code path that zeroes `tokens_spent`. Run against the actual incident file with the window stamp set back one day, it produces `tokens_spent: 0, clock_ticks_used: 0, halted: false`, caps untouched, and logs a single stderr line. So `token_cap_total` was never a total. It was a per-UTC-day allowance that renewed itself silently.
- **`requeue-stage.sh:100-104`** cleared `.halted` unconditionally, on the comment's reasoning that "tick re-halts if a halt condition genuinely still exists". True of the tick check, but it makes a routine hand re-queue an unlatch of the only safety in the design, and the state branch shows this repo was re-briefed and re-queued repeatedly through the window ("re-brief 38 round 2", "round 3", "round 4", "re-brief 39a round 2").
- **`tick.sh --reset-halt`** does the same across every subscriber at once.

### 3. Residual uncertainty, stated rather than papered over

The full 149,752,682 accumulating within the 2026-08-15 window while the loop halted on token-cap at 07:47:04Z and next halted on *tick-cap* at 11:03:28Z is not fully reconstructible from the surviving artefacts. A tick-cap halt means the token comparison was false at 11:03, so `tokens_spent` was under 1,000,000 then, yet the day's cumulative spend by that point already exceeded 31,000,000. Something zeroed the counter mid-window, and the only in-tree path that does so is the day-boundary reset, which should not have fired mid-day.

The candidates are operator intervention on the file, or a hand-run of a reset path, neither of which leaves a trace. Rather than invent a mechanism, note what it implies: **`state/budget.json` is a gitignored file with no history, holding the only safety in the design, and any process or person may rewrite it leaving no record.** That is itself the finding, and the `breaches[]` retention below is the response to it.

### 4. The tick counter, separately

470 against 400 deserves its own answer because it needs no token parsing: one integer against another.

`budget_increment_tick` is called at most once per tick and every call site is downstream of the top-of-tick check, so the code cannot overshoot by 70 within one window. The overshoot is the same reset-and-unlatch artefact as the token one. But two things specific to the tick cap are worth fixing regardless:

- **The breach was never named.** The four caps are tested in a fixed order and `budget_check_caps` returned on the first match. A budget over both wrote `halt_reason: "token-cap"` and nothing else, so the 470/400 breach appears in no artefact anywhere. The card's own reading of the evidence was thrown by this: it inferred from `halt_reason: token-cap` that no tick-cap halt ever fired, when in fact two did, on 2026-08-15 at 11:03:28Z and 12:29:40Z.
- **`clock_ticks_used` has no coherent scope.** `budget_ensure_window`'s healthy branch preserves it across a day boundary while its breached branch zeroes it. So the counter is lifetime-scoped while the repo is well and window-scoped only once something has already gone wrong, which is the wrong way round. Left as-is deliberately: changing it would grant *more* budget, and this stage is not the place to do that. Recorded here as known and unfixed.

Separately, on the double-firing visible in the 2026-08-15 logs: every tick event there does appear twice, six seconds apart, and that is a real contributor to the 470/400 overshoot. It was **already fixed during the 2026-08-15 session**, before this stage ran: two duplicate launchd jobs were each running the fleet-wide tick loop (which takes no repo argument, so every subscriber was ticked once per job), and they were consolidated into the single `com.autometta.tick.fleet` agent. Verified on 2026-08-16: `~/.phat-controller/log/tick-2026-08-16.log` shows single fires at exactly 300-second intervals, and `launchctl list` carries one tick agent with the legacy cron entry disabled.

This stage's own analysis initially reported the double-fire in the present tense, having read the pre-fix logs without noticing the date boundary. Recorded here as the correction, because an incident doc that reports a fixed fault as live sends the next reader hunting a second fire source that no longer exists.

## The fix

| Change | File |
|---|---|
| `budget_gate_dispatch`, the cap check that guards a spawn. Halts before refusing; fails closed on any unexpected return code. | `scripts/budget.sh` |
| Called immediately before both the worker and the verifier spawn, after any reap in that tick has been charged. Worker gate runs before state is mutated or a worktree cut, so a gated stage stays cleanly pending. | `scripts/tick.sh` |
| `BUDGET_CHECK_ALL_HITS` and `halt_reasons`: every cap that was over, not just the first tested. | `scripts/budget.sh`, `schemas/budget.json` |
| `lifetime_tokens_spent`, monotonic, reset by nothing. | `scripts/budget.sh`, `schemas/budget.json` |
| `budget_record_breach` writes an append-only `breaches[]` entry both on a cap halt and immediately before the window reset zeroes anything. Bounded to the most recent 50. | `scripts/budget.sh`, `schemas/budget.json` |
| Re-queue clears a failure-cap halt and the failure counter, which is what re-queueing means, and refuses non-zero to clear one whose spend cap is still blown. | `scripts/requeue-stage.sh` |
| Regression test, offline, carrying the 31 real dispatch sizes as its replay fixture. | `scripts/budget-cap-smoke.sh` |

No cap was raised. No retry, backoff or circuit breaker was added. Every change is in the shared scripts, so it applies to every subscribed repo.

## The counterfactual

Replaying the 31 real dispatches of 2026-08-15 in order through the fixed gate:

```
replayed: halted after 2 of 31 dispatches at 5676364 tokens (cap 1000000)
incident: ran all 31 dispatches to 149752682 tokens
```

**It halts at 5,676,364 tokens.** Dispatch 1 (a 77,124-token worker) is allowed; dispatch 2 (a 5,599,240-token verifier) is allowed because spend is still 77,124; dispatch 3 is refused.

That is a 26x reduction, and it is still 5.7x the cap. Both halves matter. The residual is not slack in the implementation: the cap is enforced after the fact per dispatched process, so crossing it costs whatever the crossing dispatch cost, and here that was a 5.6M-token verifier. One dispatch of overshoot is the floor for an after-the-fact cap, and pre-dispatch estimation stays future scope (`docs/phat-controller.md`, "Deferred"). The operational consequence: **a cap smaller than a typical dispatch is decorative.** Set one you can afford to exceed by a single worker or verifier.

## Decision: what survives the daily window reset

The window reset can erase evidence of a breach, and did. This is the answer to the card's fifth deliverable.

The reset keeps its purpose. A new day still resumes a repo that halted for a real reason, and the caps are still left untouched. What changes is that it no longer destroys the record on its way through. Preserved across the boundary:

- **`lifetime_tokens_spent`**: monotonic, incremented alongside `tokens_spent`, reset by nothing. `tokens_spent` answers how much of this window's cap is left; this answers what the repo has actually cost, which is the question nobody could answer on the morning after.
- **`breaches[]`**: one record per breach, written *before* the reset touches the counters, capturing `tokens_spent`, `clock_ticks_used`, `consecutive_failures`, all four caps, the reasons, and whether it was a `halt` or a `window-reset` that closed it. Bounded to the most recent 50 so the file cannot grow without limit.
- The reset's log line now names the breach it is carrying over and the lifetime total, instead of noting only that a reset happened.

Deliberately **not** preserved: the halt itself. Making a token breach terminal across windows would mean an overrun on Monday stops the repo forever, which is the behaviour `budget_ensure_window` exists to prevent, and the card rules out weakening it.

The gap this leaves is that `state/budget.json` is gitignored and has no history, so `breaches[]` is only as durable as the file. `commit_state_branch` already tries to `git add state/budget.json` and that add is a silent no-op wherever `state/**` is ignored, which is every subscribed repo checked. Worth a follow-up card: the breach record is the audit trail for spend, and it currently lives in a file with no backup.

## What makes this the dangerous kind of failure

Every visible signal said success. Stages completed, commits landed, verifiers passed, the work was good. The single artefact that disagreed was a gitignored JSON file nobody reads while things are working, and the daily reset meant that by the next morning it agreed too.

"Budget file, not retries" is load-bearing because there is nothing behind it. No circuit breaker, no backoff, no second line. A budget file that does not stop dispatch is not a weak safety. It is the absence of one, presented as its presence.
