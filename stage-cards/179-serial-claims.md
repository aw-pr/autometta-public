# Stage card 179: Keep serial cards out of pipeline pairs

## Metadata

- **Authored:** 2026-11-22
- **Orchestrator:** GPT-6.2 Astra <gpt-6-2-astra@local>
- **Worker:** GPT-6.2 Astra <gpt-6-2-astra@local>
- **Verifier:** Claude Sonnet 5.5 <claude-sonnet-5-5@local>
- **Base branch:** dev
- **Run branch:** autometta/179-serial-claims
- **Proposal:** P-20261118-32de
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Recovery attempts:** 3
- **Recovery attempt:** 1
- **Dispatch:** serial
- **Pairing rationale:** Astra handles queue migration and compatibility across two surfaces. Sonnet independently tests both admission and scheduling.
- **Open decisions:** none
- **Cold read:** Claude Sonnet reviewed the three cards and their frozen tests on 22 November. Commit the cards and tests on dev before admission. The separate verifier observations below are required.

## Surfacing concern

Worker 178 started while verifier 177 was still running. Both cards specified serial dispatch and owned different files. Queue admission persisted only the claims.

## Objective

Carry explicit serial intent through admission and enforce it for either member of a prospective pipeline pair.

## Inputs

- `scripts/add-stage.sh`
- `scripts/tick.sh`
- `schemas/state.yaml.json`
- `scripts/pipeline-pair-smoke.sh`

## Deliverables

Carry explicit serial intent through admission and enforce it for either member of a prospective pipeline pair. Update the relevant production entry points and their schema or documentation where the public record changes.

## Acceptance criteria

1. Keep explicit serial metadata alongside the original path claims in admitted stage state, compatible with the state schema. Consult either member before forming a pair.
2. For a historical row with no dispatch declaration in state, honour the source card declaration if it exists. Existing claims-only pairs that meet the existing gates still overlap.
3. Run the frozen fixture through admission and tail selection. Independently demonstrate that admitted serial intent survives removing the declaration from the card after queueing, and show the tail remains pending without a spawn.

Both seats run `bash scripts/serial-claims-contract-smoke.sh` and `bash scripts/pipeline-pair-smoke.sh` from the run worktree. The verifier independently exercises the normal entry points, records commands and observed results for every criterion, and fails any criterion missing its required evidence. Use isolated temporary fixtures.

## Constraints

Preserve existing frozen tests, accepted digests, unrelated work and existing subscription routing. Exercise model and provider boundaries offline with fixtures. The worker records its dispatch envelope. The verifier supplies independent observations.

## Contract test

- **Test file:** `scripts/serial-claims-contract-smoke.sh`
- **Assertions digest:** `sha256:04e01d5054b4faad9e9d0217526295db199ff04bee9a421450b63f75132dbcb9`
- **Oracle proof:** On base e4227b2, eligible pairing succeeds, then the serial head overlaps. A disposable reference passed the full frozen fixture. The first attempt owes a full positive run through the production entry point as well as the separate regression and independent evidence specified above.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes
- **Spend basis:** Estimate 2.5M cache-inclusive tokens per pair and 7.5M for the first three pairs. Previous comparable medians were 1.17M worker and 1.30M verifier. Track preparation separately at a 250k checkpoint per card. The operator authorised today's scoped token lift. Record diagnosed retries and measured spend separately.

## Dispatch envelope

Write the worker envelope under `state/envelopes/179-serial-claims.json`. Record the independent verdict under `state/verifiers/179-serial-claims.json`.
