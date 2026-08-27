# Stage card 18-panel-verifier: Optional N=3 verifier panel with quorum voting

## Metadata

- **Authored:** 2026-05-27
- **Orchestrator:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Worker:** Claude Sonnet 4.6 <claude-sonnet-4-6@local>
- **Verifier:** Codex GPT-5.3 <codex-gpt-5-3@local>
- **Pairing rationale:** Cross-family. Sonnet builds the panel dispatch (lots of careful shell + JSON aggregation); Codex verifies the quorum tally is correct and the failure modes (split votes, panellist crash) behave per spec.
- **Depends on:** 15c (SDK verifier route) and 17 (handoff envelope).

## Surfacing concern

A single verifier is a single point of judgement. For high-stakes stages — sandbox changes, auth refactors, the dispatch contract itself — one disagreement on rubric interpretation can land bad work. The reverse failure (one over-strict verifier blocking good work indefinitely) is just as expensive. A panel vote across heterogeneous model families is the cheapest known mitigation.

## Objective

Add an opt-in N=3 panel route to `scripts/spawn-verifier.sh`. The card declares `verifier_panel: true` in its metadata (or stage record); the spawn script then dispatches three verifiers (default: Opus via SDK, Sonnet via SDK, Codex GPT-5.3 via `codex exec`), waits for all three artefacts (or a configurable subset), and writes a synthesised `state/verifiers/<stage-id>.json` whose `overall` is the majority vote. Panellist artefacts are preserved at `state/verifiers/<stage-id>.panel/<panellist-id>.json` for audit.

## Inputs

- `scripts/spawn-verifier.sh` — current single-verifier dispatch.
- `scripts/verify-sdk.py` — SDK verifier from 15c.
- `schemas/verifier.json` — rubric schema from 15b.
- `schemas/handoff-envelope.json` — handoff contract from 17 (a panellist that doesn't write its artefact is treated like a missing envelope).
- `templates/stage-card.md` — Metadata section schema; the new `Verifier panel` field lives here.

## Deliverables

1. `scripts/spawn-verifier-panel.sh` — orchestrates the three dispatches in parallel via `op-fetch` + `register-agent.sh`, waits with `watch-agent.sh` per panellist, aggregates results.
2. `scripts/spawn-verifier.sh` — single-line dispatch to `spawn-verifier-panel.sh` when the stage record or card metadata declares panel mode.
3. `schemas/verifier-panel.json` — JSON Schema for the synthesised artefact. Extends `schemas/verifier.json` with `panellists: [{id, identity, artefact_path, overall}]` and `quorum: {required, achieved}`.
4. `templates/stage-card.md` — add optional Metadata field `Verifier panel: true | false (default false)` with one-line comment.
5. `docs/verifier-panel.md` — when to use the panel, how to read the synthesised artefact, what split-vote means, cost implications.
6. `memory/decision-verifier-panel.md` — decision memo. Why N=3 not N=5, why majority not unanimity, why the panel composition is fixed for v1, why panel mode is opt-in not default.
7. `bin/autometta` — new subcommand `autometta panel <stage-id>` that re-runs the panel on a previously-verified stage and prints the synthesis without mutating state (audit tool).

## Constraints

- Default verifier behaviour is unchanged. Panel mode is opt-in via card metadata or `AUTOMETTA_VERIFIER_PANEL=1` env override.
- A panellist crash (exit non-zero with no artefact) counts as no-vote, not a fail vote. Quorum is `ceil((N+1)/2) = 2` for N=3; if only one panellist returns an artefact, the stage stalls with marker `verifier_panel_no_quorum`.
- Total budget for a panel dispatch is the sum of individual budgets. The card's existing verifier budget is interpreted as per-panellist when panel mode is on.
- Panel mode requires SDK route for the two claude panellists; if SDK route is unavailable, spawn fails closed.
- Panel mode does not change the worker dispatch.

## Acceptance criteria

1. Card with `Verifier panel: false` (or absent) dispatches a single verifier as today; no panel paths are exercised.
2. Card with `Verifier panel: true` dispatches three verifiers in parallel and writes one synthesised artefact + three panellist artefacts under `state/verifiers/<stage-id>.panel/`.
3. Synthesised artefact validates against `schemas/verifier-panel.json` and has `overall` equal to the majority of panellist `overall` values.
4. With two panellists returning PASS and one FAIL, `overall=PASS` and the failing panellist's per-criterion findings are preserved under `panellists[].artefact_path`.
5. With one panellist crashing (no artefact) and the other two returning split votes (1 PASS, 1 FAIL), the stage stalls with marker `verifier_panel_no_quorum`.
6. `autometta panel 14-auth-route-toggle` re-runs the panel against stage 14, prints the synthesis to stdout, and does not modify `state.yaml` or `state/verifiers/14-auth-route-toggle.json`.
7. The cost log (existing token tracking) records all three panellist costs separately and the synthesis as zero (it is a local aggregation, not an LLM call).
8. Heartbeat / agent ticker see three concurrent verifier registrations, one per panellist, and clear cleanly on each panellist's completion.
9. `docs/verifier-panel.md` covers the quorum rule, the cost implication ("verifier cost roughly 3x for panel-mode stages"), and the split-vote stall path.
10. No regressions: stages 06-14 re-verified under `Verifier panel: false` produce identical artefacts to a control run before this change.

## Out of scope

- Configurable panel composition per card. Composition is fixed for v1 (Opus SDK + Sonnet SDK + Codex CLI). Future card if it bites.
- N>3 panels.
- Weighted votes / tie-breaker model.
- Cross-tick panel (panellists across multiple ticks). All three dispatch in the same tick.
- Cost-aware panel suppression (skip panel for cheap stages). Card-author's job for now.

## Budget

- **Worker wall-clock:** 90 minutes.
- **Verifier wall-clock:** 45 minutes.

## Verifier handoff

Worker writes the deliverables, dogfoods the panel against stage 14 (a known-passing stage) and against a synthetic always-fail stage, pastes the synthesised artefact + the three panellist artefacts in its completion message. Verifier reads card and deliverables, validates the quorum logic by induction (read `spawn-verifier-panel.sh`'s tally function), and re-runs acceptance #5 against a synthetic crash scenario. Verifier writes `state/verifiers/18-panel-verifier.json` (single verifier — this stage's verification is not itself panelled).

## Family-specific notes

- **Sonnet (worker):** SDK route preferred; `claude -p` would work but the new code is itself the SDK harness, so dogfood via SDK.
- **Codex (verifier):** runs outside any panel; standard cross-family verification per the invariant. Stdin redirect on subprocess invocation.
