# Stage card 17-structured-worker-handoff-envelope: Worker emits a JSON handoff envelope as the sole completion signal

## Metadata

- **Authored:** 2026-05-27
- **Orchestrator:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Worker:** Codex GPT-5.3 <codex-gpt-5-3@local>
- **Verifier:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Pairing rationale:** Cross-family. Codex changes the worker prompt template and the spawn script's parse step; Claude verifies that the envelope is the only completion signal `tick.sh` keys off.

## Surfacing concern

Today the controller decides a worker is done by scraping its log file (`/tmp/<family>-<stage>.log`) for end-of-run patterns or by waiting for the process to exit. That is fragile: a worker that prints "done" mid-stream can be falsely classified, and a worker that exits cleanly without writing anything to its tail buffer can be missed. The Codex side already produces a structured exit; the Claude side does not.

## Objective

Define a single JSON handoff envelope shape (`{stage_id, status, deliverables, notes}`) that every worker writes to a predictable path on completion. Update `templates/worker-prompt.md` to require it. Update `scripts/tick.sh` to treat the envelope as the sole signal that worker work is done. Process exit + log tail remain available as fallback signals for genuinely stuck workers, not as success signals.

## Inputs

- `templates/worker-prompt.md` — current worker prompt template.
- `scripts/tick.sh` — the controller tick that currently decides worker completion.
- `scripts/spawn-worker.sh` — for context on how workers are launched.
- `state/verifiers/14-auth-route-toggle.json` — exemplar for "single JSON file as a stage signal".
- `schemas/state.yaml.json` — convention for `$id` / `$schema` / docstrings.

## Deliverables

1. `schemas/handoff-envelope.json` — JSON Schema 2020-12 for `state/handoffs/<stage-id>.json`. Required keys: `stage_id`, `status` (enum: `pass`, `fail`, `partial`), `deliverables` (array of relative paths), `notes` (string). Optional: `failed_acceptance` (array of criterion indices), `worker_identity`.
2. `templates/worker-prompt.md` — add a final "Handoff envelope" section instructing the worker to write `state/handoffs/<STAGE_ID>.json` as its last action, with a literal example.
3. `scripts/tick.sh` — change worker-completion detection to: poll for the envelope file, validate against the schema, then transition. Process-exit and log-tail are downgraded to "stuck-worker" signals only. Add a `worker_envelope_missing_after_exit` failure mode that stalls the stage with a clear marker.
4. `state/handoffs/` directory (with a `.gitkeep`) and a `state/handoffs/README.md` explaining the envelope contract.
5. `scripts/validate-handoff-envelope.sh` — one-shot validator for any `state/handoffs/*.json`.
6. `docs/handoff-envelope.md` — one-pager: what the envelope is, why it exists, what happens when it is missing or malformed, fallback behaviour for legacy stages.
7. `memory/decision-handoff-envelope.md` — decision memo. Why JSON file rather than tool call, why this is a worker contract rather than a per-family extension, why the envelope is mandatory for new stages but legacy stages stay grandfathered.

## Constraints

- Stages already in `state/state.yaml.stages[]` as `completed` are not retroactively re-checked. Envelope is enforced for `pending` and `in_progress` stages going forward.
- The envelope must be writable from inside a `workspace-write` codex sandbox (the path is in-tree). No new sandbox writes required.
- `tick.sh` must continue to terminate cleanly within its existing wall-clock budget. The envelope poll has a hard timeout (use the existing `clock_tick_budget_remaining` field as the bound).
- No changes to verifier flow (`spawn-verifier.sh`, `verify-sdk.py`, `schemas/verifier.json`).
- No changes to the controller's halt / failure-cap semantics.

## Acceptance criteria

1. `schemas/handoff-envelope.json` validates: a hand-written sample envelope; an envelope produced by a Codex worker dispatched against a trivial test card.
2. `scripts/validate-handoff-envelope.sh state/handoffs/<stage-id>.json` exits 0 for valid, non-zero with a clear message for invalid.
3. With a worker that writes a `status=pass` envelope, `tick.sh` transitions the stage to `in_progress -> completed (subject to verifier)` and never reads the worker log file for completion.
4. With a worker that writes a `status=fail` envelope, `tick.sh` transitions the stage to `failed` without dispatching the verifier and includes the envelope `notes` in the stall marker.
5. With a worker that exits cleanly but writes no envelope, `tick.sh` marks the stage `stalled` with marker `worker_envelope_missing_after_exit` after the poll timeout.
6. With a worker that writes a malformed envelope (fails schema validation), `tick.sh` marks the stage `stalled` with marker `worker_envelope_invalid` and moves the bad file to `state/handoffs/<stage-id>.invalid.json`.
7. `templates/worker-prompt.md` includes a literal example envelope and the explicit instruction "write this file as your final action".
8. `docs/handoff-envelope.md` documents the four `tick.sh` outcomes from acceptance #3-#6.
9. Re-running stage 14 (a completed legacy stage) does not change its `state/state.yaml` record (grandfathering invariant).
10. The cd-fix at `9e282f3` is not reverted.

## Out of scope

- Verifier handoff envelope. The verifier already writes `state/verifiers/<stage-id>.json`; that is the verifier's envelope. Naming convention parallel is intentional.
- Per-family worker tool-call surface (Anthropic SDK tool call as the envelope source). The file-on-disk approach works for both families uniformly.
- Backfilling envelopes for historical stages.
- A worker library that writes the envelope for you. The prompt instructs the worker to write it; no abstraction layer.

## Budget

- **Worker wall-clock:** 45 minutes.
- **Verifier wall-clock:** 25 minutes.

## Verifier handoff

Worker writes the deliverables and runs the four `tick.sh` outcome scenarios from acceptance #3-#6 against a trivial test card (`/tmp/test-card.md`), pasting the resulting `state.yaml` diff for each in its completion message. Worker also writes its own handoff envelope at `state/handoffs/17-structured-worker-handoff-envelope.json` per the new contract (this is the dogfood). Verifier reads card and deliverables, re-runs at least the `status=pass` and `envelope_missing` scenarios, and writes `state/verifiers/17-structured-worker-handoff-envelope.json`.

## Family-specific notes

- **Codex (worker):** stdin redirect for any subprocess invocation in the modified `tick.sh` (lessons.md #1). The envelope file is a write inside the repo tree; `workspace-write` is sufficient.
- **Claude (verifier):** runs outside the worker sandbox per the cross-family invariant. The verifier may invoke `tick.sh` directly against test cards to reproduce the four outcomes.
