# Stage card 20-sweep-skill-design: Design document for the autometta-sweep skill (parallel design exploration)

## Metadata

- **Authored:** 2026-05-27
- **Orchestrator:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Worker:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Verifier:** Codex GPT-5.3 <codex-gpt-5-3@local>
- **Pairing rationale:** Opus authors prose design documents; Codex verifies that the design is internally consistent and references only patterns / scripts that exist in the tree (no hand-waving).
- **Type:** Design-only. Deliverable is documentation + a decision memo. No code change. Implementation is a separate future card.

## Surfacing concern

Stages with high upstream uncertainty — architecture choice, library choice, contract change — currently run as single-track exploration: one worker, one approach, one result. The cost of a wrong commit at that depth is large. The research-sweeper MCP pattern (parallel lanes + synthesis pass) is the obvious adaptation, but it does not yet have a place in the dispatch contract. This design card decides how it would fit before any code is written.

## Objective

Produce a design document at `docs/design/sweep-stage.md` that specifies how a "sweep stage" extends the dispatch contract: how a card declares itself a sweep, how N parallel workers are dispatched into N scratch worktrees, how their results are synthesised, what the deliverable shape is, and where this sits relative to the panel-verifier (18) which it superficially resembles but is materially different from.

## Inputs

- `docs/philosophy.md` — load-bearing beliefs the design must respect.
- `docs/phat-controller.md` — current loop design.
- `docs/observability.md` — current heartbeat / ticker surface.
- `templates/stage-card.md` — the contract being extended.
- `examples/self-host/18-panel-verifier.md` — adjacent multi-dispatch pattern; the design must explain the boundary.
- `~/.claude/skills/research-sweep/` if present, otherwise the user's description of the existing research-sweeper MCP.

## Deliverables

1. `docs/design/sweep-stage.md` — the design document. Required sections: Problem statement; Card schema additions; Dispatch flow (worktrees, parallelism, sandboxing); Synthesis pass (separate dispatched agent vs in-process aggregation — pick one with reasoning); Deliverable shape; Sandbox / git-state implications; Boundary against panel-verifier (18) and against research-sweeper (which produces notes, not code); Risks and open questions; Smallest-possible-prototype card outline.
2. `memory/decision-sweep-stage.md` — decision memo. Why a sweep stage is opt-in not default, why synthesis is itself a worker not a verifier, why worktrees not branches, why the synthesis output is a `docs/decisions/` entry rather than a code commit.
3. `docs/philosophy.md` — minimal edit: add sweep-stage to the load-bearing-beliefs section as an explicit *exception* to the "one card per dispatch" pattern (or argue it's not an exception — but be explicit).

## Constraints

- Design must respect the four load-bearing beliefs: git-as-state, sandbox-as-role, cron+tick, budget-not-retries. Any tension must be called out, not glossed.
- Design must not invent new infrastructure beyond what is already in the repo (worktrees, op-fetch, register-agent, watch-agent, tick.sh). If something new is needed, the design says so explicitly and proposes the smallest possible scope.
- The boundary against panel-verifier (18) must be explicit: panel = N verifiers on one worker's output, sweep = N workers on one problem. Document the distinction.
- No prose longer than ~1500 words across all design files. Lean is the point.
- British English, no em dashes, no AI-tell vocabulary (per the persona-west audit rules in CLAUDE.md).

## Acceptance criteria

1. `docs/design/sweep-stage.md` exists with the eight required sections from Deliverable #1.
2. Each load-bearing belief from `docs/philosophy.md` is addressed in the design (either "respected because X" or "tension because Y, mitigated by Z").
3. The boundary against `18-panel-verifier.md` is explicit and one-paragraph (panel vs sweep, in plain terms).
4. The design names every existing script it would reuse and every new piece it would introduce. The new-piece list has at most three items.
5. The "Smallest-possible-prototype card outline" is at most one page and could be lifted into a future stage card with minimal editing.
6. `memory/decision-sweep-stage.md` follows the decision-memo format and links to `[[decision-handoff-envelope]]` (the sweep workers will emit handoff envelopes per 17).
7. `docs/philosophy.md` edit is at most three lines.
8. Total prose under 1500 words across the three deliverables.
9. No em dashes, no `delve`, `leverage`, `seamless`, `robust`, `crucial`, `pivotal`.
10. No code change. `bin/autometta`, every script, every schema is byte-identical before and after.

## Out of scope

- Implementing the sweep stage. This card is design-only.
- Building the synthesis prompt. The design names it as a deliverable of the future implementation card, not this one.
- Cost analysis. Implementation card's job, once parallelism factor is decided.
- A sweep against an existing question. v1 of the design is generic.

## Budget

- **Worker wall-clock:** 60 minutes.
- **Verifier wall-clock:** 25 minutes.

## Verifier handoff

Worker writes the deliverables and a one-paragraph executive summary in its handoff envelope. Worker writes `state/handoffs/20-sweep-skill-design.json`. Verifier reads card, deliverables, and `docs/philosophy.md`, confirms every belief is addressed and every existing-script reference is real (grep), and writes `state/verifiers/20-sweep-skill-design.json`.

## Family-specific notes

None. Pure design + prose card.
