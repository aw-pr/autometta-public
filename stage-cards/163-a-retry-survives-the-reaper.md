# Stage card 163: a retry survives the reaper

## Metadata

- **Authored:** 2026-10-23
- **Orchestrator:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Worker:** GPT-6.1 Sol <gpt-6-1-sol@local>
- **Verifier:** Claude Sonnet 5.5 <claude-sonnet-5-5@local>
- **Base branch:** dev
- **Run branch:** autometta/163-a-retry-survives-the-reaper
- **Worker effort:** high
- **Verifier effort:** medium
- **Verifier panel:** false
- **Dispatch:** serial
- **Pairing rationale:** a narrow change across `scripts/tick.sh`, the heartbeat's embedded python and two small scripts, all smoke-testable: Sol writes it on the Codex window and Sonnet verifies cross-family on the Claude window, the same pairing that landed card 161 on attempt 1. It touches `scripts/tick.sh`, which is load-bearing, so it dispatches serially.
- **Open decisions:** none
- **Cold read:** pending; run a Codex read-only cold read before queueing (`autometta-card-review` section 3).

## Surfacing concern

Card 161's automatic retry almost never fires in production. On 2026-10-23 card 162's worker was killed by the heartbeat as a token outlier, and the tick log shows the order: the stall path preserved the attempt (`preserved attempt 1 as fa61fca... on wip/162-...-attempt-1`), the reaper removed the now-pinned worktree one second later (`safe to reap`), and six seconds after that the retry called `preserve_failed_work`, found no run worktree, got a non-zero return and logged `automatic retry skipped: preservation failed`. The missing-envelope, silence and wall-clock stall paths all preserve and then let the reaper run before the retry, so this is the normal order, not a race. Card 161's frozen fixtures always kept the worktree in place, which is why its oracle missed it.

The retry was right to skip that stage, for the wrong reason: a dispatch the heartbeat killed for spending too much would spend the same again. But the tick cannot tell a killed dispatch from a dead one. The heartbeat records `outcome: killed-token-outlier` in the agent's registration, and its next pass, finding the pid dead, rewrites the record with `outcome: exited` and empty flags (`state/recent-agents/21659-162-the-controller-is-retired.json` shows exactly that), so the tick only ever sees `worker_envelope_missing_after_exit`.

## Objective

A worker that died without an envelope is retried once even when the reaper has already removed its pinned worktree, and a dispatch the heartbeat killed is never retried automatically: the kill leaves a durable record that the retry, the escalation and a requeue all read.

## Inputs (read these in your own context)

