# Stage card 67: an outlier dispatch says so while it runs

## Metadata

- **Authored:** 2026-08-25
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Base branch:** dev
- **Run branch:** autometta/67-an-outlier-dispatch-says-so-while-it-runs
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Gate:** stage-completed: 65-the-loop-stamps-its-own-heartbeat
- **Pairing rationale:** arithmetic over an existing ledger, written by the
  family that owns the cost log and checked by the family that will read the
  warning.

## Objective

On 2026-08-25 a single worker spent **45,758,708 tokens**. The median worker
on this repo spends between one and two million: the stage dispatched an hour
earlier cost 1,824,717 against a card of comparable size. The outlier was
twenty-five times the median, took the day's total from 18.8M to 66.6M in one
dispatch, and **nothing said anything** until the day ended over cap.

Nothing was broken. `budget_gate_dispatch` refuses a dispatch once the cap is
reached and it did exactly that, later. But it is the only spend signal in the
loop, and it fires at one threshold, at one moment, after the money is gone.
There is no signal for "this dispatch is behaving unlike every other dispatch
on this repo", which is a different and more useful fact.

**The data already exists.** `state/cost-log.jsonl` carries one row per
dispatched role with `total_tokens`, `usage_status` and the tier and route. A
median over the last N rows is a one-line `jq`. The registry at
`state/active-agents/<pid>.json` carries the live agent, its role, its start
time and its budget, and `budget_parse_dispatch_tokens_from_transcript`
already reads a running dispatch's usage. Everything needed is on disk and
nothing reads it for this purpose.

The same day gave a second illustration. A re-briefed stage cost 30.7M on its
second attempt against 16.2M on its first, because the re-brief changed the
shape of the solution rather than correcting details. A warning would not have
stopped that, and should not have. It would have made it visible while it was
happening rather than in a post-mortem.

## Inputs (read these in your own context)

- `state/cost-log.jsonl` and `docs/cost-log.md` for the row schema, including
  `usage_status` values `recorded`, `total_only` and `unknown`.
- `scripts/cost-log.sh`, the appender.
- `scripts/budget.sh`, `budget_gate_dispatch` and
  `budget_parse_dispatch_tokens_from_transcript`.
- `scripts/heartbeat.sh`, the existing precedent for surfacing a condition
  about a running agent without acting on it.
- `state/active-agents/<pid>.json` and `docs/observability.md`.
- `docs/incidents/2026-08-24-run-lessons-log.md` entries 10 and 13.

## Deliverables

1. **A per-repo baseline computed from the cost log**, per role, since worker
   and verifier costs differ by an order of magnitude and comparing them is
   meaningless. Use a median or another order statistic, not a mean: one 45M
   row drags a mean far enough to hide the next outlier.
2. **A warning while the dispatch is still running**, not after it exits. The
   heartbeat already inspects live agents on its own schedule and is the
   natural home. Surface it the way a stall is surfaced.
3. **The warning is an observation, never an action.** It does not kill the
   agent, halt the repo, or refuse anything. A large dispatch is often
   legitimate: it is what a big card costs. The operator decides.
4. **A cold start says nothing.** With fewer than a stated minimum of
   comparable rows there is no baseline, and the honest output is silence
   rather than a warning against a sample of two. State the minimum and why.
5. **Rows that cannot be compared are excluded, not treated as zero.**
   `usage_status: unknown` and null totals must not drag the baseline down and
   manufacture outliers. Card 59 introduced those states deliberately.
6. **It is visible where an operator already looks**: the repo ticker's
   escalations, and the tick log. Reuse the existing surfaces rather than
   inventing a new file.
7. **A smoke** replaying the 2026-08-25 sequence: a run of ordinary dispatches
   establishing a baseline, then one at twenty-five times it, asserting the
   warning fires while it runs, names the multiple, and takes no action.

## Constraints

- Do not add a cap, a limit, or any refusal. `budget_gate_dispatch` is the
  only thing that refuses, and this card does not touch it.
- Do not poll a transcript on a tight loop. The heartbeat's existing cadence
  is the budget; a warning that costs meaningful time to compute is not worth
  having.
- No new state file. The cost log, the agent registry and the heartbeat file
  are enough.
- Do not warn on wall-clock. Elapsed against budget already exists in the
  ticker and is a different signal.

## Acceptance criteria

1. A baseline is computed per repo and per role from the cost log, excluding
   uncomparable rows. Show it against the real log in this repo.
2. A dispatch far above the baseline is flagged while it is still running.
   Show the flag and the live agent.
3. The flag names the figure and the multiple, so an operator can judge
   without opening the log.
4. Nothing is killed, halted or refused. Show the agent running to completion
   after the warning.
5. With fewer than the stated minimum of comparable rows, nothing is emitted.
6. `usage_status: unknown` and null-total rows change no baseline. Show a log
   containing both.
7. The warning appears in the repo ticker's escalations and the tick log.
8. The smoke replays the 2026-08-25 sequence, fails on the pre-fix tree and
   passes after.

## Contract test

Replay 2026-08-25 from this repo's own `state/cost-log.jsonl`: the workers at
1.8M and 2.8M establishing a baseline, then the 45.7M worker. The warning must
fire during that third dispatch, name roughly twenty-five times the median,
and let it finish.

## Out of scope

- Estimating what a card will cost before dispatch. This is observation of
  what is happening, not prediction.
- Any change to rates in `scripts/rates.sh` or to cost estimation.
- The cap and drain mechanism.

## Budget

- **Worker wall-clock:** 60 minutes
- **Verifier wall-clock:** 40 minutes

## Verifier handoff

Return the baseline against the real log, the live warning with its multiple,
proof nothing was killed or halted, the cold-start silence, the excluded-row
cases, both surfaces carrying the warning, and the replay smoke before and
after.

## Family-specific notes

None
