# Stage card 24-memory-federation-design: Design document for cross-repo memory federation

## Metadata

- **Authored:** 2026-05-27
- **Orchestrator:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Worker:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Verifier:** Codex GPT-5.3 <codex-gpt-5-3@local>
- **Pairing rationale:** Design-only; same shape as cards 20 and 22. Opus authors prose; Codex verifies internal consistency and respects load-bearing beliefs.
- **Type:** Design-only. Tier 3 — should only be queued after Tier 1 + Tier 2 cards have landed, because the federation has nothing to federate over until that happens.

## Surfacing concern

Today each subscribed repo has its own `memory/` directory. Decisions made in `autometta` (e.g. "verifier prompt always mirrors stage card") are invisible to `fractals-from-the-90s` until manually copied. A new subscribed repo bootstraps with zero memory and has to relearn invariants the hard way. As the number of subscribed repos grows (currently three: autometta, emergence-lab, fractals), the cost of this isolation grows quadratically with new agents bootstrapping into unfamiliar repos.

## Objective

Produce a design document at `docs/design/memory-federation.md` specifying a cross-repo memory index: how memories are tagged for federation eligibility, where the index lives, how a worker / verifier in repo A queries memories from repo B, and how the per-repo `memory/` file stays authoritative (per the existing two-family invariant). Explicit answer to: is this an MCP server, a git submodule pattern, a file-sync convention, or something else?

## Inputs

- `memory/README.md` — current per-repo memory contract.
- `docs/philosophy.md` — load-bearing beliefs, especially "git is the state store" and "MCP is the only tool integration boundary".
- `memory/adopters/emergence-lab/` — current cross-repo memory exists in this odd form; the design must explain why this is or isn't sufficient.
- `docs/design/mcp-cards.md` (from card 22, if landed) — sibling design; both touch the same MCP boundary.
- `~/.phat-controller/subscribers/*.yaml` — current subscribers list.

## Deliverables

1. `docs/design/memory-federation.md` — the design document. Required sections: Problem statement; Federation eligibility (not every memory federates — which do?); Index location and shape; Query surface (MCP vs git vs file-sync, with decision); In-repo authority (how the per-repo file stays canonical); Failure modes (federation index unavailable, stale, conflicting); Migration path from current `memory/adopters/<repo>/` pattern; Smallest-possible-prototype card outline.
2. `memory/decision-memory-federation.md` — decision memo. Why this is design-only Tier 3, what concrete pain would trigger building it, why the current `memory/adopters/<repo>/` pattern is or isn't already federation.
3. `docs/philosophy.md` — minimal edit (≤ 3 lines): add a one-line "considered, deferred" item.

## Constraints

- The design must keep per-repo `memory/<file>.md` as the source of truth. Federation is a view, not a store.
- The design must reach a decision on the query mechanism (one of: MCP server, git submodule of an index repo, file-sync convention, hand-rolled `autometta memory federate` CLI). Hand-waving across multiple options is not acceptable.
- The design must explicitly address the case where two repos have conflicting memories on the same topic. Either: conflicts are surfaced and resolved manually; or conflicts are impossible by construction (with reasoning).
- Federation must not require a running daemon. A `cron` / `tick` / `on-demand` model only.
- Prose budget: ≤ 1500 words across all deliverables.
- British English, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

1. `docs/design/memory-federation.md` exists with the eight required sections.
2. The Federation eligibility section explicitly classifies the four existing memory types (`user`, `feedback`, `project`, `reference`) as "federates" or "doesn't federate" with reasoning.
3. The Query surface section reaches a single decision among the four options listed in Constraints.
4. The In-repo authority section explains how the per-repo file stays canonical and is at least one paragraph.
5. The Failure modes section names the three failure modes from Constraints and explains the behaviour for each.
6. The Migration path section addresses the current `memory/adopters/<repo>/` pattern by name.
7. The Smallest-possible-prototype card outline fits on one page.
8. `memory/decision-memory-federation.md` follows the decision-memo format and links to `[[decision-mcp-cards]]` (sibling design from card 22).
9. `docs/philosophy.md` edit is additive and at most three lines.
10. Total prose under 1500 words. No em dashes, no AI-tell vocabulary.

## Out of scope

- Implementing federation.
- Designing the federation index UI / discoverability.
- Multi-organisation federation (one operator, multiple GitHub orgs). Single-operator only for v1 design.
- Versioned memories (memory edits as a graph). Memories stay flat for v1.

## Budget

- **Worker wall-clock:** 60 minutes.
- **Verifier wall-clock:** 25 minutes.

## Verifier handoff

Worker writes deliverables and a one-paragraph executive summary in handoff envelope. Worker writes `state/handoffs/24-memory-federation-design.json`. Verifier reads card, deliverables, and `memory/README.md`, confirms the query-mechanism decision is unambiguous, and writes `state/verifiers/24-memory-federation-design.json`.

## Family-specific notes

None. Pure design + prose card.
