# Stage card 15a-sdk-verifier-probe: Probe Claude Agent SDK and build a minimal verifier prototype against one existing stage

## Metadata

- **Authored:** 2026-05-27
- **Orchestrator:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Worker:** Codex GPT-5.3 <codex-gpt-5-3@local>
- **Verifier:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Pairing rationale:** Cross-family default. Codex builds a Python SDK scaffold against a clear acceptance contract; Claude verifies the JSON shape and rubric output against a known-good stage.

## Surfacing concern

`claude -p` is the only Claude surface autometta uses today, and it has two known gotchas (lessons.md #6, #7): the log file stays empty until completion, and `--permission-mode bypassPermissions` plus `-p` exits silently. The Agent SDK is the documented programmatic surface for the same model family, with streaming, structured tools, and hooks. Before changing any spawn script we need to prove the SDK can produce a verifier-shaped rubric output against an existing stage card.

## Objective

Stand up a minimal Python Agent SDK script at `scripts/verify-sdk.py` that reads one stage card + one worker artefact set, runs the Claude Agent SDK against a verifier prompt, and writes a `state/verifiers/<stage-id>.json` artefact matching the existing verifier JSON shape. No integration into `spawn-verifier.sh` yet. No changes to existing dispatch. Pure prototype.

## Inputs (read these in your own context)

- `examples/self-host/14-auth-route-toggle.md` — the canonical recent card to verify against.
- `scripts/spawn-verifier.sh` — current verifier dispatch; for shape reference only, do not modify.
- `state/verifiers/` — example artefacts from past stages (read one to learn the JSON shape).
- `templates/verifier-prompt.md` — the prompt the SDK script will use.
- `op-refs.sh` + `~/.config/autometta/op-refs.local.sh` — for the OP_REF_ANTHROPIC_API_KEY env var name.

## Deliverables

1. `scripts/verify-sdk.py` — Python entrypoint. Accepts `--stage-id`, `--card`, `--artefact-glob`, `--out`. Reads card + artefacts, calls the Agent SDK with the verifier prompt, writes the JSON artefact. Uses `os.environ['ANTHROPIC_API_KEY']` (caller is expected to use `op-fetch` to inject it).
2. `scripts/requirements-sdk.txt` — pinned `claude-agent-sdk` version. Single-line file, no other deps.
3. `docs/sdk-verifier.md` — one-page note: what the prototype does, what it does not yet do, how to invoke for manual smoke test, known gaps before 15b.
4. `memory/decision-sdk-verifier-prototype.md` — decision memo. Why SDK over staying on `claude -p`, why Python over TypeScript, why prototype-only before touching `spawn-verifier.sh`.

## Constraints

- No modifications to `scripts/spawn-verifier.sh`, `bin/autometta`, or any existing dispatch.
- No new system dependencies beyond what `pip install -r scripts/requirements-sdk.txt` covers. Operator runs the pip install once; the card does not invoke pip.
- The script must work whether or not the SDK is installed: if the import fails, exit 2 with a clear message naming the requirements file, do not crash with a stack trace.
- Output JSON shape must match an existing `state/verifiers/<stage-id>.json` artefact. Do not invent a new shape.
- No telemetry, no logging beyond stderr.
- The script must accept `ANTHROPIC_API_KEY` only via env; never read 1Password directly. Auth is the caller's job (op-fetch).

## Acceptance criteria

1. `python3 scripts/verify-sdk.py --help` prints usage and exits 0.
2. With `ANTHROPIC_API_KEY` unset and the SDK installed, the script exits non-zero with a clear "missing ANTHROPIC_API_KEY" message and does not call any API.
3. With the SDK not installed (simulated by removing the package), the script exits 2 with a message naming `scripts/requirements-sdk.txt`.
4. Invoked via `op-fetch OP_REF_ANTHROPIC_API_KEY -- python3 scripts/verify-sdk.py --stage-id 14-auth-route-toggle --card examples/self-host/14-auth-route-toggle.md --artefact-glob 'scripts/auth-route.sh,scripts/auth.sh,bin/autometta' --out /tmp/v15a.json`, it writes a JSON file with the same top-level keys as the existing `state/verifiers/14-auth-route-toggle.json`.
5. The output JSON contains an `overall` key with value `PASS` or `FAIL`, and a per-criterion `checks` array.
6. The script's exit code is `0` for `overall=PASS`, `1` for `overall=FAIL`, `2` for environment errors. The current `claude -p` flow conflates 0 and PASS, which we are deliberately keeping.
7. `docs/sdk-verifier.md` exists and is referenced from `README.md` section "Verification" (one-line addition, not a rewrite).
8. `memory/decision-sdk-verifier-prototype.md` follows the decision-memo format (Decision / Why / How to apply, plus a `[[link]]` to `decision-auth-route-toggle`).
9. No files outside the deliverables list are modified.
10. The cd-fix at `9e282f3` is not reverted (regression guard).

## Out of scope

- Integration into `spawn-verifier.sh` — that is card 15c.
- Prompt caching — that is card 16.
- Structured rubric contract beyond matching the existing shape — that is card 15b.
- TypeScript SDK port. Python only for v1.
- Fallback behaviour when SDK is unavailable but `claude -p` is. The prototype is opt-in; production dispatch still uses `claude -p`.

## Budget

- **Worker wall-clock:** 45 minutes.
- **Verifier wall-clock:** 20 minutes.

## Verifier handoff

Worker writes the four deliverables, runs the smoke test from acceptance #4 against stage 14, attaches the resulting `/tmp/v15a.json` path in its completion message, and reports any deviation from the existing JSON shape. Verifier reads the card, the four deliverables, and `/tmp/v15a.json`, then writes `state/verifiers/15a-sdk-verifier-probe.json` per the rubric.

## Family-specific notes

- **Codex (worker):** redirect stdin from `/dev/null` when invoking pip or python in any wrapping script (lessons.md gotcha #1). Sandbox is `workspace-write`; this card needs no out-of-tree writes except the `/tmp/v15a.json` smoke test, which is permitted under the sandbox.
- **Claude (verifier):** runs outside the worker sandbox per the cross-family verification invariant. The verifier may run `python3 scripts/verify-sdk.py --help` to confirm acceptance #1.
