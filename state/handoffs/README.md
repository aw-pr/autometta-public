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
| Envelope present, `status=partial`, valid schema | Dispatch verifier, as for `pass`; stamp `worker_envelope: partial` on the stage stanza and hand the envelope `notes` to the verifier as its checklist |
| Envelope present but schema-invalid | Mark stage `stalled` with marker `worker_envelope_invalid`; move bad file to `<stage-id>.invalid.json` |
| Worker exits cleanly, no envelope written within poll timeout | Mark stage `stalled` with marker `worker_envelope_missing_after_exit` |

`partial` is a worker-side annotation, not a verdict. It means the worker believes the work is substantially done but deferred some criteria, most often because its sandbox stopped it checking them. The verifier decides whether that is acceptable, so the stage goes to the verifier rather than closing as failed. See `docs/handoff-envelope.md`.

## Legacy stages

Stages already recorded as `completed` in `state/state.yaml` before stage 17 was shipped are grandfathered. `tick.sh` does not retroactively require envelopes for them. The envelope contract applies to `pending` and `in_progress` stages from stage 17 onwards.

## Gitignore

`state/handoffs/*.json` and `state/handoffs/*.invalid.json` are gitignored (runtime files). Only `.gitkeep` and this README are committed.
