# Stage card 39-loop-moves-head-in-the-shared-tree: a tick changes the branch under whoever else is working, and a finished run worktree has no disposition

## Metadata

- **Authored:** 2026-08-23
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Claude Opus 5 <claude-opus-5@local>
- **Verifier:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes
- **Pairing rationale:** cross-family. Both defects are about git state in a
  tree two processes share, where the failure is a race rather than a wrong
  line, and a same-family verifier is the one most likely to re-inherit the
  assumption that the window is too small to matter.

## Objective

The loop dispatches into an ephemeral sibling worktree precisely so it never
touches `repo_root`. Two paths still do, five minutes apart, forever.

Make the tick keep its hands off the shared working tree, and give a finished
run worktree a disposition rather than leaving it standing.

## Reported by

Both found on 2026-08-23 while landing cards 33, 37 and 38 by hand. Defect A
was found by being bitten: an orchestrator commit landed on the wrong branch.

### Defect A: `commit_state_branch` checks out a branch in `repo_root`

`scripts/tick.sh`, every tick, per subscriber:

```sh
original_branch="$(git rev-parse --abbrev-ref HEAD)"
trap 'git checkout "$original_branch" >/dev/null 2>&1 || true' EXIT
git checkout -B phat-controller/state >/dev/null 2>&1
git add state/state.yaml state/budget.json ...
git commit ...
```

The trap restores the operator's branch afterwards, so the window is short and
the function looks safe in isolation. It is not, because `repo_root` is shared:
anyone committing during that window commits to `phat-controller/state`.

That is not hypothetical. Retiring card 36 today produced commit `2d4dc08`,
authored against `dev`, landed on `phat-controller/state`, and only noticed
because `git push origin dev` answered "Everything up-to-date". It was
recovered with a cherry-pick as `1efd82a`. The reflog shows four HEAD moves
between the two branches inside two minutes, one per tick.

The fleet job runs every 300 seconds against every subscriber, so this window
opens roughly 288 times a day per repo, in a tree the operator is expected to
work in. It also silently truncates: `git checkout -B` resets the branch ref to
the current HEAD, so the stray commit becomes unreachable on the next tick.
Today's was recovered because it was noticed within minutes.

Note also that the `git add state/state.yaml` in that function is a documented
no-op, because the file is gitignored (`docs/lessons.md` gotcha 10). Whatever
replaces this must not quietly re-create the belief that the state file is
being backed up when it is not.

### Defect B: a finished run worktree has no disposition when base has moved

`finalize_run_worktree` fast-forwards `base_branch` to the run branch when base
has not moved since dispatch, and `teardown_run_worktree` then removes the
worktree. That path is clean, and card 38 took it today.

When base has moved, the run branch is pushed to `origin` and the worktree is
left standing "for manual integration". Three things are missing from that
path:

- nothing records that a stage is awaiting integration anywhere a person or a
  panel will see it. The stage is `completed`, the commit SHA is in
  `state.yaml`, and the only trace of the outstanding merge is one appended
  line in `HANDOFF.md`.
- nothing ever reaps the worktree. Card 33 noted this and recorded it in
  `docs/observability.md` for its own card; this is that card. A stage that
  neither completed nor was repaired leaves the same litter.
- base had moved for both stages that took this path today, and in both cases
  because the orchestrator had committed to `dev` between dispatch and PASS.
  That is the normal condition during an active session, not an edge case.

Cards 33 and 37 both had to be merged by hand as a result, each with real
conflicts, because each run worktree was cut before the previous stage landed.

## Inputs (read these in your own context)

- `scripts/tick.sh` - `commit_state_branch`, `ensure_run_worktree`,
  `finalize_run_worktree`, `teardown_run_worktree`, and the PASS path in
  `_process_verifier_artefact`.
- `scripts/requeue-stage.sh` - already removes a run worktree and branch, and
  is the sanctioned reset. Reuse it rather than duplicating the removal.
