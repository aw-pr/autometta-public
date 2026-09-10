# state/handoffs/ (legacy)

The worker completion envelope moved to `state/envelopes/<stage-id>.json` (card 104). This directory stays only so a subscriber still vendoring a pre-card-104 worker prompt keeps a writable target; nothing current reads it. New work goes to `state/envelopes/`, whose README carries the contract (`schemas/envelope.json`, `scripts/validate-envelope.sh`, `docs/dispatch-envelope.md`). Only `.gitkeep` and this README are committed; any `*.json` here is gitignored runtime output.
