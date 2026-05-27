# Stage card 22-mcp-served-cards-design: Design document for MCP-served stage cards (multi-machine readiness)

## Metadata

- **Authored:** 2026-05-27
- **Orchestrator:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Worker:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Verifier:** Codex GPT-5.3 <codex-gpt-5-3@local>
- **Pairing rationale:** Design-only; same shape as card 20. Opus authors prose, Codex verifies the design is internally consistent and respects the load-bearing beliefs.
- **Type:** Design-only. No code change. Implementation, if pursued, is a future card.

## Surfacing concern

Cards live on disk today (`examples/self-host/*.md`). The dispatch contract assumes the worker can `cat` the card path. That works on one machine. The moment autometta runs across two machines (a future Tier-2 / Tier-3 goal), card distribution becomes a problem: which copy is canonical, how is staleness detected, how is a mid-flight edit propagated? MCP is the documented tool integration boundary for autometta (one of the load-bearing beliefs); serving cards over MCP rather than filesystem is the natural extension. This card decides whether to pursue it and how, before any code is written.

## Objective

Produce a design document at `docs/design/mcp-cards.md` specifying an MCP server that exposes stage cards as resources, the URI scheme, how card versioning works, how `tick.sh` would consume cards via MCP rather than file path, what happens when MCP is unavailable (fallback to filesystem), and what concrete problem this enables (multi-machine, multi-clone, audit trail of card edits).

## Inputs

- `docs/philosophy.md` — load-bearing beliefs (especially "MCP is the only tool integration boundary" and "git is the state store; filesystem is the message bus").
- `scripts/tick.sh` — current card-path consumer.
- `templates/stage-card.md` — current card shape.
- `examples/self-host/14-auth-route-toggle.md` — recent card the design references concretely.
- Any in-repo prior MCP work (search `grep -r mcp .`) to align on convention.

## Deliverables

1. `docs/design/mcp-cards.md` — the design document. Required sections: Problem statement (what is MCP-cards solving that the filesystem isn't?); URI scheme (e.g. `stage://<repo>/<stage-id>@<version>`); Server responsibilities (read, list, versioning, no write authority from worker); Consumption by `tick.sh` (with fallback to filesystem); Relationship to the "filesystem is the message bus" belief (is this a refinement or a contradiction? answer explicitly); Multi-machine implications; Migration path (no big-bang; opt-in per repo); Smallest-possible-prototype card outline.
2. `memory/decision-mcp-cards.md` — decision memo. Why MCP not HTTP, why server-side versioning not git SHAs (or vice versa, with reasoning), why fallback to filesystem is mandatory not optional, why this is design-only until a concrete multi-machine use case lands.
3. `docs/philosophy.md` — minimal edit (≤ 3 lines): add MCP-cards as an explicit "considered, deferred" item under load-bearing beliefs.

## Constraints

- The design must not contradict "filesystem is the message bus" — if MCP-served cards replace the filesystem path for cards specifically, the design must argue why cards are not "messages" in the same sense as handoff envelopes or verifier artefacts.
- The design must explicitly preserve git-as-state: card edits are still tracked in git; the MCP server reads from git, it does not own card storage.
- No third-party MCP server framework dependency without explicit justification.
- Prose budget: ≤ 1500 words across all deliverables.
- British English, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

1. `docs/design/mcp-cards.md` exists with the eight required sections.
2. The "Relationship to filesystem-is-the-message-bus" section is at least one paragraph and reaches an explicit conclusion (this is a refinement / this is a contradiction with mitigation X).
3. The URI scheme is concrete (literal example given).
4. The fallback-to-filesystem path is described well enough that `tick.sh` could be patched against the design without further specification.
5. The "Smallest-possible-prototype card outline" fits on one page and could be lifted into a future implementation card.
6. `memory/decision-mcp-cards.md` follows the decision-memo format and links to `[[decision-sweep-stage]]` (sibling design card).
7. `docs/philosophy.md` edit is at most three lines and is additive (no existing belief is rewritten).
8. Total prose under 1500 words.
9. No em dashes; no `delve`, `leverage`, `seamless`, `robust`, `crucial`, `pivotal`.
10. No code change. Every script, schema, and `bin/autometta` is byte-identical.

## Out of scope

- Implementing the MCP server.
- Choosing an MCP framework / library.
- Multi-machine card sync. v1 design is single-machine MCP server + filesystem fallback; multi-machine is "consequence of pursuing this", not "designed here".
- Authentication on the MCP card surface (local-only; MCP transport security is a separate question).

## Budget

- **Worker wall-clock:** 60 minutes.
- **Verifier wall-clock:** 25 minutes.

## Verifier handoff

Worker writes the deliverables and a one-paragraph executive summary in its handoff envelope. Worker writes `state/handoffs/22-mcp-served-cards-design.json`. Verifier reads card, deliverables, and `docs/philosophy.md`, confirms the "filesystem is the message bus" tension is addressed and reaches a clear position, and writes `state/verifiers/22-mcp-served-cards-design.json`.

## Family-specific notes

None. Pure design + prose card.