- `docs/lessons.md` - gotcha 10 on the gitignored state file, and gotcha 2 on
  the card-sync race across worktrees.
- `docs/observability.md` - where card 33 recorded the unreaped worktree.
- `docs/phat-controller.md`, `docs/dispatch-contract.md` - the loop and
  integration contracts these change.
- `schemas/state.yaml.json` - if a stage gains an integration field.
- `MANUAL.md` - the command table.
- `git reflog` in this repo, which still holds the evidence for defect A.

## Deliverables

- `scripts/tick.sh` - `commit_state_branch` no longer changes the branch in
  `repo_root`; run-worktree disposition on the base-moved path.
- `scripts/state-worktree.sh` - if a dedicated worktree needs its own
  create-or-reuse helper rather than living inline.
- `scripts/reap-worktrees.sh` - or an equivalent path in `tick.sh`, for run
  worktrees left by stages that neither completed nor were repaired.
- `scripts/state-branch-smoke.sh` - new. Asserts that a commit made in
  `repo_root` while `commit_state_branch` is running lands on the branch the
  committer was on.
- `schemas/state.yaml.json`, `docs/phat-controller.md`,
  `docs/dispatch-contract.md`, `docs/observability.md`, `MANUAL.md` as the
  changes require.

## Constraints

- `repo_root`'s HEAD must not move. A dedicated worktree for
  `phat-controller/state` is the expected shape, but any approach that leaves
  the operator's branch untouched qualifies; `git worktree` and plumbing
  commands such as `git commit-tree` both do.
- A dedicated state worktree is a fixture, not a per-tick creation. Creating
  and removing one every 300 seconds trades one cost for another.
- Do not silently change what is backed up. If `state.yaml` is gitignored and
  therefore not committed, say so in the code rather than leaving an `add` that
  looks like it works.
- Reuse `requeue-stage.sh` for any worktree removal.
- Reaping must never remove a worktree with uncommitted work that is not the
  known `state/` symlink artefact, and never one whose stage is `in_progress`.
- The loop must stay resumable and killable. No long-lived lock held across a
  dispatch.
- British English, no em dashes.

## Acceptance criteria

1. A commit made in `repo_root` while a tick is running lands on the branch the
   committer was on. Demonstrate with the race, not with an argument: commit
   during a tick and show the resulting branch.
2. `repo_root`'s HEAD is unchanged across a full tick, including a tick that
   writes state. Assert on `git rev-parse --abbrev-ref HEAD` before and after.
3. State is still committed somewhere durable each tick, and what is and is not
   captured is stated plainly in the code and in `docs/phat-controller.md`.
4. On the base-moved path, the outstanding integration is recorded somewhere a
   panel or a person will see, not only in `HANDOFF.md`.
5. A run worktree belonging to a stage that is neither `in_progress` nor
   awaiting integration is reaped, and one with unexpected uncommitted content
   is reported rather than removed.
6. `scripts/state-branch-smoke.sh` passes, and every existing smoke script
   still passes.

## Out of scope

- Changing when or how a worker is dispatched.
- Changing the ff-merge-when-base-is-clean path, which works.
- Deciding whether `state/state.yaml` should be tracked. Record what is true;
  the change is its own card.
- The `phat-controller/state` branch's existing history, including the stray
  `2d4dc08`. Leave it; the loop resets that ref every tick anyway.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes

## Notes for the worker

- The evidence for defect A is in this repo's reflog and in `2d4dc08` on
  `phat-controller/state`. Read it before designing; the shape of the race
  matters more than the description of it.
- Card 33 landed `--repair` and the single halt-clearing path, and card 37
  split the tick counters. Both touched `tick.sh` in the regions you will be
  in. Read their commits (`530af5a`, `98673a5`) rather than assuming the file
  looks like it did last week.
- The orchestrator committing to `dev` mid-session is the normal case, so
  treat the base-moved path as the common one and the ff path as the lucky one.
