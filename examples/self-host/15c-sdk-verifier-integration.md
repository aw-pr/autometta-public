# Stage card 15c-sdk-verifier-integration: Wire the SDK verifier into spawn-verifier.sh with a CLI fallback

## Metadata

- **Authored:** 2026-05-27
- **Orchestrator:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Worker:** Claude Sonnet 4.6 <claude-sonnet-4-6@local>
- **Verifier:** Codex GPT-5.3 <codex-gpt-5-3@local>
- **Pairing rationale:** Cross-family. Sonnet modifies the shell dispatch via the Claude OAuth route; Codex verifies via the API route by simulating SDK absence and confirming the original `claude -p` route still works.

## Surfacing concern

The SDK prototype (15a) and rubric contract (15b) are now in place. Until `spawn-verifier.sh` actually uses them, the dispatch loop sees no benefit. The change must preserve the existing route: if the SDK is unavailable, mis-configured, or the operator wants to A/B compare, the `claude -p` path must still work.

## Objective

Add an SDK route to `scripts/spawn-verifier.sh` for the claude family, selected by a per-repo manifest flag (`verifier.claude.transport: sdk | cli`, default `cli`). When `sdk` is selected and `scripts/verify-sdk.py` is present, dispatch via the SDK; otherwise fall back to the existing `claude -p` route. Emit a single log line saying which route was taken.

## Inputs

- `scripts/spawn-verifier.sh` — the file to modify.
- `scripts/verify-sdk.py`, `schemas/verifier.json` — from 15a/15b.
- `.autometta.local.yaml` (this repo) and `.autometta.local.yaml.example` — manifest schema reference.
- `scripts/auth-route.sh` — the existing pattern for "manifest flag + env override + fallback default".

## Deliverables

1. `scripts/spawn-verifier.sh` — adds the SDK route as described. The existing `claude -p` block stays untouched. The route choice is logged to stderr in a single line: `verifier-transport: sdk|cli (provenance: manifest|env|default)`.
2. `.autometta.local.yaml.example` — adds the optional `verifier.claude.transport` block with a comment explaining the two values, the fallback, and the operator-opt-in step (set `auth.claude.mode: api` AND `verifier.claude.transport: sdk` together; setting only the transport with subscription mode fails closed).
3. `docs/sdk-verifier.md` — extend with "Integration into spawn-verifier.sh" section.
4. `memory/decision-sdk-verifier-integration.md` — decision memo. Why manifest flag rather than per-card, why cli is the default fallback, why no per-family flag (codex stays on `codex exec`), why this card deliberately does NOT mutate the autometta repo's own manifest (avoids the circular dispatch where 15c's verifier runs with sdk+subscription and fails closed on its own stage).
5. `CLAUDE.md` — one-line addition to the "Manual orchestrator dispatch pattern" section noting that claude-family dispatch may take the SDK route when the manifest selects it.

## Constraints

- Default behaviour with no manifest flag set is the existing `claude -p` route. Zero behavioural change for any repo that does not opt in.
- The SDK route must use the same env-injection contract as the CLI route (`op-fetch` with `OP_REF_ANTHROPIC_API_KEY` in api mode, nothing in subscription mode — but the SDK requires api mode, so subscription + sdk must fail closed at dispatch with a clear message).
- The SDK route must register the agent via `scripts/register-agent.sh` exactly the same way the CLI route does, so heartbeat / ticker work unchanged.
- The SDK route's exit code semantics must match what `tick.sh` expects (0 = PASS, non-zero = FAIL or env error). `verify-sdk.py` already emits 0/1/2/3; map appropriately.
- No changes to `scripts/spawn-worker.sh`, `bin/autometta`, `scripts/tick.sh`.

## Acceptance criteria

1. With `verifier.claude.transport: cli` (or absent), dispatching the verifier for any stage hits the existing `claude -p` block and logs `verifier-transport: cli (provenance: default|manifest)`.
2. With `verifier.claude.transport: sdk` and `auth.claude.mode: subscription`, the dispatch fails closed before invoking any process, with a message naming the manifest flag and the required `api` mode.
3. With `verifier.claude.transport: sdk` and `auth.claude.mode: api`, the dispatch invokes `op-fetch OP_REF_ANTHROPIC_API_KEY -- python3 scripts/verify-sdk.py ...` with the card and artefact glob derived from the stage record.
4. `AUTOMETTA_CLAUDE_TRANSPORT=cli` overrides a manifest setting of `sdk` and logs `(provenance: env)`.
5. With the SDK route selected and `scripts/verify-sdk.py` missing, the dispatch falls back to `claude -p` and logs a warning naming the missing file.
6. Registering via `register-agent.sh` includes the same family/role/identity fields regardless of route.
7. Re-running a stage that previously passed under `claude -p` under the SDK route produces a schema-valid `state/verifiers/<stage-id>.json` with `overall=PASS`. (Smoke test target: stage 14.)
8. No regressions in stages 06-14 (spot-check by re-running stage 14's verifier under both routes and diffing the artefacts; differences must be limited to wording, not `overall` or per-criterion `status`).
9. `.autometta.local.yaml.example` documents the flag, the env override, and the fail-closed condition.
10. The cd-fix at `9e282f3` is not reverted (regression guard).

## Out of scope

- Codex worker on SDK. Worker stays on `codex exec`.
- Removing the `claude -p` block. Both routes coexist.
- A/B framework for comparing routes at scale. Manual diff for v1.
- Prompt caching on the SDK route — that is card 16.

## Budget

- **Worker wall-clock:** 45 minutes.
- **Verifier wall-clock:** 25 minutes.

## Verifier handoff

Worker writes the deliverables, runs the smoke test from acceptance #7 against stage 14 under both routes by setting `AUTOMETTA_CLAUDE_TRANSPORT=sdk` + `AUTOMETTA_CLAUDE_MODE=api` for the SDK run (env override avoids mutating this repo's manifest). Worker attaches both artefact diffs in its completion message and confirms acceptance #2 by attempting a dispatch under `subscription` + `sdk` via env override and pasting the fail-closed message. Verifier reads the card and deliverables, runs `scripts/spawn-verifier.sh` for stage 14 once under each transport setting (via env override only — manifest stays at the operator's default), and writes `state/verifiers/15c-sdk-verifier-integration.json`. Verifier dispatch itself uses the default `claude -p` route per the operator's current manifest, sidestepping the circular dispatch hazard.

## Family-specific notes

- **Claude (worker):** the SDK route under verification is the same SDK a future Claude verifier may use. Worker must keep the env stripped per usual (`op-fetch` boundary), so there is no transport-conflation risk for this stage.
- **Codex (verifier):** stdin redirect remains mandatory when invoking any subprocess in the modified spawn script (lessons.md #1). Sandbox `workspace-write` is sufficient for writing the verifier artefact.
