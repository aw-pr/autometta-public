# Stage card 28-per-role-family-sdk-transport: Per-role, per-family SDK transport matrix (OpenAI verifier route + orchestrator design)

## Metadata

- **Authored:** 2026-05-28
- **Orchestrator:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Worker:** Codex GPT-5.3 <codex-gpt-5-3@local>
- **Verifier:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Pairing rationale:** Cross-family. Codex builds the OpenAI SDK verifier route and the generalised transport resolver; Claude verifies the matrix is consistent, fails closed correctly, and that the orchestrator-SDK design honours the card-23 gate rather than productionising ahead of it.
- **Type:** Implementation (verifier side) plus design (orchestrator side).
- **Depends on:** 15c + 16 (shipped Claude SDK verifier route and prompt caching). The orchestrator-SDK portion depends on the card-23 verdict for productionisation; this card designs it but does not build a production orchestrator-SDK path.

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

1. `scripts/verify-sdk-openai.py` - OpenAI SDK verifier entrypoint, parallel to `scripts/verify-sdk.py`: reads the same rubric contract (`schemas/verifier.json`), writes the same verifier artefact shape, and emits a comparable cache or usage line to stderr. Uses the `openai` library.
2. `scripts/requirements-sdk.txt` - add the `openai` dependency, pinned.
3. `scripts/spawn-verifier.sh` - generalise the transport branch so `verifier.codex.transport: sdk` routes to the OpenAI entrypoint, mirroring the existing Claude SDK branch, including the same fail-closed check that SDK transport requires `auth.<family>.mode: api`.
4. `.autometta.local.yaml.example` - document the generalised matrix: `verifier.{claude,codex}.transport` and a commented, not-yet-active `orchestrator.{claude,codex}.transport` block marked as design-pending card 23.
5. `docs/sdk-verifier.md` - extend with the OpenAI verifier route and the generalised matrix.
6. `docs/design/orchestrator-sdk-transport.md` - design memo for the orchestrator-role transport options across both families: what the manifest keys would be, how dispatch would differ from the CLI orchestrator, and the explicit statement that the production path is gated behind the card-23 verdict.
7. `memory/decision-per-role-family-sdk-transport.md` - decision memo; links to `[[decision-sdk-verifier-integration]]` and `[[decision-sdk-controller-experiment]]`.

## Constraints

- The OpenAI verifier route must fail closed exactly like the Claude one: `verifier.codex.transport: sdk` with `auth.codex.mode` not `api` aborts at dispatch with a clear message.
- No production orchestrator-SDK code in this card. The orchestrator side is design memo only.
- `verify-sdk-openai.py` must honour the same `AUTOMETTA_*_TRANSPORT` A/B override pattern the Claude route uses.
- Reuse the existing rubric schema and verifier artefact contract; do not fork them per family.
- British English, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. `scripts/verify-sdk-openai.py --help` prints usage and exits 0.
2. `verifier.codex.transport: sdk` with `auth.codex.mode: api` routes a verifier dispatch through `verify-sdk-openai.py` (demonstrated against one stage, or with a documented smoke run if no API key is available at verify time).
3. `verifier.codex.transport: sdk` with `auth.codex.mode: subscription` fails closed at dispatch with a clear message, matching the Claude route's behaviour.
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
