# Stage card 99: the verifier reaches the subscription through the Agent SDK

## Metadata

- **Authored:** 2026-09-01
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Verifier:** Claude Opus 5 <claude-opus-5@local>
- **Base branch:** dev
- **Run branch:** autometta/99-the-verifier-reaches-the-subscription
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/verify-sdk-agent.py, scripts/models.sh, scripts/spawn-verifier.sh, scripts/verifier-route-matrix-smoke.sh, docs/sdk-verifier.md
- **Pairing rationale:** same family, different tier, and deliberately so. The
  deliverable is a *Claude subscription auth route*, and only the claude
  family's auth route injects `CLAUDE_CODE_OAUTH_TOKEN`; a codex verifier
  could not run the thing it is judging and would be left grading the
  worker's prose. That is the failure mode that stranded emergence-lab
  stages 13, 14 and 15 on a criterion no seat could satisfy. Independence
  here comes from a separate process with its own context, a stronger tier
  judging a weaker one, and criteria the verifier executes itself rather
  than reads about. Note both roles run `claude -p` unsandboxed, so the
  codex `Requires network` / `Requires agent home` grants do not apply and
  are deliberately absent.
- **Type:** Production wiring. Unlike cards 23 and 98 this is not an
  experiment; the question it would have asked was answered on 2026-09-01.

## Surfacing concern

Card 89 is titled "the SDK verifier runs on the subscription" and card 90 made
that route the transport of first resort. Neither is true as built.
`scripts/verify-sdk.py` imports `anthropic` -- the API SDK, the raw Messages
API -- while its documentation, its dispatch branch and its own
`VERIFIER_IDENTITY` all named `claude-agent-sdk`. A Claude Code subscription
token is not a credential for the Messages API.

Measured 2026-09-01, one request each, same model and minute: a `max_tokens=4`
call returned `429 rate_limit_error` on the OAuth token, `200` on
`ANTHROPIC_API_KEY`, and `claude -p` on that same OAuth token answered. Card 89
passed because `verify-sdk.py` prefers `ANTHROPIC_API_KEY` when both are
present, so the subscription token was never the credential under test.

`361b43c` made the surfaces explicit and refuses the crossing, which stopped
the bleeding: `agent-sdk` is now a named surface that no entrypoint implements,
so declaring it is refused rather than silently becoming something else. This
card implements it. `claude-agent-sdk==0.2.87` is already pinned in
`scripts/requirements-sdk.txt` and installed; the worker and controller
experiments (cards 98, 23) both used it, so only the verifier never did.

The prize is what card 89 wanted: a verifier that runs on the subscription
*and* returns structured output, per-message usage and a validated envelope
without parsing a CLI log for them.

## Objective

Add `scripts/verify-sdk-agent.py`, an Agent SDK verifier entrypoint that
authenticates with `CLAUDE_CODE_OAUTH_TOKEN`, and make `transport: agent-sdk`
dispatch it. The route matrix stops refusing that surface because it now
exists.

**This card does not change any default.** No repo switches route as a result;
`agent-sdk` becomes available to a manifest that asks for it. Making it the
default is a separate decision with its own evidence, and card 90 is the
cautionary tale for taking it early.

## Inputs (read these in your own context)

- `scripts/verify-sdk.py` -- the api-sdk entrypoint whose CLI contract,
  artefact shape, prompt assembly and exit codes you are matching
- `scripts/models.sh` -- `claude_surface_for_transport`,
  `claude_route_refusal`, `claude_route_guard`: the matrix you are amending
- `scripts/spawn-verifier.sh` -- the claude dispatch branch and
  `resolve_verifier_transport`
- `scripts/worker-sdk-experiment.py` -- a working `ClaudeSDKClient` session
  with a permission callback, for the SDK's actual API shape
