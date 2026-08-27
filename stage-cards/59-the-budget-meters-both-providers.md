# Stage card 59: the budget meters both providers

## Metadata

- **Authored:** 2026-08-24
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Base branch:** dev
- **Run branch:** autometta/59-the-budget-meters-both-providers
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Pairing rationale:** the defect is in how a codex transcript is read, so
  the family that writes those transcripts does the reading, and the family
  whose accounting already works verifies the result against its own.

## Objective

`state/budget.json` meters one provider. Codex dispatches record
`output_tokens` as zero on nearly every row of `state/cost-log.jsonl`, and
input tokens only sometimes. On the evening of 2026-08-24 the log read
155.4M Anthropic against 1.0M OpenAI, which is not a real ratio.

Two rows show the shape of it. Stage 44's codex worker is recorded as
`in=40 cached=40 out=20` for a change that passed verification. Stage 54's
codex worker is recorded as `in=101 out=10` for restoring a preserved
commit and finishing an 839-line implementation.

The consequence is not a reporting inconvenience. `tokens_spent` is the
number every cap is compared against, so a drain cap, a token cap and the
host defaults from card 47 all constrain Anthropic dispatches and none of
them constrain codex. A codex-worked night runs unmetered.

After this card, a codex dispatch's real usage reaches the cost log and the
budget, or the tick says plainly that it could not read it.

## Inputs (read these in your own context)

- `state/cost-log.jsonl`, particularly every row whose identity is a Codex
  or GPT identity, against the same stages' Anthropic rows.
- `budget_account_tokens_from_dispatch` and the transcript reader it calls.
- `docs/cost-log.md`, the schema and the prompt-caching notes.
- `scripts/rates.sh`, for how a tier turns usage into `cost_usd_est`.

## Deliverables

1. A codex dispatch's input, cached-input and output token counts recorded
   as accurately as the Anthropic path records them, from whatever the
   codex CLI actually emits.
2. Where a count genuinely cannot be recovered, the row says so explicitly
   rather than recording a zero. A zero and an unknown are different facts
   and the budget must not treat them alike.
3. A tick-time warning when a dispatch completes and its usage could not be
   read, so an unmetered run is visible on the night rather than in a later
   audit.
4. `docs/cost-log.md` updated to state which fields each family populates
   and what an unknown looks like.

## Constraints

- Do not estimate usage from wall-clock, log size, or diff size. An
  invented number in a field that gates spend is worse than an absent one.
- Historical rows stay as they are. This card fixes the reader, it does not
  rewrite the log.
- No change to what the caps mean or to their values.

## Acceptance criteria

1. A real codex worker dispatch records non-zero output tokens, shown
   against the run's own transcript.
2. A real codex verifier dispatch does the same.
3. The recorded totals for one stage reconcile with that stage's `tokens`
   in `state.yaml`.
4. A dispatch whose usage cannot be read produces an explicit unknown in
   the row and a warning in the tick log, demonstrated by a fixture.
5. `budget_spend_caps_blown` counts a codex dispatch's usage. Show a cap
   being reached by codex spend alone.
6. The Anthropic path is unchanged, shown by a before-and-after row for one
   Anthropic dispatch.

## Contract test

Replay a stage with a codex worker and an Anthropic verifier. The sum of
the two roles' recorded usage must reconcile with the stage's `tokens`, and
neither role may contribute a zero it did not earn.

## Out of scope

- Rewriting historical cost-log rows.
- Any change to tier pricing in `scripts/rates.sh`.
- Per-provider caps. This card makes one meter honest; splitting it is a
  separate decision.

## Budget

- **Worker wall-clock:** 90 minutes
- **Verifier wall-clock:** 45 minutes

## Verifier handoff

Return the recorded rows for both roles of the replayed stage, the
reconciliation against `state.yaml`, the unknown-usage fixture with its
warning, and the cap demonstrably reached by codex spend alone.

## Family-specific notes

None
