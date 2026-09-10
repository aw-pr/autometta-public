# Stage card 97: a pause is not a stall

## Metadata

- **Authored:** 2026-08-31
- **Orchestrator:** Claude Fable 5 <claude-fable-5@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Opus 5 <claude-opus-5@local>
- **Base branch:** dev
- **Run branch:** autometta/97-a-pause-is-not-a-stall
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Gate:** stage-completed: 96-no-verdict-left-behind
- **Path claims:** scripts/tick.sh, scripts/budget-cap-smoke.sh
- **Pairing rationale:** tick-loop surgery with a smoke harness beside it;
  the standard seats for this run's control-plane work.

## Objective

Stage 96, 2026-08-31, attempt 2: the worker returned a PASS envelope at
18:39:44Z; the verifier's first dispatch was refused by the provider (429)
and the loop correctly paused the repo until the window reset at 20:45
BST. The first tick after the pause then marked the stage
"stalled after 4487s (budget 1800s + 50% grace)" and never dispatched the
verifier. The 4487s is almost entirely the pause itself: dead time in
which no agent existed, charged against the stage's worker wall-clock as
though work were running. A finished worker plus a provider pause equals
a stall verdict, which is wrong twice over.

Fix both halves in the tick's stall check:

1. **A stage with a consumed PASS worker envelope and no live agent is not
   stallable on the worker clock.** Its only outstanding obligation is a
   verifier dispatch, which the tick itself owes. The stall check must
   skip straight to dispatching (or waiting out the pause), not tally
   wall-clock against a worker that already returned.
2. **Paused time is excluded from the stall arithmetic.** Time between a
   provider refusal's pause start and its expiry counts toward nothing:
   not the worker budget, not the grace window. Track the exclusion from
   the pause records the budget file already keeps; no new state file.

## Inputs (read these in your own context)

- scripts/tick.sh (the stall check that produced the message above, the
  pause bookkeeping, and the verifier dispatch path)
- scripts/budget-cap-smoke.sh (the harness this extends)
- state/budget.json fields paused_until / paused_reason (shape only)

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/tick.sh`: the stall check implements both rules above. A
   genuinely running worker past budget + grace still stalls exactly as
   today.
2. `scripts/budget-cap-smoke.sh`: two regression checks: (a) a stage with
   a consumed PASS envelope, no live pid, and elapsed wall-clock past
   budget + grace is NOT stalled, and the tick proceeds to verifier
   dispatch; (b) elapsed time spanning a recorded pause window subtracts
   the pause before comparing against budget + grace.

## Constraints

- No change to the pause mechanism itself or the provider-refusal
  classification (cards 35 and 52 own those).
- The worker-still-running stall path keeps its current arithmetic when
  no pause occurred.
- No new state files; derive the exclusion from existing budget records.
- British English in prose, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

1. `bash -n scripts/tick.sh` and `bash -n scripts/budget-cap-smoke.sh`
   pass.
2. The full `scripts/budget-cap-smoke.sh` passes, including both new
   checks and every pre-existing check unchanged.
3. Fixture (a): PASS envelope consumed, no pids, elapsed 2x budget: after
   one tick the stage is not stalled and a verifier dispatch was
   attempted (evidence: state and tick log lines).
4. Fixture (b): a pause spanning most of the elapsed time: the stage
   survives the stall check; the same fixture without the pause record
   stalls as on dev today.
5. `git diff --stat` on the run branch touches only the two claimed paths.

## Contract test

- **Test file:** scripts/budget-cap-smoke.sh
- **Assertions digest:** a returned worker is never stalled on the worker
  clock; paused time is excluded from stall arithmetic; a genuinely
  overrunning worker still stalls.

## Out of scope

- Retry/backoff policy for provider refusals (the pause stands as is).
- The verifier attempt cap and its counting.
- Live-agent stall detection (heartbeat), which is a different mechanism.

## Budget

- **Worker wall-clock:** 2400s
- **Verifier wall-clock:** 1800s

## Verifier handoff

Leave the working tree dirty. Report both new smoke checks' output
verbatim, the pre-existing checks' summary, and the diff stat.

## Family-specific notes

None