- `docs/sdk-verifier.md` -- the route matrix and the doc you are extending
- `schemas/verifier.json` -- the artefact contract

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/verify-sdk-agent.py`. Imports `claude_agent_sdk`; must not import
   `anthropic`. Same CLI surface as `verify-sdk.py` (`--stage-id`, `--card`,
   `--artefact-glob`, `--out`, `--model`, `--effort`) and the same exit codes,
   so the dispatch site differs only in which file it names. Writes an
   artefact that validates against `schemas/verifier.json`.
2. **Resolve the schema from the install, not the cwd.** A dispatched verifier
   runs with cwd set to the subscriber's run worktree. `verify-sdk.py` carried
   `Path("schemas/verifier.json")` and was dead in every subscriber repo for a
   day (`1df9ab3`). Do not reproduce it. The template stays cwd-relative on
   purpose -- a subscriber vendors and may fill its own copy.
3. `scripts/models.sh`: `agent-sdk` is no longer refused, on either credential.
   Add the surface-to-entrypoint mapping in the same place as the matrix, so
   there is still one source of truth for what a surface is and what runs it.
4. `scripts/spawn-verifier.sh`: an `agent-sdk` transport dispatches the new
   entrypoint through the existing `op-fetch` auth-route contract. No new
   secrets handling, and no new credential names.
5. `scripts/verifier-route-matrix-smoke.sh`: the `agent-sdk` assertions invert
   -- it is now permitted on both credentials. The smoke must fail against the
   pre-change matrix.
6. `docs/sdk-verifier.md`: the `agent-sdk` row is implemented; say which
   surface to choose and why, and that the default is unchanged.
7. A recorded live run in the stage's evidence: the new entrypoint verifying a
   synthetic card end to end on the subscription token, with the transcript
   and the artefact it produced.

## Constraints

- **`verify-sdk.py` keeps its behaviour.** The api-sdk surface stays; this is
  an addition. Its identity string, exit codes and artefact shape do not move.
- Reuse `scripts/auth-route.sh` and `op-fetch` as they stand. If the Agent SDK
  needs a credential named differently, stop and escalate rather than
  inventing an env var.
- No new dependency. `claude-agent-sdk` is already pinned.
- The default transport is untouched.

## Acceptance criteria

1. `python3 scripts/verify-sdk-agent.py --help` exits 0, and the file imports
   `claude_agent_sdk` and not `anthropic`.
2. Run the new entrypoint for real on the subscription token against a
   synthetic card and artefact. It writes an artefact that validates against
   `schemas/verifier.json`. Both the transcript and the artefact are in the
   evidence; a description of a run is not a run.
3. `AUTOMETTA_CLAUDE_TRANSPORT=agent-sdk bash scripts/spawn-verifier.sh
   --print-transport claude <any repo>` prints `agent-sdk`, not a
   `route-guard` downgrade.
4. `scripts/verifier-route-matrix-smoke.sh` passes, and fails when its
   `agent-sdk` assertions are run against the pre-change `models.sh`. Record
   both runs.
5. Run the new entrypoint from a cwd that is not the autometta root and show
   it finds its schema. `scripts/verify-sdk-schema-path-smoke.sh` still passes.
6. The api-sdk route is unchanged: `AUTOMETTA_CLAUDE_TRANSPORT=sdk
   --print-transport` against a subscription repo still downgrades to
   `cli (route-guard: ...)`.
7. No default changed. `bash scripts/spawn-verifier.sh --print-transport
   claude <repo with no transport in its manifest>` resolves exactly as it
   did before this card.

## Contract test

- **Test file:** scripts/verifier-route-matrix-smoke.sh
- **Assertions digest:** agent-sdk permitted on both credentials; api-sdk
  still refused on a subscription token; the guard still covers env and
  manifest provenance; the codex family still passes through unguarded.

## Out of scope

- Making `agent-sdk` the default transport for any repo or for the fleet.
- Retiring `scripts/verify-sdk.py` or the api-sdk surface.
- The worker SDK route (cards 23 and 98) and its two sandbox grants.
- Per-message usage plumbed into the registry or heartbeat. Record what the
  SDK reports; wiring it to the live-spend ticker is its own card.
- Any change to emergence-lab or any other subscriber.

## Budget

- **Worker wall-clock:** 90 minutes
- **Verifier wall-clock:** 45 minutes

## Escalation

If the Agent SDK cannot be made to return an artefact that validates against
`schemas/verifier.json` -- for instance if structured output is unreliable
without a tool-shaped contract -- record what it did return, alongside the
prompt that produced it, and stop. Do not loosen `schemas/verifier.json` to
make a run pass: the schema is the contract every other route already meets,
and widening it to accommodate one transport silently lowers the bar for all
of them.

If the subscription token is refused by the Agent SDK too, that is a genuinely
new finding and the card is answered by recording it. Say so plainly rather
than falling back to `ANTHROPIC_API_KEY`, which would pass the criteria while
testing nothing this card exists to establish.

## Verifier handoff

You have the subscription credential, so run the deliverable rather than
reading about it. Execute criteria 1, 2, 3, 5, 6 and 7 yourself. For criterion
4, check out the pre-change `scripts/models.sh` into a scratch path and
confirm the smoke's `agent-sdk` assertions fail against it -- a contract test
that passes both before and after proves nothing.

Two specific things to disbelieve. First, that the entrypoint really is the
Agent SDK: grep its imports, do not trust the filename, since a filename
saying `sdk` while the code said `anthropic` is the whole reason this card
exists. Second, that criterion 2's run used the subscription token: confirm
the transcript shows `CLAUDE_CODE_OAUTH_TOKEN` as the credential and that
`ANTHROPIC_API_KEY` was absent from the environment, because an API key
present in the parent shell silently wins the resolution order and would make
a green run meaningless. That is exactly how card 89 passed while being wrong.
