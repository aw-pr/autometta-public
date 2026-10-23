# Stage card 161: the tick retries a dead worker once

## Metadata

- **Authored:** 2026-10-23
- **Orchestrator:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Worker:** GPT-6.1 Sol <gpt-6-1-sol@local>
- **Verifier:** Claude Sonnet 5.5 <claude-sonnet-5-5@local>
- **Base branch:** dev
- **Run branch:** autometta/161-the-tick-retries-a-dead-worker-once
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Gate:** stage-completed: 160-an-orchestration-chat-sees-escalations
- **Dispatch:** serial
- **Pairing rationale:** a narrow change to `scripts/tick.sh`, load-bearing, so serial; Sol writes it and Sonnet verifies cross-family, alternating from card 160. Gated on 160 so the run stays strictly serial through `tick.sh` and the escalation it raises on the second death already has a reader.
- **Open decisions:** none

## Surfacing concern

The only recovery the phat-controller was ever useful for without a human was mechanical: a worker that died or stalled without reporting anything (no envelope, no `BLOCKED` marker) gets requeued once. That needs no judgement and no model tokens, but today it waits for a controller pass (`pc_requeue`, `scripts/phat-controller.sh`), and controller passes are being retired (card 162). Everything that does need judgement (frozen-contract conflicts, re-briefs, criteria) is outside the controller's mandate anyway (`docs/proposals/orchestrator-role-review.md`, prohibition 1).

## Objective

When a stage's worker ends without a usable envelope (process gone and no envelope, or a `stalled` status whose `stall_marker` does not start with `BLOCKED`), the tick preserves the attempt's work through `preserve_failed_work`, requeues the stage once through the same mechanics as `scripts/requeue-stage.sh`, and records the retry. A second such ending for the same stage, or any ending that carries an envelope with `status: fail` or a `BLOCKED` marker, or any `verifier_failed`, is left in its alert status for card 159's escalation and is never retried automatically.

## Inputs (read these in your own context)

- `scripts/tick.sh` (stall detection near the `stalled` transitions, `preserve_failed_work`, the reaper)
- `scripts/requeue-stage.sh`
- `scripts/phat-controller.sh` (`pc_requeue`, `pc_preserve`, for what they already do)
- `scripts/escalations.sh` (card 159)
- `docs/tick-loop.md`

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/tick.sh`: the single automatic retry above, counted in the stage record as `auto_retries` (absent means 0), and logged as one line naming the stage, the reason and the preserved commit. Requeue mechanics are shared with `scripts/requeue-stage.sh` (sourced function or a call), not duplicated.
2. `scripts/auto-retry-smoke.sh`: fixtures for (a) worker gone with no envelope, retried once; (b) the same stage dying again, not retried, left `stalled`; (c) envelope `status: fail`, not retried; (d) `BLOCKED` marker, not retried; (e) `verifier_failed`, not retried; (f) the preserved commit exists and contains the fixture's uncommitted file.
3. `docs/tick-loop.md`: a short "Automatic retry" paragraph stating the rule and that everything else goes to the escalation folder.

## Constraints

- At most one automatic retry per stage, ever, until an operator requeue resets the record.
- The retry respects every existing gate: budget, halt, quota reserve and schedule stop. A retry is a pending stage like any other; it does not bypass dispatch checks.
- Work is preserved before anything is removed; a preservation failure aborts the retry and leaves the stage in its alert status.
- No agent is dispatched by this logic other than the ordinary worker dispatch the requeue leads to.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. **Smoke, worker and verifier:** `scripts/auto-retry-smoke.sh` exits 0. Base: red (absent).
2. **No regression, worker and verifier:** `scripts/escalations-smoke.sh`, `scripts/phat-controller-smoke.sh`, `scripts/state-branch-smoke.sh` and `scripts/budget-cap-smoke.sh` exit 0. Base: green.
3. **Shared mechanics, verifier:** the retry path calls the requeue mechanics `scripts/requeue-stage.sh` uses rather than a second copy; `bash -n scripts/tick.sh` passes.

## Contract test

- **Test file:** `scripts/auto-retry-smoke.sh`
- **Assertions digest:** to be recorded before queueing
- **Oracle proof:** pending: the orchestrating chat authors the frozen block with `autometta-oracle`, proves it red on dev and green on a reference, and records the digest here before queueing.

## Out of scope

- Retrying verifier failures or worker FAIL envelopes (those need a decision).
- Changing pairing or effort on a retry.
- Removing controller code (card 162).

## Budget

- **Worker wall-clock:** 45 minutes (kill at 70)
- **Verifier wall-clock:** 20 minutes
- **Spend basis:** autometta role median 1.0M tokens, p95 3.7M (2026-10-23). Plan 5M: `tick.sh` cards run above the median.

## Dispatch envelope

Write `state/envelopes/161-the-tick-retries-a-dead-worker-once.json` using `schemas/envelope.json`. List changed deliverables, the exact smoke commands and their results, and any criterion you could not satisfy with why. If the card itself is wrong, stop with `status: fail` and say so in `notes`. Do not self-verify or land your own branch. The verifier writes `state/verifiers/161-the-tick-retries-a-dead-worker-once.json`.

## Family-specific notes

None
