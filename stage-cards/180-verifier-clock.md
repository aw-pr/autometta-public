# Stage card 180: Record observed verifier completion per dispatch

## Metadata

- **Authored:** 2026-11-22
- **Orchestrator:** GPT-6.2 Astra <gpt-6-2-astra@local>
- **Worker:** Claude Sonnet 5.5 <claude-sonnet-5-5@local>
- **Verifier:** GPT-6.2 Sol <gpt-6-2-sol@local>
- **Base branch:** dev
- **Run branch:** autometta/180-verifier-clock
- **Proposal:** P-20261117-ed15
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Recovery attempts:** 3
- **Recovery attempt:** 1
- **Dispatch:** serial
- **Gate:** stage-completed: 179-serial-claims
- **Pairing rationale:** Sonnet implements the cross-run state handling. Codex independently checks timestamp provenance, replay and old records.
- **Open decisions:** none
- **Cold read:** Claude Sonnet reviewed the three cards and their frozen tests on 22 November. Commit the cards and tests on dev before admission. The separate verifier observations below are required.

## Surfacing concern

Jev 08 and contract-crawler 32 had independently accepted evidence, but their reports were already present minutes before their model-authored completion times.

## Objective

Timestamp verdict consumption at the first harness observation of a finished verifier. Use this time for finding freshness and report chronology.

## Inputs

- `scripts/tick.sh`
- `scripts/proposals.sh`
- `schemas/state.yaml.json`
- `scripts/proposals-smoke.sh`

## Deliverables

Timestamp verdict consumption at the first harness observation of a finished verifier. Use this time for finding freshness and report chronology. Update the relevant production entry points and their schema or documentation where the public record changes.

## Acceptance criteria

1. At the normal consume_verifier_artefact boundary persist a UTC ISO timestamp in stage state as verifier_completed_at for a finished verifier, for PASS and FAIL, including an orphan handled through this boundary. Preserve the original report fields. Document the distinct meanings of reported and observed times and expose the observed field in the state schema.
2. The first observation for a dispatch survives replay. A fresh verifier attempt gets its own stamp even when the same stage and artefact path are reused. Never bind an older receipt to a newer report. Cover requeue/reset and any stale-authority boundary.
3. Use the matching harness observation for proposals unlifted freshness. A legacy report without a matching receipt uses its historical ran_at. Preserve both re-verification discovery and suppression of already cited findings. Verify an actual second attempt and orphan consumption with durable evidence beyond the frozen core.

Both seats run `bash scripts/verifier-clock-contract-smoke.sh` and `bash scripts/proposals-smoke.sh` from the run worktree. The verifier independently exercises the normal entry points, records commands and observed results for every criterion, and fails any criterion missing its required evidence. Use isolated temporary fixtures.

## Constraints

Preserve existing frozen tests, accepted digests, unrelated work and existing subscription routing. Exercise model and provider boundaries offline with fixtures. The worker records its dispatch envelope. The verifier supplies independent observations.

## Contract test

- **Test file:** `scripts/verifier-clock-contract-smoke.sh`
- **Assertions digest:** `sha256:eb95160b1fdcd2ae6e561bfaf42bc6a52a758faee0b63d0568df9979964285b8`
- **Oracle proof:** On base e4227b2, no harness clock in stage state at the real intake boundary. A disposable reference passed the full frozen fixture. The first attempt owes a full positive run through the production entry point as well as the separate regression and independent evidence specified above.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes
- **Spend basis:** Estimate 2.5M cache-inclusive tokens per pair and 7.5M for the first three pairs. Previous comparable medians were 1.17M worker and 1.30M verifier. Track preparation separately at a 250k checkpoint per card. The operator authorised today's scoped token lift. Record diagnosed retries and measured spend separately.

## Dispatch envelope

Write the worker envelope under `state/envelopes/180-verifier-clock.json`. Record the independent verdict under `state/verifiers/180-verifier-clock.json`.
