# Stage card 176: Count interrupted dispatch usage once

## Metadata

- **Authored:** 2026-11-18
- **Orchestrator:** GPT-6.1 Sol <gpt-6-1-sol@local>
- **Worker:** GPT-6.2 Astra <gpt-6-2-astra@local>
- **Verifier:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Base branch:** dev
- **Run branch:** autometta/176-interrupted-dispatch-spend
- **Proposal:** P-20261117-d14d
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Recovery attempts:** 3
- **Recovery attempt:** 1
- **Dispatch:** serial
- **Path claims:** scripts/tick.sh, scripts/budget.sh, scripts/cost-log.sh, docs/cost-log.md
- **Pairing rationale:** Premium Codex worker and independent Claude verifier as approved for this harness batch. The worker must reconcile existing callers and archived formats. Verification requires judgement about the evidence from the normal entry points. Run one card at a time because the changes affect shared harness behaviour.
- **Open decisions:** none
- **Cold read:** Claude Sonnet, pooled read-only review on 2026-11-18. Findings and resolutions below.
- **Related proposal:** P-20261117-1f55

## Surfacing concern

A refused worker reported 410,797 tokens that the run did not charge. A separate aborted verifier had 176,459 cumulative tokens in the transcript and a 120,712-token earlier sample. The two incidents share the requirement that an interrupted role has one final charge.

## Objective

Align the per-dispatch cost row, rolling-window spend and lifetime spend for quota-refused workers and aborted Codex verifiers.

## Inputs

- `scripts/tick.sh`
- `scripts/budget.sh`
- `scripts/cost-log.sh`
- `docs/cost-log.md`
- `scripts/interrupted-spend-smoke.sh`

## Deliverables

1. `scripts/tick.sh` Account for interrupted roles through the existing tick paths and persist retry-safe dispatch identity.
2. `scripts/budget.sh` Select the final matched cumulative evidence and apply the budget charge once.
3. `scripts/cost-log.sh` Write or recover one cost row with accurate usage provenance for each interrupted dispatch.
4. `docs/cost-log.md` Document cumulative-source selection, dispatch identity and partial-write recovery.

## Constraints

Keep the existing frozen tests and digests intact. Use temporary fixtures for acceptance. The worker writes its envelope and the verifier writes an independent verdict with observed results for each criterion.

## Acceptance criteria

1. A quota-refused worker with measured usage contributes its charge before rewind. Preserve the existing refusal pause, retry count, work preservation and failure classification. Distinguish unavailable usage from a measured zero in the cost record.
2. For an aborted Codex verifier use the latest valid cumulative usage for its own dispatch. Keep legacy token_count-only and log-only inputs working. Use thread totals rather than summing per-response totals. Preserve cache components and exclude other dispatches in the same worktree.
3. Replaying the same dead PID and start time after an interrupted reap must leave exactly one cost row and one budget charge. A subsequent genuinely distinct dispatch must be charged separately. Document the durable identity, ordering of writes and recovery when one side was already recorded. Independently replay both partial-store cases and the distinct dispatch with the frozen smoke.

Both seats run `bash scripts/interrupted-spend-smoke.sh`. The judging seat is the independent Claude verifier. Run these regression commands separately from the repository root:

- `bash scripts/cost-log-smoke.sh`
- `bash scripts/limit-refusal-keeps-work-smoke.sh`

## Review decisions

Use stage, role and dispatch identity (including process and original start time, or the existing equivalent) so a redispatch on the same stage has a separate charge. In transcript order, use the newest valid cumulative record for the matched dispatch, checking that components are coherent; skip malformed records and retain the last valid measurement. A per-response delta cannot stand in for a cumulative total. Exercise budget-only and row-only interruptions as well as full replay, a new PID, zero usage, unavailable usage, and older or unrelated sessions. Only the temporary fixture budget and ledger may change. The storage format for idempotence is the worker’s design choice.

Both cost-log and limit-refusal preservation regressions passed on the preparation base.

## Contract test

- **Test file:** `scripts/interrupted-spend-smoke.sh`
- **Assertions digest:** `sha256:c670af3a3e62440f508a83bce424473b1aaeb2bae4207eeed1d5349a2f76ceec`
- **Oracle proof:** Base `d93e651` is red. The real rewind leaves prior spend at 10. The aborted verifier charges 120,712 instead of 176,459. Each case runs independently and all model launches are held. Both role-specific base failures were observed independently: the refused worker left window spend at 10, and the aborted verifier left 120,722 including 10 previous tokens. Its cost row correctly showed the earlier legacy sample and the aborted classification. Those observations exercise the real reactor and the transcript-control path. Recovery after a partially applied update is also frozen. A complete positive accounting reference would duplicate the durable bookkeeping being commissioned.

## Out of scope

Fleet dispatch, provider spend authorisation, publishing, policy changes and alterations to earlier contracts.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes
- **Spend basis:** The nine nonzero November worker rows and nine verifier rows in the repo cost log had medians of 975,595 and 972,937 cache-inclusive tokens. Allow 1.95M for one pair, including about 1.80M cached input by the sum of role medians. A diagnosed retry is another pair. The batch estimate is 7.79M first-pass plus 9.90M pooled outlier allowance (sum of role p95s). Four separate retries would add about 7.79M. Preparation checkpoint is 195k cache-inclusive per card, including the shared cold read. The wall-clock ceilings allow diagnostic replay and exceed the November role p95s of 17m06s and 11m12s. The pooled cold read used 113,248 cache-inclusive tokens (66,252 cache reads, 43,407 cache writes). At the final readiness check the shared Codex preparation turn had reached 11.20M cache-inclusive tokens, including 11.09M cached input. This exceeded the 780k batch checkpoint. Stop additional preparation experiments; any execution and its spend need the separate queue decision.

## Dispatch envelope

Write the worker evidence to `state/envelopes/176-interrupted-dispatch-spend.json`. The verifier records commands, exit codes, the observed fixture values and any missing evidence in `state/verifiers/176-interrupted-dispatch-spend.json`; missing evidence prevents overall PASS. Keep the verifier evidence independent of the worker's interpretation.

## Family-specific notes

Run offline fixtures locally. A missing or skipped required result prevents acceptance.
