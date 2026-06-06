---
name: decision-cost-log-and-caching
description: cost-log schema, per-tier rate table, and the OAuth-vs-API prompt-caching finding (instrument first, then measure caching)
metadata:
  type: project
---

The cost-log makes each tick measurable, and is the baseline against which prompt-caching savings are measured rather than assumed. Schema and rate table are documented in `docs/cost-log.md`; the design decisions below are load-bearing.

**Why a JSONL ledger separate from budget.json**

`budget.json` is a single running total that gates the loop. The cost-log (`state/cost-log.jsonl`, one line per dispatched role) is the itemised ledger behind that total, consumed by the FinOps dashboard. Keeping them separate means the gate stays a cheap scalar and the audit trail stays append-only. The cost-log is gitignored runtime state like `logs/`, read from disk by the consumer, not committed.

**Why instrumentation shipped before caching**

The brief was explicit: measure first so the caching saving is real. Phase 1 lands the cost-log (cold-cache baseline, `cache_hit_rate` 0). Phase 2's gate is a repeated-prefix loop showing non-zero `cache_hit_rate` and a lower `cost_usd_est` for the same token shape. `scripts/cost-log-smoke.sh` proves this deterministically offline; `scripts/sdk-cache-smoke.sh` is the live API check.

**Why the rate table lives in scripts/rates.sh keyed by tier**

One file to edit when list prices move. Tier (T1/T2/T4) is derived from the identity string via the agent-orchestrator tier vocabulary, and the rate row hangs off the tier. Unknown identities fall back to T2 so an unrecognised agent is costed, not treated as free.

**Per-route token fidelity is uneven, and the log is honest about it**

Only the SDK verifier route (`cache: write/read/input/output`) and `claude --output-format json` expose a true input/cached/output split. The codex CLI and `claude -p` text routes print a total only, which lands in `input_tokens` with `cache_hit_rate` 0. A 0 hit-rate on those routes means "not visible to us", not necessarily "nothing cached". Cache-creation (write) tokens are folded into `input_tokens` to keep a two-bucket schema; this under-estimates the ~1.25x write premium slightly. See `docs/cost-log.md`.

**The OAuth/subscription vs API caching finding**

Both billing routes cache. The API route (SDK verifier, codex api mode) caching is explicit and returns `cache_read_input_tokens` in the usage block, so the cost-log can measure it. The subscription/OAuth route (`claude -p`, codex chatgpt mode) caches automatically but the default CLI output does not surface cached-token counts, so the saving happens but is not observable from the log. To measure caching, use the API route or the SDK verifier.

**Why the prompt templates were reordered**

`templates/worker-prompt.md` and `templates/verifier-prompt.md` now keep all instructional prose as a byte-identical prefix and push every per-dispatch value into a trailing `## This dispatch` block. That is the "cache breakpoint after the stable prefix, before per-task content" principle applied to the CLI routes (which cache implicitly by prefix). The SDK verifier route already split static/variable explicitly. This also fixed a latent gap: `spawn-worker.sh` never substituted `<<stage-id>>`, so the worker had been inferring its stage id from the card path; the trailing block is now authoritative.

**Relationship to other decisions**

Builds on [[decision-failure-budget-clock-tick]] (the budget gate this ledger sits behind) and [[decision-identity-via-orchestrator-skill]] (the identity strings the tier map reads). The SDK caching mechanics are in `docs/sdk-verifier.md`.
