# state/handoffs/

Worker completion envelopes. Every worker writes `<stage-id>.json` here as its final action before exiting. `tick.sh` polls for this file and treats it as the sole signal that worker work is done.

## Contract

- **Path:** `state/handoffs/<stage-id>.json`
- **Schema:** `schemas/handoff-envelope.json`
- **Validator:** `scripts/validate-handoff-envelope.sh <path>`
- **Writer:** the worker, as its last action
- **Reader:** `tick.sh`, once per tick after worker exit

## tick.sh outcomes

| Condition | tick.sh action |
|---|---|
| Envelope present, `status=pass`, valid schema | Dispatch verifier; proceed normally |
| Envelope present, `status=fail`, valid schema | Mark stage `failed`; include envelope `notes` in stall marker; do not dispatch verifier |
| Envelope present, `status=partial`, valid schema | Treat as `fail` (partial is a worker-side annotation; the verifier decides acceptability) |
| Envelope present but schema-invalid | Mark stage `stalled` with marker `worker_envelope_invalid`; move bad file to `<stage-id>.invalid.json` |
| Worker exits cleanly, no envelope written within poll timeout | Mark stage `stalled` with marker `worker_envelope_missing_after_exit` |

## Legacy stages

Stages already recorded as `completed` in `state/state.yaml` before stage 17 was shipped are grandfathered. `tick.sh` does not retroactively require envelopes for them. The envelope contract applies to `pending` and `in_progress` stages from stage 17 onwards.

## Gitignore

`state/handoffs/*.json` and `state/handoffs/*.invalid.json` are gitignored (runtime files). Only `.gitkeep` and this README are committed.
