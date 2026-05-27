# Stage card 26-replay-verification-design: Design document for recorded-replay verification (canonical-pass as pre-check)

## Metadata

- **Authored:** 2026-05-27
- **Orchestrator:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Worker:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Verifier:** Codex GPT-5.3 <codex-gpt-5-3@local>
- **Pairing rationale:** Design-only; same shape as cards 20, 22, 24.
- **Type:** Design-only. Tier 3 — speculative. The expected outcome of the design is "interesting but not yet justified"; the value of the design is forcing an explicit answer rather than leaving it as a recurring open question.

## Surfacing concern

The Agent SDK supports recording and replay of sessions. A passing verifier run is, in principle, a labelled positive example: "this verifier prompt, this card, this artefact set, produced PASS". Future runs of the same stage could in principle be pre-checked against the recording as a cheap "does this look like the canonical pass?" probe before invoking the full verifier. The honest question is whether the cost saved is worth the indirection added. This card forces a design and a decision.

## Objective

Produce a design document at `docs/design/replay-verification.md` specifying: what a verifier recording contains, where recordings are stored, how a new run is compared to a recording (similarity metric, threshold), what happens when the new run diverges (fall through to full verifier? auto-fail? auto-pass with audit flag?), how recordings are kept current as the rubric evolves, and an explicit verdict on "is this worth building?".

## Inputs

- `docs/philosophy.md` — load-bearing beliefs.
- `templates/verifier-prompt.md` — what gets recorded.
- `state/verifiers/*.json` — exemplar verifier outputs (what a "canonical pass" looks like in its current form).
- `scripts/verify-sdk.py` (from 15c) — the SDK surface that recording would attach to.
- `docs/sdk-verifier.md` — for SDK-specific assumptions.

## Deliverables

1. `docs/design/replay-verification.md` — the design document. Required sections: Problem statement; What a recording contains (raw turns? rubric output only? token-level?); Storage (where, how versioned, cache-bust rules); Similarity metric and threshold; Divergence handling (with explicit choice among the three options listed in Objective); Recording staleness (when does a recording become misleading?); Cost analysis (estimated savings vs added complexity); Verdict (build / defer / abandon); If build, smallest-possible-prototype card outline.
2. `memory/decision-replay-verification.md` — decision memo. The verdict and its reasoning, what would change the verdict in future, what concrete signal would trigger picking this back up.
3. `docs/philosophy.md` — minimal edit (≤ 3 lines): add as a "considered" item with the verdict.

## Constraints

- The design must reach an explicit verdict in the Verdict section. "Build", "defer", or "abandon" — pick one with reasoning. No hedging.
- The Cost analysis must be concrete: estimate token savings per stage from a successful pre-check hit, and indirection cost from a miss (full verifier still runs).
- The Divergence handling section must pick one of the three options or argue for a fourth with reasoning.
- The design must respect the existing verifier rubric (`schemas/verifier.json`) — a replay-based pre-check is not a substitute for the rubric, it is a pre-filter.
- Prose budget: ≤ 1500 words across all deliverables.
- British English, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

1. `docs/design/replay-verification.md` exists with the nine required sections.
2. The Verdict section is one paragraph and picks exactly one of: build, defer, abandon.
3. The Cost analysis includes a per-stage token estimate (with assumptions stated).
4. The Divergence handling section picks one of the three documented options or argues for a fourth.
5. The Storage section addresses the cache-bust rules when `templates/verifier-prompt.md` or `schemas/verifier.json` changes.
6. The Recording staleness section gives a concrete TTL or revision-pinning rule.
7. `memory/decision-replay-verification.md` follows the decision-memo format and links to `[[decision-sdk-verifier-prompt-cache]]` (sibling cost-saving mechanism).
8. `docs/philosophy.md` edit is additive and at most three lines.
9. Total prose under 1500 words. No em dashes, no AI-tell vocabulary.
10. No code change. Every script and schema is byte-identical.

## Out of scope

- Implementing replay verification.
- Choosing a similarity-metric library.
- Replay for the worker step (only the verifier is considered here).
- Cross-stage replay (using stage A's recording to pre-check stage B). Single-stage only.

## Budget

- **Worker wall-clock:** 60 minutes.
- **Verifier wall-clock:** 25 minutes.

## Verifier handoff

Worker writes deliverables and a one-paragraph executive summary in handoff envelope. Worker writes `state/handoffs/26-replay-verification-design.json`. Verifier reads card and deliverables, confirms the Verdict section commits to one of the three options, and writes `state/verifiers/26-replay-verification-design.json`.

## Family-specific notes

None. Pure design + prose card.
