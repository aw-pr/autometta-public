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
- **Cold read:** Codex (GPT-6.1 Sol, read-only) 2026-10-23, with card 160. Answered: the schema field is now deliverable 4; the double-preserve production path is fixture (n); gate placement is asserted by order in `_process_repo_locked`.
- **Baseline note:** `scripts/state-schema-smoke.sh` is red on dev for an environment reason (`ModuleNotFoundError: No module named 'yaml'` in the host python), unchanged by this card and not a criterion here.

## Surfacing concern

The only recovery the phat-controller was ever useful for without a human was mechanical: a worker that died or stalled without reporting anything (no envelope, no `BLOCKED` marker) gets requeued once. That needs no judgement and no model tokens, but today it waits for a controller pass (`pc_requeue`, `scripts/phat-controller.sh`), and controller passes are being retired (card 162). Everything that does need judgement (frozen-contract conflicts, re-briefs, criteria) is outside the controller's mandate anyway (`docs/proposals/orchestrator-role-review.md`, prohibition 1).

## Objective

When a stage's worker ends without a usable envelope, the tick preserves the attempt's work through `preserve_failed_work`, requeues the stage once through `scripts/requeue-stage.sh`, and records the retry. "Without a usable envelope" means all of: status `stalled`; no worker envelope at `state/envelopes/<id>.json` or `state/handoffs/<id>.json` (an invalid one has already been moved aside to `.invalid.json`); `worker_pid` empty or not a live process; and a `stall_marker` that is not a deterministic fault (`dispatch_configuration_fault:*`, `run_worktree_failed`, `dispatch_base_tip_unresolved`, `card_missing`), which a retry would only repeat. An empty marker qualifies (the silence and wall-clock stalls set none). A verifier-side stall is excluded because its worker envelope exists. A second such ending for the same stage, a worker envelope with `status: fail` (status `failed`), any `verifier_failed`, and any stage in a halted repo are left in their alert status for card 159's escalation and never retried automatically. (Operator decision 2026-10-23: the card's earlier `BLOCKED`-marker rule is dropped, because nothing writes such a marker.)

## Inputs (read these in your own context)

- `scripts/tick.sh` (stall detection near the `stalled` transitions, `preserve_failed_work`, the reaper)
- `scripts/requeue-stage.sh`
- `scripts/phat-controller.sh` (`pc_requeue`, `pc_preserve`, for what they already do)
- `scripts/escalations.sh` (card 159)
- `docs/tick-loop.md`

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/tick.sh`: a function `auto_retry_dead_workers <repo-root> <state-yaml>` (the frozen smoke calls it by that name) performing the single automatic retry above, called from `_process_repo_locked` after the budget, halt and pause checks and before dispatch selection. It records `auto_retries: 1` on the stage after its requeue (absent means 0) and logs one line naming the stage, the reason and the preserved commit. It calls `scripts/requeue-stage.sh --keep-budget` rather than copying its mechanics.
2. `scripts/requeue-stage.sh`: a `--keep-budget` option that skips the halt-clearing and `consecutive_failures` reset (an automatic retry must not unlatch a gate), and its stage reset sets `auto_retries` to 0, so an operator requeue gives the stage its automatic retry back. Without `--keep-budget` its behaviour is unchanged.
3. `scripts/auto-retry-smoke.sh` (frozen, written by the orchestrator; do not edit it): (a) worker gone with no envelope, retried once with `budget.json` untouched; (b) the same stage dying again, not retried; (c) envelope `status: fail`, not retried; (d) a stall carrying a worker envelope, not retried; (e) `verifier_failed`, not retried; (f) the preserved commit exists on a `wip/` branch and contains the fixture's uncommitted file; (g) each deterministic fault, not retried; (h) a halted repo, not retried and its budget untouched; (i) a live worker pid, not retried; (j) a preservation failure, not retried and the work left in place; (k) an empty marker, retried; (l) other stages untouched; (m) an operator requeue resets `auto_retries`; (n) a stage the stall path already preserved, whose card names a gitignored deliverable, is still retried and its recorded `wip_commit` holds the deliverable (the production path: the missing-envelope, silence and wall-clock stalls already call `preserve_failed_work`, so the retry's preserve may find nothing new and must not treat that as a failure). It also checks the schema declares `auto_retries` and that `_process_repo_locked` calls the retry after `budget_check_caps` and `budget_pause_active`.
4. `schemas/state.yaml.json`: declare `auto_retries` (integer, minimum 0) on the stage record beside `repair_attempts`, as `docs/tick-loop.md` requires for every field the tick writes.
5. `docs/tick-loop.md`: a short "Automatic retry" paragraph stating the rule and that everything else goes to the escalation folder.

## Constraints

- At most one automatic retry per stage, ever, until an operator requeue resets the record.
- The retry respects every existing gate: budget, halt, quota reserve and schedule stop. A retry is a pending stage like any other; it does not bypass dispatch checks.
- Work is preserved before anything is removed; a preservation failure aborts the retry and leaves the stage in its alert status.
- No agent is dispatched by this logic other than the ordinary worker dispatch the requeue leads to.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. **Smoke, worker and verifier:** `scripts/auto-retry-smoke.sh` exits 0. Base: red (`tick.sh defines no auto_retry_dead_workers`).
2. **No regression, worker and verifier:** `scripts/escalations-smoke.sh`, `scripts/phat-controller-smoke.sh`, `scripts/state-branch-smoke.sh` and `scripts/budget-cap-smoke.sh` exit 0. Base: green.
3. **Shared mechanics, verifier:** the retry path calls `scripts/requeue-stage.sh --keep-budget` rather than a second copy of its mechanics (the smoke also checks the call); `bash -n scripts/tick.sh` passes.
4. **Lint, worker:** `shellcheck -S warning scripts/auto-retry-smoke.sh` exits 0, and `scripts/tick.sh` and `scripts/requeue-stage.sh` gain no new warning-level findings over the base.

## Contract test

- **Test file:** `scripts/auto-retry-smoke.sh`
- **Assertions digest:** `sha256:adde7059e0ea9d98c9b53cf207b6c02536778e87b88b38445d9b58ff50a96371`
- **Oracle proof:** fails on dev at its first assertion (`tick.sh defines no auto_retry_dead_workers`). A throwaway reference (a 20-line function in `tick.sh`, `--keep-budget` and the `auto_retries` reset in `requeue-stage.sh`), built on the throwaway references for 159 and 160, passed every assertion and left the escalations, session-start, phat-controller, state-branch and budget-cap smokes green. Mutations each tripped their own case: no `--keep-budget` (a), no halt check (h), no live-pid check (i), no fault exclusion (g), no once-only check (b), retrying past a preservation failure (j), no reset in requeue (m). Traps: a fixture `budget.json` must carry every cap field, or `budget_spend_caps_blown` reports a blown cap and `requeue-stage.sh` exits 3; `preserve_failed_work` returns 0 on a clean worktree, so "preservation failed" means a non-zero return, not "nothing preserved".

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
