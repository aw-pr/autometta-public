# Stage card 110: preserve keeps what the card called a deliverable

## Metadata

- **Authored:** 2026-09-06
- **Orchestrator:** Claude Fable 5.1 <claude-fable-5-1@local>
- **Worker:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Verifier:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Base branch:** dev
- **Run branch:** autometta/110-preserve-keeps-what-the-card-called-a-deliverable
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/tick.sh, scripts/requeue-stage.sh, scripts/preserve-failed-work-smoke.sh, skills/autometta-requeue/SKILL.md, stage-cards/110-preserve-keeps-what-the-card-called-a-deliverable.md
- **Pairing rationale:** cross-family. Preservation is the safety net under every re-queue; the
  verifier's job is to lose work on purpose and confirm it cannot.
- **Type:** Data-loss guard on the preserve and re-queue paths. Touches `scripts/tick.sh`, so serial.

## Surfacing concern

`preserve_failed_work` (`scripts/tick.sh:1512-1605`) commits with
`git add -- . ':(exclude)state'`, which honours `.gitignore`. Stage 75's
first attempt on 2026-09-03 had rendered its three deliverable frames into
`e2e/artifacts/`, which emergence-lab ignores; the preserve commit did not
carry them, `requeue-stage.sh` then removed the worktree, and the frames
were gone. The re-brief had to tell attempt 2 to regenerate them
(`docs/runs/2026-09-03-evening-watch.md:24` in emergence-lab). The same
path lost stage 69's uncommitted work on 2026-09-01 by a different route
(a stall preserves nothing), recorded in that repo's `HANDOFF.md`.

## Objective

A preserve captures every file the card names as a deliverable, ignored
or not, and a re-queue refuses to remove a worktree that still holds
ignored files newer than the dispatch that nobody has preserved.

## Inputs (read these in your own context)

- `scripts/tick.sh:1512-1605`, `preserve_failed_work`
- `scripts/requeue-stage.sh`, the worktree removal
- `scripts/preserve-failed-work-smoke.sh`, the existing fixture
- `templates/stage-card.md`, the Deliverables section, whose paths are the
  list to honour
- `skills/autometta-requeue/SKILL.md`

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. `preserve_failed_work` parses the card's Deliverables section for
   repo-relative paths and adds them with `git add -f -- <path>` when they
   exist in the worktree, after the ordinary add. A path that is a
   directory is added recursively. Files over a size limit
   (`AUTOMETTA_PRESERVE_MAX_MB`, default 50) are skipped with a log line
   naming them.
2. The tick also preserves on a **stall**, not only on a verifier FAIL, so a
   stalled stage has a WIP branch before anything removes its worktree.
3. `scripts/requeue-stage.sh` refuses (non-zero, with the file list) when the
   run worktree holds ignored files with mtime later than the stage's
   `started_at` and no `wip_commit` is recorded for the attempt; `--discard`
   overrides.
4. `scripts/preserve-failed-work-smoke.sh` gains cases: an ignored
   deliverable is in the WIP commit; an ignored non-deliverable is not; a
   stall produces a WIP branch; requeue refuses the unpreserved-ignored case
   and proceeds after preserve. Frozen block around the new assertions.
5. `skills/autometta-requeue/SKILL.md`: the refusal and `--discard` are
   documented in the procedure.

## Constraints

- `state/` is still excluded from every preserve.
- Never `git add -A`; only card-named paths bypass the ignore rules.
- The existing smoke's cases keep passing unchanged.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. A fixture card naming `out/frame.png` as a deliverable, with `out/`
   ignored, produces a WIP commit containing `out/frame.png`.
2. The same fixture with the file renamed to something the card does not
   name produces a WIP commit without it.
3. A stalled fixture stage has a `wip_commit` in `state.yaml` before its
   worktree is removed.
4. `requeue-stage.sh` on a worktree with a fresh ignored file and no
   `wip_commit` exits non-zero naming the file; with `--discard` it proceeds.
5. `scripts/preserve-failed-work-smoke.sh` and `scripts/requeue-reset-smoke.sh`
   pass; the new cases fail against the pre-change scripts.

## Contract test

- **Test file:** scripts/preserve-failed-work-smoke.sh
- **Assertions digest:** frame the assertions in a block between the begin
  marker and the end marker, the begin marker naming this card by its
  `card=stage-cards/110-preserve-keeps-what-the-card-called-a-deliverable.md` field, and replace this line's text with the real
  digest printed by `scripts/check-contract-test-gate.sh print scripts/preserve-failed-work-smoke.sh`. Do not
  write a `sha256:` comment inside the block, and do not spell the marker
  tokens anywhere in this card's prose; the card is in your path claims for
  exactly this edit.

## Out of scope

- Stashing ignored files that no card names.
- Retro-recovering stage 75's frames.

## Budget

- **Worker wall-clock:** 90 minutes
- **Verifier wall-clock:** 45 minutes

## Escalation

If parsing Deliverables paths out of card prose is ambiguous for real
cards (paths in backticks, paths with globs, prose paths), report the
shapes found in `stage-cards/` and implement the backticked-path form only,
saying so in the envelope.

## Verifier handoff

Lose the file yourself: build the ignored-deliverable fixture, run a
verifier FAIL through the fixture tick, run requeue, and check the WIP
branch. Then confirm the negative: a 200 MB ignored file named as a
deliverable is skipped with a log line, not committed. Check that the
stall-preserve does not fire on a paused stage (card 97 made pause
distinct from stall).

## Family-specific notes

None

## Seat history (2026-09-06)

The Codex subscription closed at 10:31Z and this batch was re-seated onto
Claude alone; when Claude session windows then drained faster than the batch
was sized for, the verifying seat moved to the free local route
(`gpt-oss:120b` via `codex exec --oss`). The Codex window reopened the same
afternoon and the card is back on the seats it was authored with. Nothing
about the work changed across either move.
