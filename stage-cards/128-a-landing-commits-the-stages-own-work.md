# Stage card 128: a landing commits the stage's own work

## Metadata

- **Authored:** 2026-09-06
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Codex GPT-5.6 Sol <codex-gpt-5-6-sol@local>
- **Verifier:** Claude Opus 5 <claude-opus-5@local>
- **Base branch:** dev
- **Run branch:** autometta/128-a-landing-commits-the-stages-own-work
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/tick.sh, scripts/landing-scope-smoke.sh, docs/tick-loop.md, stage-cards/128-a-landing-commits-the-stages-own-work.md
- **Pairing rationale:** cross-family. The failure this card must not ship is
  a guard that passes a case it should refuse, which reads the same as a
  guard that works until the day it does not. A verifier from the other
  family reads the refusal path without the worker's assumption about which
  directory is which.
- **Type:** Landing correctness. Touches `scripts/tick.sh`, so serial.

## Surfacing concern

On 2026-09-06 the loop landed stage 124 with a commit containing none of
stage 124's eight declared path-claim files. It contained twenty-five
unrelated files instead: the orchestrator's uncommitted working tree in the
shared checkout, swept up whole and committed under the stage's name, the
stage's headline, and the stage's full `Autometta-Worker` /
`Autometta-Verifier` attribution. The stage's actual work stayed on its run
branch and never reached `dev`. Nothing in the log said so. The commit was
local, was noticed by reading it, and was reset by hand.

The mechanism is `_process_verifier_artefact` in `scripts/tick.sh:2152-2157`:

```sh
work_dir="$(worktree_path_for_stage "$repo_root" "$stage_id")"
local commit_dir="$repo_root"
if [[ -n "$base_branch" && -d "$work_dir" ]]; then
  commit_dir="$work_dir"
fi
```

`worktree_path_for_stage` derives the canonical path from the stage id. If
a worktree is not there -- it was moved, it was cut by hand under another
name, it was reaped early -- the condition is false and `commit_dir` stays
the shared checkout. The landing then runs `git add -- . ':(exclude)state'`
there and commits whatever it finds.

That fallback made sense before run worktrees existed, when the worker
committed in the shared tree. It is now a silent path from "the worktree is
not where I expected" to "commit the operator's unrelated work under a
stage's attribution". Two guards immediately above it refuse the landing on
a missing worker identity and on an empty diff, and both log why; this case
has neither a guard nor a log line.

The blast radius is not only a wrong commit. The stage is marked
`completed` on a commit that does not contain it, so the ledger, the facts
record and the run history all assert a landing that did not happen, and the
run branch that does hold the work looks merged.

## Objective

A landing commits the work of the stage it names, or it does not commit at
all. Falling back to the shared checkout is never how a stage with a
declared base branch lands.

## Inputs (read these in your own context)

- `scripts/tick.sh:2140-2200`, `_process_verifier_artefact` from the
  `commit_subject` down to the commit itself
- `worktree_path_for_stage` and `finalize_run_worktree` in the same file
- `scripts/preserve-failed-work-smoke.sh`, for how an existing smoke drives
  a landing offline against a fixture repo

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. A stage with a `base_branch` whose run worktree is absent from the
   canonical path does not land. `_process_verifier_artefact` refuses,
   returns non-zero, leaves the stage's status untouched by the landing, and
   logs a line naming the stage, the path it looked for, and the fact that
   nothing was committed. Model the refusal on the missing-worker-identity
   guard directly above it, which is the same shape of failure.

2. The refusal is distinguishable in the log from the two existing
   refusals, so an operator reading a tick log can tell "no worker identity"
   from "no worktree" without opening the state file.

3. A stage with no `base_branch` still commits in the shared checkout
   exactly as it does today. That is the pre-worktree path and this card
   does not change it.

4. `scripts/landing-scope-smoke.sh`, new, offline, driving
   `_process_verifier_artefact` against fixture repos. Frozen block around
   the assertions per the contract-test gate.

5. `docs/tick-loop.md` states that a landing is scoped to the stage's run
   worktree, and that a missing worktree is a refusal rather than a
   fallback. Name what the operator does next: the run branch holds the
   work and is merged by hand.

## Constraints

- Do not widen this into recovering or re-creating a missing worktree. The
  refusal is the deliverable; recovery is a different card.
- Do not change `finalize_run_worktree`, the diverged/awaiting record, or
  the push path.
- Do not add a path-claim check to the landing. Whether a stage's diff
  matches its declared claims is worth doing and is not this card: this one
  is about committing in the wrong directory entirely.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. Fixture: a stage with `base_branch: dev`, a PASS artefact, no worktree at
   the canonical path, and dirty unrelated files in the shared checkout. The
   landing commits nothing, the shared checkout's HEAD is unchanged, and
   those dirty files are still uncommitted afterwards.
2. The same fixture logs a line naming the stage id and the absent worktree
   path, and that line is not the missing-worker-identity line and not the
   empty-diff line.
3. Fixture: the same stage with its worktree present. It lands from the
   worktree exactly as it does today, and the commit's file list is the
   worktree's diff, not the shared checkout's.
4. Fixture: a stage with no `base_branch` and a dirty shared checkout lands
   in the shared checkout, byte-for-byte as on clean `dev`.
5. Reproduce the original defect against the pre-change `scripts/tick.sh`:
   the 2026-09-06 shape (declared base branch, worktree absent, dirty shared
   tree) produces a commit containing the shared tree's files. Assert it
   fails against the pre-change script and passes after.
6. `scripts/landing-scope-smoke.sh` passes.
   `scripts/preserve-failed-work-smoke.sh` and
   `scripts/budget-cap-smoke.sh` are no more red than on clean `dev`.
7. `docs/tick-loop.md` says a missing worktree refuses rather than falls
   back, and says what the operator does next.

## Contract test

- **Test file:** scripts/landing-scope-smoke.sh
- **Assertions digest:** frame the assertions in a block between the begin
  marker and the end marker, the begin marker naming this card by its
  `card=stage-cards/128-a-landing-commits-the-stages-own-work.md` field, and replace this line's text with the real
  digest printed by `scripts/check-contract-test-gate.sh print scripts/landing-scope-smoke.sh`. Do not
  write a `sha256:` comment inside the block, and do not spell the marker
  tokens anywhere in this card's prose; the card is in your path claims for
  exactly this edit.

## Out of scope

- Checking a landing's diff against the card's declared path claims.
- Re-creating, moving or repairing a missing worktree.
- Anything about the run branch's merge into base.

## Budget

- **Worker wall-clock:** 60 minutes
- **Verifier wall-clock:** 45 minutes

## Escalation

If the refusal cannot be made without changing how a stage's status is
written on a failed landing, stop and report. Leaving the stage in the
status it already had is the point: a stage that did not land must not read
as landed.

## Verifier handoff

The interesting case is not the refusal, it is criterion 3 and 4: a guard
that refuses everything would pass criteria 1 and 2 and break every normal
landing. Drive a real landing from a present worktree and check the
committed file list is the worktree's, then drive the no-base-branch path
and check it still commits in the shared tree. Then look for the reverse
error: a `-d` test that a *file* at the canonical path would satisfy, or a
`cd` that succeeds into a directory that is not a git worktree at all.

## Family-specific notes

None
