# Stage card 16-sdk-verifier-prompt-cache: Enable Anthropic prompt caching on the SDK verifier route

## Metadata

- **Authored:** 2026-05-27
- **Orchestrator:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Worker:** Claude Sonnet 4.6 <claude-sonnet-4-6@local>
- **Verifier:** Codex GPT-5.3 <codex-gpt-5-3@local>
- **Pairing rationale:** Cross-family. Sonnet makes the SDK config change via the Claude OAuth route; Codex verifies via the API route that cache_read_input_tokens grows on the second run by inspecting the SDK response usage block.
- **Depends on:** stage 15c committed and merged. Acceptance criteria below assume `scripts/verify-sdk.py` and the manifest-driven SDK route exist.

## Surfacing concern

The verifier prompt re-includes the same boilerplate every dispatch: the rubric prose from `templates/verifier-prompt.md`, the JSON schema reference, the dispatch contract reminders, and stable parts of the stage card. Across N stages this is N x ~3-5k tokens of identical input charged at full rate. Anthropic prompt caching with a 5-minute TTL (or 1-hour on supported models) trivially recovers that cost once consecutive verifier calls happen inside the window — which is exactly what `tick.sh` produces in active periods.

## Objective

Mark the static portion of the SDK verifier's input as cacheable via the `cache_control: {type: "ephemeral"}` block, log the cache-token counts to stderr after each run, and add a smoke test that proves a cache hit on the second consecutive call with identical static content. No changes to `claude -p` route.

## Inputs

- `scripts/verify-sdk.py` — the file to modify.
- `templates/verifier-prompt.md` — the boilerplate that gets cached.
- `schemas/verifier.json` — included in the cached block as the schema reference.
- Anthropic SDK docs on prompt caching (worker reads via SDK package docstrings; no live web fetch).

## Deliverables

1. `scripts/verify-sdk.py` — restructure the messages to put cacheable content (system prompt + rubric prose + schema) in a single block marked `cache_control: {type: "ephemeral"}`, and put the per-stage content (card + artefacts) in a non-cached block. Log `cache: write=<N> read=<M> input=<I> output=<O>` to stderr after each call.
2. `scripts/sdk-cache-smoke.sh` — runs `verify-sdk.py` twice against stage 14 in quick succession, parses the cache log lines, asserts that the second run has `read>0`. Exits 0 on cache hit, non-zero with a clear message on miss.
3. `docs/sdk-verifier.md` — extend with "Prompt caching" section: what is cached, what is not, TTL window, how to read the log line, when the cache misses (template changes, schema changes, model change).
4. `memory/decision-sdk-verifier-prompt-cache.md` — decision memo. Why ephemeral (5min) not 1-hour, why the schema is cached alongside the rubric, why the per-stage card is the cache-bust boundary, what changes invalidate the cache.

## Constraints

- No change to the verifier's output shape (the artefact JSON must still validate against `schemas/verifier.json`).
- No change to `spawn-verifier.sh` or `tick.sh`.
- The cached block must be large enough to be eligible (Anthropic minimum is ~1024 tokens for Sonnet, ~2048 for Opus — pad with the schema and dispatch contract reminders if the rubric alone is too small).
- Cache misses on a normal subsequent run (within 5 min, same template, same schema) are a regression. The smoke test guards this.
- The cache log line must never include any cached content — only the four counts.
- No telemetry beyond stderr.

## Acceptance criteria

1. `python3 scripts/verify-sdk.py --help` still works post-change.
2. First run of `scripts/sdk-cache-smoke.sh` (cold cache) logs `cache: write=<N>0` and `read=0`. (i.e. writes happen, reads are zero.)
3. Second run within 5 minutes logs `read>0` and the script exits 0.
4. Running the smoke test a third time after `touch templates/verifier-prompt.md && sleep 1` (or otherwise mutating the cached block) logs `read=0` on the next call.
5. The artefact written by both cached and non-cached runs validates against `schemas/verifier.json`.
6. The artefact's `overall` value is identical between cached and non-cached runs for stage 14 (cache must not change verifier behaviour).
7. `docs/sdk-verifier.md` Prompt caching section names the cache TTL, the cached block contents, and the cache-bust boundary.
8. `memory/decision-sdk-verifier-prompt-cache.md` links to `[[decision-sdk-verifier-integration]]`.
9. No files outside the deliverables list are modified.

## Out of scope

- Caching on the `claude -p` route. The CLI does not expose cache controls; this is one of the reasons we moved to the SDK route in 15c.
- 1-hour cache beta. Stick to ephemeral until a longer cadence is needed.
- Caching the per-stage content. Card + artefacts are the bust boundary by design.
- Codex worker caching. Different SDK, different pricing model, separate card.

## Budget

- **Worker wall-clock:** 30 minutes.
- **Verifier wall-clock:** 15 minutes.

## Verifier handoff

Worker writes the deliverables, runs `scripts/sdk-cache-smoke.sh`, pastes the two cache log lines in its completion message, and pastes the cache-bust log line from acceptance #4. Verifier reads the card and deliverables, re-runs the smoke test once, reads the cache log lines, and writes `state/verifiers/16-sdk-verifier-prompt-cache.json`.

## Family-specific notes

None. Both the worker change and the verification are family-neutral once the SDK route exists.