- `scripts/tick.sh` (`auto_retry_dead_workers`, `preserve_failed_work`, `worktree_path_for_stage`, the missing-envelope transition near `worker_envelope_missing_after_exit`)
- `scripts/heartbeat.sh` (the embedded python: the token-outlier kill and the quota run-cap kill, and the dead-agent move to `recent-agents`)
- `scripts/requeue-stage.sh` (the per-stage purge, `--worktree-only`, `--keep-budget`)
- `scripts/escalations.sh` (`escalation_write`, the per-stage body)
- `scripts/reap-worktrees.sh` (when the reaper removes a worktree)
- `scripts/retry-after-reap-smoke.sh` (the frozen contract test)
- `docs/tick-loop.md` (the "Automatic retry" paragraph from card 161)

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/tick.sh`, `auto_retry_dead_workers`: when the stage's run worktree no longer exists, the retry proceeds without calling `preserve_failed_work`. The reaper removes a worktree only when it is clean or its work is pinned on a `wip/` branch, so there is nothing left to preserve; the log line names the recorded `wip_commit` (or "none"). A worktree that does exist is preserved exactly as today, and a preservation failure there still aborts the retry.
2. `scripts/heartbeat.sh`: whenever it kills a dispatch (the token-outlier kill and the quota run-cap kill), it writes `state/kills/<stage-id>.json` under the repo root with `stage_id`, `role`, `pid`, `reason` (`token-outlier` or `quota-run-cap`), `killed_at` (ISO 8601 UTC, `YYYY-MM-DDTHH:MM:SSZ`) and the figures it acted on (live tokens and multiple, or the weekly percentage moved). A later heartbeat pass never rewrites or removes it. A write failure never stops the kill.
3. `scripts/tick.sh`, `auto_retry_dead_workers`: a stage with a kill record whose `killed_at` is not earlier than the stage's `started_at` is not retried, and the skip is logged with the kill reason. A record older than `started_at` belongs to an earlier attempt and is ignored.
4. `scripts/escalations.sh`: a stage escalation's body names the kill reason and time when `state/kills/<stage-id>.json` exists.
5. `scripts/requeue-stage.sh`: the per-stage purge also removes `state/kills/<stage-id>.json`, so an operator requeue starts clean. `--worktree-only` stays as it is.
6. `docs/tick-loop.md`: extend the "Automatic retry" paragraph with the reaped-worktree rule and the kill record; name `state/kills/` in the state layout if the doc lists one.
7. `scripts/retry-after-reap-smoke.sh` (frozen, written by the orchestrator; do not edit it): (a) the production order (stall-time preserve, reap, retry) retries once with the pinned `wip_commit` unchanged and no second `wip/` branch; (b) a stage whose worktree was reaped with nothing recorded is retried; (c) the real `heartbeat.sh` kills a 25x outlier and leaves a kill record a second pass does not disturb; (d) that killed stage is not retried and its worktree stays; (e) its escalation names `token-outlier`; (f) a kill record older than `started_at` does not block a retry; (g) an operator requeue removes the record.

## Constraints

- No behaviour change to dispatch, verification, landing, budgets, quota gates or the heartbeat's kill thresholds. This card does not change how outliers are measured (see Out of scope).
- The retry still respects card 161's rules: once per stage, never for a halted repo, a live pid, a worker envelope or a deterministic fault, and always through `requeue-stage.sh --keep-budget`.
- `state/kills/` lives under `state/`, which `.gitignore` (`state/**`) already covers; it is never committed.
- No absolute home paths in committed files.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. **Smoke, worker and verifier:** `scripts/retry-after-reap-smoke.sh` exits 0. Base: red at `(a) a preserved and reaped attempt was not retried (status stalled)`, which reproduces the 2026-10-23 production failure.
2. **No regression, worker and verifier:** `scripts/auto-retry-smoke.sh`, `scripts/escalations-smoke.sh`, `scripts/phat-controller-smoke.sh`, `scripts/budget-cap-smoke.sh` and `scripts/state-branch-smoke.sh` exit 0. Base: green.
3. **Quota run-cap kill, verifier:** reading `scripts/heartbeat.sh` shows the quota run-cap kill writes the same record with `reason: quota-run-cap`; `bash -n scripts/heartbeat.sh` passes.
4. **Lint, worker:** `shellcheck -S warning scripts/retry-after-reap-smoke.sh` exits 0, and `scripts/tick.sh`, `scripts/requeue-stage.sh` and `scripts/escalations.sh` gain no new warning-level findings over the base.

## Contract test

- **Test file:** `scripts/retry-after-reap-smoke.sh`
- **Assertions digest:** `sha256:0f10431decdd10bb815488910f8082778c4ddf526fcbd2602a0f77ab08d6b885`
- **Oracle proof:** fails on dev at case (a), the production failure. A throwaway reference (about 30 lines: a worktree-exists check and a kill-record check in `auto_retry_dead_workers`, a `record_kill` helper in the heartbeat python, one purge path in `requeue-stage.sh`, one body line in `escalation_write`) passed every assertion and left the auto-retry, escalations, phat-controller, budget-cap and state-branch smokes green. Mutations each tripped their own case: always preserving (a), ignoring the kill record (d), ignoring `started_at` (f), no record written (c), no purge on requeue (g), no reason in the escalation (e). Traps: case (c) drives the real `heartbeat.sh`, so the heartbeat needs `AUTOMETTA_CODEX_TRANSCRIPT_ROOTS` and at least five baseline rows to measure the outlier (the smoke supplies both); `killed_at` and `started_at` are compared as ISO strings, so both must be in the same `YYYY-MM-DDTHH:MM:SSZ` form. `scripts/outlier-warning-smoke.sh` is red on dev for reasons unrelated to this card and is not a criterion.

## Out of scope

- How the outlier is measured. The live total counts cache reads, so a wide card on a 200K context reaches 15x a median built from narrow cards quickly (card 162's attempt 1). Changing the measure or the threshold is a separate decision for the operator.
- Retrying a killed dispatch automatically, or changing its pairing.
- The silence-kill and wall-clock stall paths beyond what the reaped-worktree rule already covers.

## Budget

- **Worker wall-clock:** 45 minutes (kill at 70)
- **Verifier wall-clock:** 20 minutes
- **Spend basis:** `state/cost-log.jsonl` on 2026-10-23: autometta role median 1.0M tokens, p95 3.7M. Card 161, the nearest precedent, landed on attempt 1. Plan 5M for the stage.

## Dispatch envelope

Write `state/envelopes/163-a-retry-survives-the-reaper.json` using `schemas/envelope.json`. List changed deliverables, the exact smoke commands and their results, and any criterion you could not satisfy with why. If the card itself is wrong, stop with `status: fail` and say so in `notes` rather than working round it. Do not self-verify or land your own branch. The verifier writes `state/verifiers/163-a-retry-survives-the-reaper.json`.

## Family-specific notes

None
