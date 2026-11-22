# Stage card 181: Resolve equivalent repo paths in scoped headroom reports

## Metadata

- **Authored:** 2026-11-22
- **Orchestrator:** GPT-6.2 Astra <gpt-6-2-astra@local>
- **Worker:** GPT-6.2 Sol <gpt-6-2-sol@local>
- **Verifier:** Claude Sonnet 5.5 <claude-sonnet-5-5@local>
- **Base branch:** dev
- **Run branch:** autometta/181-scoped-headroom
- **Proposal:** P-20261122-5139
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Recovery attempts:** 3
- **Recovery attempt:** 1
- **Dispatch:** serial
- **Gate:** stage-completed: 180-verifier-clock
- **Pairing rationale:** Sol handles the small path-resolution change. Sonnet checks cap isolation and backwards compatibility.
- **Open decisions:** none
- **Cold read:** Claude Sonnet reviewed the three cards and their frozen tests on 22 November. Commit the cards and tests on dev before admission. The separate verifier observations below are required.

## Surfacing concern

The same read-only request showed a 300M resting cap with a relative path and the active 1B scoped lift with its canonical path.

## Objective

Use the physical repository directory consistently for all reads in the headroom report.

## Inputs

- `scripts/readiness-headroom.sh`
- `scripts/budget.sh`
- `scripts/readiness-headroom-contract-smoke.sh`

## Deliverables

Use the physical repository directory consistently for all reads in the headroom report. Update the relevant production entry points and their schema or documentation where the public record changes.

## Acceptance criteria

1. An existing directory given by canonical path, relative path with dot components or symlink produces the same scoped cap, spend, headroom and shortfalls.
2. A different repo keeps its own resting cap. Reject an absent directory with nonzero exit. The report leaves budgets, drains and filesystem inputs intact, including an expired scoped lift. The verifier records the expired case from the original stage 178 frozen regression, which compares the drain before and after the read.
3. Pass the original frozen headroom contract and the new equivalence fixture, using only isolated directories. Keep existing JSON field names, arithmetic and precedence.

Both seats run `bash scripts/scoped-headroom-contract-smoke.sh` and `bash scripts/readiness-headroom-contract-smoke.sh` from the run worktree. The verifier independently exercises the normal entry points, records commands and observed results for every criterion, and fails any criterion missing its required evidence. Use isolated temporary fixtures.

## Constraints

Preserve existing frozen tests, accepted digests, unrelated work and existing subscription routing. Exercise model and provider boundaries offline with fixtures. The worker records its dispatch envelope. The verifier supplies independent observations.

## Contract test

- **Test file:** `scripts/scoped-headroom-contract-smoke.sh`
- **Assertions digest:** `sha256:0fde50ba7b6dedca16de13f23b389a2dd9d50dd909367b8339943c235a89ef9e`
- **Oracle proof:** On base e4227b2, the absolute case passes and ./repo gets the wrong cap. A disposable reference passed the full frozen fixture. The first attempt owes a full positive run through the production entry point as well as the separate regression and independent evidence specified above.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes
- **Spend basis:** Estimate 2.5M cache-inclusive tokens per pair and 7.5M for the first three pairs. Previous comparable medians were 1.17M worker and 1.30M verifier. Track preparation separately at a 250k checkpoint per card. The operator authorised today's scoped token lift. Record diagnosed retries and measured spend separately.

## Dispatch envelope

Write the worker envelope under `state/envelopes/181-scoped-headroom.json`. Record the independent verdict under `state/verifiers/181-scoped-headroom.json`.
