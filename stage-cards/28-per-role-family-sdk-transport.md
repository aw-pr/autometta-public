# Stage card 28-per-role-family-sdk-transport: Per-role, per-family SDK transport matrix (OpenAI verifier route + orchestrator design)

## Metadata

- **Authored:** 2026-05-28 (refreshed 2026-08-31: identities, gate, claims, and the auth-mode reality after card 89)
- **Orchestrator:** Claude Fable 5 <claude-fable-5@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Opus 5 <claude-opus-5@local>
- **Base branch:** dev
- **Run branch:** autometta/28-per-role-family-sdk-transport
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Gate:** stage-completed: 89-the-sdk-verifier-runs-on-the-subscription
- **Path claims:** scripts/verify-sdk-openai.py, scripts/requirements-sdk.txt, scripts/spawn-verifier.sh, .autometta.local.yaml.example, docs/sdk-verifier.md, docs/design/orchestrator-sdk-transport.md, memory/decision-per-role-family-sdk-transport.md
- **Pairing rationale:** Cross-family. Codex builds the OpenAI SDK verifier route and the generalised transport resolver; Claude verifies the matrix is consistent, fails closed correctly, and that the orchestrator-SDK design honours the card-23 gate rather than productionising ahead of it.
- **Type:** Implementation (verifier side) plus design (orchestrator side).
- **Depends on:** 15c + 16 (shipped Claude SDK verifier route and prompt caching), and card 89 (the Claude SDK route on subscription auth), because both edit `spawn-verifier.sh` and this card must generalise the post-89 branch, not the pre-89 one. The orchestrator-SDK portion depends on the card-23 verdict for productionisation; this card designs it but does not build a production orchestrator-SDK path.

## Surfacing concern

The transport layer already supports `verifier.claude.transport: cli|sdk`, but only the Claude family has an SDK route, and only the verifier role has a transport knob at all. The operator wants finer granularity: an SDK option for both OpenAI and Claude, across both the verifier and the orchestrator roles. That gives a full `<role>.<family>.transport` matrix so each role can run on the cheapest or most cache-friendly transport per family, independently. The verifier side is incremental and shippable now; the orchestrator side is a design until the card-23 experiment says whether a long-lived SDK session should drive the loop at all.

## Objective

Generalise the transport configuration from `verifier.<family>.transport` to a per-role, per-family matrix, and implement the missing OpenAI SDK verifier route so `verifier.codex.transport: sdk` works the same way `verifier.claude.transport: sdk` does today. Design (do not build a production path for) the orchestrator-role transport options for both families, with the build gated behind the card-23 verdict.

## Inputs (read these in your own context)

- `scripts/spawn-verifier.sh` - current transport branch (Claude SDK vs CLI).
- `scripts/verify-sdk.py` - the shipped Anthropic SDK verifier with prompt caching.
- `scripts/auth-route.sh` - per-family auth route resolution.
- `.autometta.local.yaml.example` - current `verifier.<family>.transport` docs.
- `docs/sdk-verifier.md` - the verifier SDK design and integration notes.
- `examples/self-host/23-sdk-controller-experiment.md` - the orchestrator-SDK experiment whose verdict gates productionisation.

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. `scripts/verify-sdk-openai.py` - codex SDK verifier entrypoint, parallel to `scripts/verify-sdk.py`: reads the same rubric contract (`schemas/verifier.json`), writes the same verifier artefact shape, and emits a comparable usage line to stderr from the turn's `ThreadTokenUsage`. Uses the official **Codex SDK** (`openai-codex` on PyPI), which drives the codex agent harness and reuses codex's own auth resolution - NOT the `openai` API library and NOT the `openai-agents` framework, both of which are key-only and the wrong surface (researched 2026-08-31; see `memory/project-codex-sdk-subscription-auth.md`).
2. `scripts/requirements-sdk.txt` - add the `openai-codex` dependency, pinned.
3. `scripts/spawn-verifier.sh` - generalise the transport branch so `verifier.codex.transport: sdk` routes to the codex SDK entrypoint, mirroring the Claude SDK branch. Both families take api or subscription on the SDK route. The codex-side trap is CODEX_HOME selection, the exact inverse of gotcha 8: subscription mode must point CODEX_HOME at the normal `~/.codex` (chatgpt-mode auth.json, bills the plan); api mode must point it at the sibling api-only home. The spawn reads the selected auth.json's `auth_mode` and fails closed on a mismatch with the resolved billing mode, because a silent mismatch bills the wrong route invisibly.
4. `.autometta.local.yaml.example` - document the generalised matrix: `verifier.{claude,codex}.transport` and a commented, not-yet-active `orchestrator.{claude,codex}.transport` block marked as design-pending card 23.
5. `docs/sdk-verifier.md` - extend with the OpenAI verifier route and the generalised matrix.
6. `docs/design/orchestrator-sdk-transport.md` - design memo for the orchestrator-role transport options across both families: what the manifest keys would be, how dispatch would differ from the CLI orchestrator, and the explicit statement that the production path is gated behind the card-23 verdict.
7. `memory/decision-per-role-family-sdk-transport.md` - decision memo; links to `[[decision-sdk-verifier-integration]]` and `[[decision-sdk-controller-experiment]]`.

