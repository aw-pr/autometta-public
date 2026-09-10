# state/envelopes/

Where a worker writes its dispatch envelope. Every worker writes `<stage-id>.json` here as its final action before exiting; `tick.sh` polls for that file and treats it as the sole signal that worker work is done.

- **Path:** `state/envelopes/<stage-id>.json`
- **Schema:** `schemas/envelope.json`
- **Validator:** `scripts/validate-envelope.sh <path>`
- **Design and tick.sh outcomes:** `docs/dispatch-envelope.md`

`state/handoffs/` is the legacy location. Only this README is committed; every `*.json` here is gitignored runtime output.
