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
4. The script's CLI surface accepts `--stage-id`, `--card`, `--artefact-glob`, `--out`, all four are required, and missing any of them produces a clear argparse-style error.
5. The intended output JSON shape (documented in `docs/sdk-verifier.md`) names the same top-level keys as an existing `state/verifiers/<stage-id>.json` artefact: `stage_id`, `verifier_identity`, `verifier_invocation`, `ran_at`, `criteria` (array of `{id, name, verdict, evidence}` objects), `additional_findings`, `overall`. The doc shows a literal example envelope matching the existing shape exactly.
6. The script's exit-code mapping is documented in `docs/sdk-verifier.md`: `0` for `overall=PASS`, `1` for `overall=FAIL`, `2` for environment errors (missing key, missing SDK). The implementation matches the doc (verifier reads the source and confirms).
7. `memory/decision-sdk-verifier-prototype.md` follows the decision-memo format (Decision / Why / How to apply, plus a `[[link]]` to `decision-auth-route-toggle`).
8. No files outside the deliverables list are modified.
9. The cd-fix at `9e282f3` is not reverted (regression guard).

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

Worker writes the four deliverables and confirms acceptance #1-#4 by running the `--help` and missing-arg invocations in its completion message. No live API call is part of this stage; live verification of the SDK call path is deferred to card 15c, which wires the SDK route into `spawn-verifier.sh` and requires the operator to add `OP_REF_ANTHROPIC_API_KEY` to `~/.config/autometta/op-refs.local.sh` as a prerequisite. Verifier reads the card and the four deliverables, runs `python3 scripts/verify-sdk.py --help` once to confirm #1, and writes `state/verifiers/15a-sdk-verifier-probe.json` per the rubric.

## Prerequisite for downstream cards

15a does not invoke the SDK; it produces the script and the documentation. Before card 15c can wire the SDK route into `spawn-verifier.sh`, the operator must:

1. Set `OP_REF_ANTHROPIC_API_KEY="op://<vault>/<item>/credential"` in `~/.config/autometta/op-refs.local.sh` (or the dev-checkout fallback).
2. Decide whether to keep `auth.claude.mode: subscription` (in which case the SDK route on `spawn-verifier.sh` is opt-in per dispatch via `AUTOMETTA_CLAUDE_MODE=api`) or flip to `api` in the manifest for the repos that will use the SDK verifier route.

Neither of these is required for 15a itself. Surfaced here so the chain is honest.

## Family-specific notes

- **Codex (worker):** redirect stdin from `/dev/null` when invoking pip or python in any wrapping script (lessons.md gotcha #1). Sandbox is `workspace-write`; no out-of-tree writes are needed.
- **Claude (verifier):** runs outside the worker sandbox per the cross-family verification invariant. The verifier may run `python3 scripts/verify-sdk.py --help` to confirm acceptance #1.
