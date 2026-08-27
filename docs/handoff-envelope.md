# Handoff envelope

A worker writes a JSON file to `state/handoffs/<stage-id>.json` as its final action. `tick.sh` treats this file as the sole completion signal. Process exit and log-tail inspection are fallback stuck-worker signals only, not success signals.

## Shape

```json
{
  "stage_id": "17-structured-worker-handoff-envelope",
  "status": "pass",
  "deliverables": [
    "schemas/handoff-envelope.json",
    "templates/worker-prompt.md"
  ],
  "notes": "All seven deliverables written. Acceptance criteria 1-9 believed satisfied.",
  "worker_identity": "GPT-5.6 Sol <gpt-5-6-sol@local>"
}
```

Required fields: `stage_id`, `status`, `deliverables`, `notes`. Optional: `failed_acceptance`, `worker_identity`. Full schema: `schemas/handoff-envelope.json`. Validator: `scripts/validate-handoff-envelope.sh`.

## Why a file, not a tool call or log pattern

A file on disk is the only completion signal that works identically for both worker families (Codex in `workspace-write` sandbox, Claude in headless `claude -p` mode). Tool calls are family-specific; log patterns are fragile — a worker that prints "done" mid-stream can be falsely classified. A file written as the last action is atomic on POSIX and inspectable without re-running the worker.

## tick.sh outcomes

The five outcomes tick.sh implements once a worker process exits:

### 1. status=pass, valid envelope

tick.sh proceeds to verifier dispatch as normal. The worker's working tree changes remain dirty for the verifier to inspect. No log file is read for the completion decision.

### 2. status=fail, valid envelope

tick.sh marks the stage `failed` immediately and does not dispatch a verifier. The envelope's `notes` field is written verbatim to the stage's `stall_marker` in state.yaml so the operator can read the reason without opening the envelope file. No verifier runs over a run its own author disowns.

### 2a. status=partial, valid envelope

tick.sh takes the same path as `pass`: it dispatches the verifier, and additionally stamps `worker_envelope: partial` on the stage stanza as the audit trail.

`partial` is a worker-side annotation, not a verdict. It means "substantially done, some criteria deferred", and who decides whether that is acceptable is the verifier, not the worker. This matters because of the sandbox boundary: a worker that honestly reports it could not check a criterion from inside its sandbox is describing exactly the condition the boundary exists to create. Closing the stage as failed on that report throws away a build the verifier would have passed, and it teaches workers that honesty about a deferred criterion costs them the stage.

`spawn-verifier.sh` reads the envelope back off disk at dispatch time and, on `partial`, substitutes the worker's notes into the verifier prompt's family-specific-notes slot in place of "None", instructing the verifier to treat the deferred criteria as its checklist. The SDK transport (`scripts/verify-sdk.py --worker-notes`) carries the same text in its per-stage variable block, never the cacheable static block.

### 3. Worker exits cleanly, no envelope written

tick.sh marks the stage `stalled` with `stall_marker = "worker_envelope_missing_after_exit"`. The working tree is left intact for operator review. This is the most likely failure mode for workers running on the old prompt template before stage 17.

### 4. Envelope present but schema-invalid

tick.sh moves the bad file to `state/handoffs/<stage-id>.invalid.json`, marks the stage `stalled` with `stall_marker = "worker_envelope_invalid"`, and logs the validation failure. The operator can inspect the invalid file without it being overwritten on the next tick.

## Legacy stages

Stages already recorded as `completed` in state.yaml before stage 17 was shipped are grandfathered. tick.sh does not retroactively require envelopes for them. Envelope enforcement applies only to stages that transition from `pending` to `in_progress` after stage 17 is committed — i.e., stages whose worker dispatch goes through the updated `spawn-worker.sh` and worker prompt template.

## Operator checklist when a stage stalls on envelope reasons

- `worker_envelope_missing_after_exit`: the worker was dispatched with the old prompt template or crashed before its final action. Check the worker log at `state/logs/<stage-id>-worker.log`. Re-dispatch after updating the prompt.
- `worker_envelope_invalid`: inspect `state/handoffs/<stage-id>.invalid.json`. Correct the prompt or the worker logic, then delete the invalid file and re-queue the stage.
