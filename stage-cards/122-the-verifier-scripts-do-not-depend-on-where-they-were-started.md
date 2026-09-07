# Stage card 122: the verifier scripts do not depend on where they were started

## Metadata

- **Authored:** 2026-09-06
- **Orchestrator:** Claude Fable 5.1 <claude-fable-5-1@local>
- **Worker:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Verifier:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Base branch:** dev
- **Run branch:** autometta/122-the-verifier-scripts-do-not-depend-on-where-they-were-started
- **Worker effort:** low
- **Verifier effort:** medium
- **Verifier panel:** false
- **Path claims:** scripts/retro-grade-batch.py, scripts/verify-sdk.py, scripts/cwd-independence-smoke.sh, stage-cards/122-the-verifier-scripts-do-not-depend-on-where-they-were-started.md
- **Pairing rationale:** cross-family. Same defect family as the schema path fixed on 2026-09-01;
  the verifying seat verifies by running both scripts from a directory that is
  not the repo.
- **Type:** Latent-defect repair. Pipeline-eligible.

## Surfacing concern

`verify-sdk.py` died one second after every subscriber dispatch until
2026-09-01 because it read `schemas/verifier.json` relative to cwd
(`HANDOFF.md`, the 2026-09-01 section). That path was fixed to
`AUTOMETTA_ROOT / "schemas" / "verifier.json"` (`scripts/verify-sdk.py:25`).
Two siblings remain: `scripts/retro-grade-batch.py:19` still reads
`Path("schemas/verifier.json")` (and `STATE`, `VERIFIER_TEMPLATE`,
`REPORT_TEMPLATE` beside it), and `scripts/verify-sdk.py:57` writes its
live-usage registry to `Path("state/active-agents")`, which lands in
whatever directory the verifier was started in.

## Objective

Every path either script opens is anchored to the autometta root or to
an explicit repo argument, never to cwd.

## Inputs (read these in your own context)

- `scripts/retro-grade-batch.py:1-60`
- `scripts/verify-sdk.py:20-70`
- how `AUTOMETTA_ROOT` is derived in `verify-sdk.py`, to reuse it

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. `retro-grade-batch.py`: the four module-level paths anchor to the
   autometta root for schema and templates and to a `--repo` argument
   (default: the autometta root) for `state/state.yaml`.
2. `verify-sdk.py`: the active-agents registry path anchors to the repo the
   verifier is verifying (it already knows it; find the variable) and the
   directory is created if absent.
3. `scripts/cwd-independence-smoke.sh`: runs both scripts in `--help` or
   dry-run form from a temporary directory and asserts no file is created
   there and no `FileNotFoundError` is raised. Frozen block around those
   assertions.

## Constraints

- No behaviour change when run from the repo root.
- Do not touch `verify-sdk-agent.py` or `verify-sdk-openai.py` unless the
  same literal appears there; if it does, fix it and say so.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. `cd /tmp && python3 <root>/scripts/retro-grade-batch.py --dry-run` (or its
   nearest no-op form) exits 0 and creates nothing under `/tmp`.
2. A verifier run from a subscriber worktree writes its registry under that
   subscriber's `state/active-agents/`, not under cwd.
3. `scripts/cwd-independence-smoke.sh` passes and fails against the
   pre-change scripts.

## Contract test

- **Test file:** scripts/cwd-independence-smoke.sh
- **Assertions digest:** sha256:ab2e2698757d5583d124fe6cfda71189c0c2273e8183ae319131335575df633d

## Out of scope

- Anything else in the two scripts.

## Budget

- **Worker wall-clock:** 30 minutes
- **Verifier wall-clock:** 20 minutes

## Escalation

If `retro-grade-batch.py` has no dry-run or help path that exercises the
file opens, add `--check-paths` that resolves and prints them without
running, and say so.

## Verifier handoff

Run both scripts from `/tmp` yourself and `ls -la /tmp` afterwards.

## Family-specific notes

None

## Seat history (2026-09-06)

The Codex subscription closed at 10:31Z and this batch was re-seated onto
Claude alone; when Claude session windows then drained faster than the batch
was sized for, the verifying seat moved to the free local route
(`gpt-oss:120b` via `codex exec --oss`). The Codex window reopened the same
afternoon and the card is back on the seats it was authored with. Nothing
about the work changed across either move.

## Seat change (2026-09-07): Codex weekly quota exhausted

The verifier seat moved from Codex GPT-5.6 to Claude Opus 5 because the
Codex weekly window reached 95% at 01:59 BST and resets at 09:43 BST. The
operator's standing instruction was to swap to Claude rather than stall the
run when Codex runs out.

**This stage no longer has cross-family verification.** Its worker is Claude
Sonnet 5 and its verifier is now Claude Opus 5: a different model, which is
the binding seat rule, but the same family. Cross-family verification is a
load-bearing belief in this repo, not a preference, and the judgement
diversity it buys is not present here. Read this stage's verdict knowing
that, and treat it as a candidate for re-verification on a Codex seat once
the window resets if anything about it later looks wrong.

Opus rather than Sonnet is deliberate: Sonnet 5 is the working seat, and the
same model on both sides of the gate is not verification at all.

## Seat restored (2026-09-07 17:06)

The Codex window is back, so the verifying seat returns to Codex GPT-5.6
Terra and this stage regains cross-family verification. The overnight swap
to Claude Opus 5 recorded in the section above never took effect: the batch
halted on the token cap before this card was dispatched, so no verdict was
ever taken on a same-family seat. Read the section above as history, not as
a caveat on this stage's result.

