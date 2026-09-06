# Stage card 122: the verifier scripts do not depend on where they were started

## Metadata

- **Authored:** 2026-09-06
- **Orchestrator:** Claude Fable 5.1 <claude-fable-5-1@local>
- **Worker:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Verifier:** Claude Opus 5 <claude-opus-5@local>
- **Base branch:** dev
- **Run branch:** autometta/122-the-verifier-scripts-do-not-depend-on-where-they-were-started
- **Worker effort:** low
- **Verifier effort:** medium
- **Verifier panel:** false
- **Path claims:** scripts/retro-grade-batch.py, scripts/verify-sdk.py, scripts/cwd-independence-smoke.sh, stage-cards/122-the-verifier-scripts-do-not-depend-on-where-they-were-started.md
- **Pairing rationale:** cross-model, single family (re-seated 2026-09-06, see below). Same defect family as the schema path fixed on 2026-09-01;
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
- **Assertions digest:** frame the assertions in a block between the begin
  marker and the end marker, the begin marker naming this card by its
  `card=stage-cards/122-the-verifier-scripts-do-not-depend-on-where-they-were-started.md` field, and replace this line's text with the real
  digest printed by `scripts/check-contract-test-gate.sh print scripts/cwd-independence-smoke.sh`. Do not
  write a `sha256:` comment inside the block, and do not spell the marker
  tokens anywhere in this card's prose; the card is in your path claims for
  exactly this edit.

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

## Re-seat (2026-09-06, Codex subscription exhausted)

Both Codex seats were unavailable from 10:31Z with the subscription window
closed until 14:49Z, and every card in this batch carried one, so the queue
could not move. On the operator's instruction the batch was re-seated onto
Claude alone: high-effort cards run Opus as worker and Sonnet as verifier,
the rest run Sonnet as worker and Opus as verifier, so worker and verifier
are never the same model.

What this keeps: the sandbox boundary, which is what makes worker
self-verification structurally impossible, is a property of the dispatch and
not of the vendor, so it is untouched. What it costs: judgement diversity.
A Claude verifier shares training and failure modes with a Claude worker in
a way a Codex verifier did not, so a wrong assumption the worker makes is
likelier to survive verification. Two different Claude models recover part
of that and not all of it. Read this card's acceptance criteria as needing
more, not less, evidence than usual.