## Constraints

- The codex SDK route must fail closed when the selected CODEX_HOME's `auth.json` carries an `auth_mode` that contradicts the resolved billing mode, naming both in the message. Do not narrow either family back to api-only anywhere; card 89's subscription branch is the contract this card generalises.
- No production orchestrator-SDK code in this card. The orchestrator side is design memo only.
- `verify-sdk-openai.py` must honour the same `AUTOMETTA_*_TRANSPORT` A/B override pattern the Claude route uses.
- Reuse the existing rubric schema and verifier artefact contract; do not fork them per family.
- British English, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. `scripts/verify-sdk-openai.py --help` prints usage and exits 0.
2. `verifier.codex.transport: sdk` with `auth.codex.mode: api` routes a verifier dispatch through `verify-sdk-openai.py` (demonstrated against one stage, or with a documented smoke run if no API key is available at verify time).
3. `verifier.codex.transport: sdk` dispatches on both auth modes with the right CODEX_HOME each way (subscription -> normal home, api -> sibling), shown by the spawn's route log; a deliberately mismatched auth.json fails closed naming the mismatch; and `verifier.claude.transport: sdk` with `auth.claude.mode: subscription` still dispatches per card 89.
4. The OpenAI verifier writes a verifier artefact that validates against `schemas/verifier.json` via `scripts/validate-verifier-artefacts.sh`.
5. `.autometta.local.yaml.example` documents `verifier.{claude,codex}.transport` and a commented `orchestrator.{claude,codex}.transport` block flagged as design-pending card 23.
6. `docs/design/orchestrator-sdk-transport.md` states explicitly that the orchestrator-SDK production path is gated behind the card-23 verdict.
7. `memory/decision-per-role-family-sdk-transport.md` follows the decision-memo format and links to both named memos.
8. No regression in the existing Claude SDK verifier route (`verifier.claude.transport: sdk` still works).

## Out of scope

- Building a production orchestrator-SDK dispatch path (gated behind card 23).
- A worker-role SDK transport (workers stay CLI subprocesses; the sandbox-as-role-boundary belief depends on it).
- Cloud or hosted execution (card 27).
- Cost-aware automatic transport selection (that is card 25's territory).

## Budget

- **Worker wall-clock:** 90 minutes.
- **Verifier wall-clock:** 30 minutes.

## Verifier handoff

Worker implements the OpenAI verifier route and the generalised transport branch, runs the fail-closed checks and (if a key is available) one smoke verify, pastes the relevant diffs and log lines in the completion message, and writes `state/handoffs/28-per-role-family-sdk-transport.json`. Verifier reads the card, the new script, the spawn-verifier branch, and the design memo; confirms the fail-closed behaviour and the card-23 gate; writes `state/verifiers/28-per-role-family-sdk-transport.json`.

## Family-specific notes

- **Codex (worker):** stdin redirect for any subprocess. The OpenAI SDK verifier needs `OPENAI_API_KEY` injected via the existing `op-fetch` route; do not read keys from any other source.
- **Claude (verifier):** the verifier does not need to run either SDK route end to end; it reads the code, the manifest docs, and one smoke artefact if present. This is a deliberate cost guard, matching card 23.

## Re-brief (2026-08-31, after attempt 1 verifier FAIL)

Attempt 1 (`wip/28-per-role-family-sdk-transport-attempt-1`, commit
b7c7c56fd3161d0e98f0b48ae6af1f189cd684cc) passed seven of eight acceptance
criteria. Criterion 3 failed on one clause, "dispatches": the codex SDK
branch forwards `AUTOMETTA_EFFORT_ARGV` verbatim, and
`effort_flags_for_family` emits the codex CLI form
(`-c model_reasoning_effort=<level>`) for that family, which
`verify-sdk-openai.py`'s argument parser rejects (`unrecognized arguments`,
exit 2). The child dies before any verification runs, burns a verifier
attempt against `verifier_attempt_cap`, and 63 of the 97 cards in
`stage-cards/` declare a `Verifier effort`, so the majority case of this
route never runs (verifier finding,
`state/verifiers/28-per-role-family-sdk-transport.json`, criterion 3).

Resolution: **restore the tree preserved on
`wip/28-per-role-family-sdk-transport-attempt-1` and apply one narrow
fix.** When the codex family dispatches over the SDK transport, effort must
reach `verify-sdk-openai.py` as the `--effort <level>` option it already
defines, never as the codex CLI form. Do not fix it by dropping the effort
argv: a declared effort that is silently inert on one route is the failure
mode card 34 and `docs/lessons.md` gotcha 12 exist to prevent. Restore the
preserved tree, not the preserved commit; everything else in attempt 1 was
judged sound, so reproduce its behaviour unchanged. Attempt 2's smoke of
the codex SDK route must be run with a declared `Verifier effort` in play,
so the corrected path is the path exercised. All other constraints and
criteria stand unchanged.
