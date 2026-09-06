# Stage card 118: the history smoke counts lost tokens the way the ledger does

## Metadata

- **Authored:** 2026-09-06
- **Orchestrator:** Claude Fable 5.1 <claude-fable-5-1@local>
- **Worker:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Verifier:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Base branch:** dev
- **Run branch:** autometta/118-the-history-smoke-counts-lost-tokens-the-way-the-ledger-does
- **Worker effort:** medium
- **Verifier effort:** medium
- **Verifier panel:** false
- **Path claims:** scripts/tui-history-smoke.sh, stage-cards/118-the-history-smoke-counts-lost-tokens-the-way-the-ledger-does.md
- **Pairing rationale:** cross-family. The fix is in a smoke's baseline, and the verifier's job is
  to decide whether the smoke or the aggregator is right; the working seat did
  not write either.
- **Type:** Red-smoke repair. Pipeline-eligible.

## Surfacing concern

`scripts/tui-history-smoke.sh:108` computes expected lost tokens as the
sum of `total_tokens` over rows whose `result != "pass"`. On 2026-09-01 the
aggregator became adjudication-aware (`scripts/aggregate-dashboard.sh:604-641`,
`scripts/adjudicated-spend-smoke.sh`): a landed stage's failed attempts are
not lost. The smoke's fixture has a stage that failed and then landed, so
the aggregator now reports it `LANDED` with zero lost tokens, and the
smoke's stale arithmetic expects `FAIL` and 85,000. The smoke has been red
on clean `dev` since, and card 103 was told it was not that card's to fix.

## Objective

The smoke's independent arithmetic applies the same rule the ledger does:
a failed attempt of a stage that later landed is not lost.

## Inputs (read these in your own context)

- `scripts/tui-history-smoke.sh:60-125`, the fixture and the jq conjunction
- `scripts/aggregate-dashboard.sh:600-660`, the `not_landed` rule
- `scripts/adjudicated-spend-smoke.sh`, for how that rule is already tested

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. The smoke's `expected_lost` excludes rows for stages that landed, using
   the fixture's own `state.yaml` (or the fixture gains one if it has none),
   computed independently in jq, not by calling the aggregator.
2. The `cards[0].result` expectation becomes whatever the fixture's history
   truly is; if the fixture's first card is meant to be a real FAIL, adjust
   the fixture so one stage failed *and did not land* and keep the FAIL
   expectation for it. Say which you chose and why.
3. The frozen block is updated and the digest recorded in this card.

## Constraints

- The aggregator is not touched; if you believe it is wrong, stop under
  the escalation clause.
- The smoke must still fail if `lost_seven_day_tokens` reads 0 when a
  genuinely unlanded failure exists in the fixture.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. `scripts/tui-history-smoke.sh` passes on the run branch.
2. The fixture contains at least one unlanded failed attempt, and the smoke
   asserts a non-zero lost figure for it.
3. Reverting the 2026-09-01 adjudication rule in a scratch copy of the
   aggregator makes the smoke fail; the smoke discriminates.

## Contract test

- **Test file:** scripts/tui-history-smoke.sh
- **Assertions digest:** frame the assertions in a block between the begin
  marker and the end marker, the begin marker naming this card by its
  `card=stage-cards/118-the-history-smoke-counts-lost-tokens-the-way-the-ledger-does.md` field, and replace this line's text with the real
  digest printed by `scripts/check-contract-test-gate.sh print scripts/tui-history-smoke.sh`. Do not
  write a `sha256:` comment inside the block, and do not spell the marker
  tokens anywhere in this card's prose; the card is in your path claims for
  exactly this edit.

## Out of scope

- The two definitions of "tokens" recorded in card 103's out-of-scope.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes

## Escalation

If the aggregator's `not_landed` rule turns out to be wrong for the
fixture's shape (a stage that landed *before* the failed attempt, for
instance), report it with the row and stop; the ledger's rule is the one
to fix, in its own card.

## Verifier handoff

Run criterion 3 yourself: patch the aggregator's rule out in a copy and
run the smoke against it. A smoke that passes against both is the wrong
pass.

## Family-specific notes

None

## Seat history (2026-09-06)

The Codex subscription closed at 10:31Z and this batch was re-seated onto
Claude alone; when Claude session windows then drained faster than the batch
was sized for, the verifying seat moved to the free local route
(`gpt-oss:120b` via `codex exec --oss`). The Codex window reopened the same
afternoon and the card is back on the seats it was authored with. Nothing
about the work changed across either move.
