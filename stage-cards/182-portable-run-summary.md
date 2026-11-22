# Stage card 182: Render a portable run summary

## Metadata

- **Authored:** 2026-11-22
- **Orchestrator:** GPT-6.2 Astra <gpt-6-2-astra@local>
- **Worker:** GPT-6.2 Sol <gpt-6-2-sol@local>
- **Verifier:** Claude Sonnet 5.5 <claude-sonnet-5-5@local>
- **Base branch:** dev
- **Run branch:** autometta/182-portable-run-summary
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Recovery attempts:** 3
- **Recovery attempt:** 1
- **Dispatch:** serial
- **Pairing rationale:** Sol handles the report and historical receipts. Sonnet independently checks retry accounting and privacy.
- **Open decisions:** none
- **Cold read:** Claude Sonnet, pooled read-only preparation review on 22 November 2026.

## Surfacing concern

Preserve what a future clone needs to understand one run. Live queue and budget files already have a local snapshot. A portable report should survive a clone without carrying process data or the operator's machine details.

## Objective

Provide a deterministic read-only renderer for one named run at one finish or halt boundary.

## Inputs

- `scripts/cost-log.sh`
- `scripts/first-attempt-history.sh`
- `scripts/aggregate-dashboard.sh`
- `scripts/lib/lifecycle_events.py`

## Deliverables

1. Implement the renderer and document the small versioned format and its evidence rules in the tick-loop guide.
2. The verifier exercises the frozen fixture plus a disposable mixed-history example with an awaiting stage, an unrelated receipt and missing verdict evidence. Record the observed JSON and confirm that read-only rendering leaves the fixture intact.

## Acceptance criteria

1. `scripts/run-summary.sh REPO RUN_ID finished|halted` emits one UTF-8 JSON object to stdout, with version 1, run_id, outcome and ordered stages. Each stage contains only id, status, verdict, worker_attempts, retries, total_tokens and landed_commit. Use machine-readable identifiers. Exclude raw logs, paths, identities, timings from the host, budget balances and arbitrary prose. No file writes, repository mutations, network or model calls.
2. Count recorded worker dispatches, including diagnosed retries, for the requested run and stage. Retries are worker starts beyond the first. Cache-inclusive total_tokens covers all attributable worker and verifier dispatches across attempts. Use receipt totals once. Inspect existing accounting and history helpers before adding logic. Production cost rows can lack run_id: use stage membership and the UTC run start encoded in run-YYYYMMDD-HHMMSS, disambiguating against other run membership or time bounds where necessary. An explicit different run_id is excluded. Requeue can replace a stage's started_at, so using that as the overall run start drops earlier attempts. Keep missing or ambiguous measures null and preserve known independent measures. An explicitly unknown row makes the total unknown even if its numeric placeholder is zero.
3. Use the recorded independent verdict when attributable to that stage/run, otherwise null. For merged integration prefer rebased_tip then head then the recorded stage commit. A pending, awaiting, failed or superseded stage has no landed SHA unless it actually has a recorded merged integration. An unknown run, unsafe identifier or unsupported outcome exits nonzero without emitting a report. Identical inputs render byte-identically; process only the requested run.

Both seats run `bash scripts/portable-run-summary-contract-smoke.sh` in the run worktree. The independent verifier records actual observations for all criteria, including the edge cases in Deliverables. Missing evidence prevents an overall PASS. Use temporary repos; no live dispatch or subscriber write is part of acceptance.

## Review decisions

A missing verdict or missing dispatch receipts for a known stage produce null fields and a successful report. For untagged receipts, match stage membership and a defensible run interval, including earlier attempts before the latest worker start. Ambiguous attribution yields null.

## Contract test

- **Test file:** `scripts/portable-run-summary-contract-smoke.sh`
- **Assertions digest:** `sha256:01d187b1d1193c8ab6eecdefee1d6741baca6a37da77d72560060a34f2989a74`
- **Oracle proof:** On 4fbfe08 the fixture exits 1 because the renderer is absent. A disposable fixture renderer exercised the JSON shape, repeatability, unknown usage, invalid input and read-only checks.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes
- **Spend basis:** 1.60M cache-inclusive tokens for one pair. Five comparable pairs from stages 179–181 ranged from 0.75M to 2.65M; allow extra implementation work for repo-safe persistence. Batch estimate 4.25M first pass plus 4.25M pooled retry planning headroom. Review preparation at 10% of first-pass estimates. The preparation check across both cards recorded 2,168,213 primary-chat tokens, including 2,137,344 cached input, and 52,153 read-only reviewer tokens, including 24,578 cache reads. This exceeded the 425k preparation checkpoint. Recheck headroom when queueing is authorised.

## Out of scope

No writer, automatic Git commit, historical migration or dashboard changes.

## Dispatch envelope

Worker evidence goes in `state/envelopes/182-portable-run-summary.json`. The independent verifier writes `state/verifiers/182-portable-run-summary.json`.
