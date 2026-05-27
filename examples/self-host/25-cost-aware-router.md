# Stage card 25-cost-aware-router: Card-declared complexity tier drives model selection

## Metadata

- **Authored:** 2026-05-27
- **Orchestrator:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Worker:** Codex GPT-5.3 <codex-gpt-5-3@local>
- **Verifier:** Claude Sonnet 4.6 <claude-sonnet-4-6@local>
- **Pairing rationale:** Cross-family. Codex modifies the spawn scripts to read the tier and route accordingly; Sonnet verifies the routing matrix (it's the model being routed *to* in the `standard` tier, so it has a vested interest in the table being correct).
- **Depends on:** 17 (handoff envelope) and 18 (panel verifier — `hard` tier triggers panel mode). 15c (SDK route) is helpful but not strictly required.

## Surfacing concern

Every stage today gets the same default worker / verifier identities — typically Opus or Codex GPT-5.3, both at the high end of the cost curve. Trivial stages (a one-line config edit, a typo fix in docs) and complex stages (a refactor of `tick.sh`, a new schema) cost roughly the same per-tick. The handoff envelope (17) and panel verifier (18) give us the levers to vary by card; what's missing is a declared tier on each card and a routing matrix.

## Objective

Add a `Complexity: trivial | standard | hard` field to the stage card Metadata section. Wire `spawn-worker.sh` and `spawn-verifier.sh` to pick model / identity from a routing matrix keyed on tier + family. `hard` automatically enables panel verifier (per card 18). `trivial` routes to Haiku where possible (cheaper, faster, fine for the work).

## Inputs

- `templates/stage-card.md` — schema for the new field.
- `scripts/spawn-worker.sh`, `scripts/spawn-verifier.sh` — current dispatch.
- `scripts/spawn-verifier-panel.sh` (from card 18) — panel hook.
- `state/budget.json` — current single-bucket budget; this card adds per-tier sub-buckets.
- `examples/self-host/*.md` — backfill: every existing card needs a tier annotation.

## Deliverables

1. `templates/stage-card.md` — add required Metadata field `Complexity: trivial | standard | hard` with a one-line comment on each tier's intent.
2. `scripts/routing-matrix.yaml` — the routing table. Keys: tier + family + role. Values: model identity, budget multiplier. Includes `trivial.claude.worker: claude-haiku-4-5`, `hard.*.verifier: panel`, etc.
3. `scripts/spawn-worker.sh` — read tier from card Metadata, look up routing in `routing-matrix.yaml`, override identity. Fall back to current default if tier is missing (with a stderr warning).
4. `scripts/spawn-verifier.sh` — same. `hard` tier delegates to `spawn-verifier-panel.sh`.
5. `state/budget.json` schema (`schemas/budget.json`) — add per-tier `tokens_spent_<tier>` fields; bump schema version.
6. `scripts/tick.sh` — increment the per-tier counters when accounting for a stage.
7. `examples/self-host/*.md` — backfill: add `Complexity:` to every existing card. (Worker proposes; orchestrator confirms before commit. Default is `standard` unless the card content clearly suggests otherwise.)
8. `docs/cost-router.md` — operator-facing: how to choose a tier, what the routing matrix means, how to read the per-tier budget counters.
9. `memory/decision-cost-router.md` — decision memo. Why card-declared not auto-inferred, why three tiers not five, why the matrix lives in YAML not hard-coded, why `hard` auto-enables panel.

## Constraints

- Backfill changes are mechanical (add one line to Metadata). No prose or acceptance criteria changes on backfilled cards.
- Routing matrix lookup failure (missing key) is a hard error, not a fallback. The matrix must cover every defined tier x family x role combination.
- The current default behaviour (no `Complexity:` field) is `standard` with a stderr warning. After the backfill, no card should hit the warning path.
- Budget schema bump is backwards-compatible (the old `tokens_spent` field stays, the new per-tier fields are additive). `tick.sh` keeps both updated.
- No change to `claude -p` / SDK route choice (orthogonal — card 15c handles that). No change to auth route (orthogonal — already handled).
- British English, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

1. Dispatching a card with `Complexity: trivial` and `Family: claude` selects `claude-haiku-4-5` as the worker identity (per the matrix).
2. Dispatching a card with `Complexity: hard` selects `spawn-verifier-panel.sh` for the verifier (panel mode auto-enabled).
3. Dispatching a card with `Complexity: standard` produces the same identity as today (no behavioural change for the default tier).
4. A card with a missing `Complexity:` field dispatches as `standard` and emits a single stderr line: `cost-router: defaulting to standard for card <id>, add Complexity: field to silence`.
5. A card with an invalid `Complexity:` value (e.g. `medium`) hard-errors before dispatch.
6. `state/budget.json` after a `trivial` dispatch shows non-zero `tokens_spent_trivial` and `tokens_spent` (the legacy aggregate field) is the sum of all per-tier fields.
7. `scripts/routing-matrix.yaml` has full coverage: every combination of (tier, family, role) has an entry.
8. All existing cards under `examples/self-host/` have a `Complexity:` field after backfill.
9. `docs/cost-router.md` documents the tier intent, the matrix, and the budget counters.
10. `memory/decision-cost-router.md` links to `[[decision-panel-verifier]]` and `[[decision-handoff-envelope]]`.
11. No regressions in stages 06-14 re-dispatched under their new (backfilled) tier.

## Out of scope

- Auto-inferring tier from card content. v1 is card-declared only.
- Cost ceilings per tier (hard cap). v1 tracks; future card enforces.
- Per-tier wall-clock budgets. v1 keeps the existing single wall-clock cap.
- More than three tiers.
- Routing across providers (e.g. trivial -> open-weights model). Anthropic + OpenAI families only.

## Budget

- **Worker wall-clock:** 75 minutes (the backfill of existing cards is mechanical but covers 15 files).
- **Verifier wall-clock:** 30 minutes.

## Verifier handoff

Worker writes the deliverables, runs three smoke dispatches (one per tier) against the trivial test cards from card 23 (or a fresh one if 23 hasn't landed), and pastes the resolved identity per tier in completion message. Worker writes `state/handoffs/25-cost-aware-router.json`. Verifier reads card, deliverables, and the routing matrix, confirms full coverage of (tier x family x role), and writes `state/verifiers/25-cost-aware-router.json`.

## Family-specific notes

- **Codex (worker):** stdin redirect on subprocess invocation in the modified spawn scripts.
- **Sonnet (verifier):** identity is in the routing matrix being verified. Verifier must not edit the matrix to favour itself (no, really — this is the only stage where the verifier has an editorial stake).
