# Stage card 169: the tail rebase keeps its own stash

## Metadata

- **Authored:** 2026-11-15
- **Orchestrator:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Worker:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Verifier:** GPT-6.1 Sol <gpt-6-1-sol@local>
- **Base branch:** dev
- **Run branch:** autometta/169-the-tail-rebase-keeps-its-own-stash
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Recovery attempts:** 3
- **Recovery attempt:** 1
- **Dispatch:** serial
- **Pairing rationale:** operator asked to maximise Claude spend; cross-family kept by a Codex verifier; serial, so no alternation needed. One function in `scripts/tick.sh` plus one doc paragraph, proved offline against throwaway git fixtures, so Opus at medium is enough.
- **Open decisions:** none
- **Cold read:** done 2026-11-15; see Cold read below for the family and findings.

## Surfacing concern

Finding H4 of the 2026-11-15 dispatch-path review (`docs/reviews/2026-11-15-dispatch-path.md`, private tier). `pipeline_prepare_tail_rebase` in `scripts/tick.sh` moves a pipeline tail's work onto the base branch after the head lands. It saves the tail's work with `git stash push`, reads the saved entry back from `refs/stash`, runs `git reset --hard <base_branch>`, then `git stash pop --index`. Two defects:

1. `refs/stash` is shared by every worktree of the repo. When the tail has committed work but nothing uncommitted (a worker that self-committed, which the landing path tolerates), `stash push` saves nothing and exits 0, and the pop then takes whatever stash is newest: the operator's own, from the main checkout. The operator's stash disappears from their list and its files land in the tail worktree as if the worker wrote them.
2. `reset --hard <base_branch>` moves the run branch off any commit the tail worker made, and the failure path (`reset --hard <old_base>`) does the same. Committed tail work is silently dropped on success and on failure.

Re-verified on `dev` at `8c2675d` with the frozen smoke below, which sources the real `tick.sh`: the operator's stash is popped into the tail worktree (`refs/stash` gone, `op.txt` present), the worker's commit is not on the run branch, a committed-only tail with no stash anywhere escalates with its commit gone, and a tail whose rebase cannot complete reports `tail-rebased` after dropping its commit.

## Objective

Rebasing a pipeline tail never reads, writes or pops the repo's shared `refs/stash`, keeps every commit the tail worker made (replayed onto the landed base with `git rebase`), restores the content of the tail's uncommitted and untracked files, and on any failure puts the tail's branch tip back on the worker's own `HEAD` with those files restored before escalating.

## Inputs (read these in your own context)

- `scripts/tick.sh` (`pipeline_prepare_tail_rebase`, `pipeline_escalate_tail`, `rebase_disjoint_run_branch` for the house style of a mechanical rebase, and `ensure_run_worktree` for the `state` symlink every run worktree carries)
- `scripts/tail-rebase-stash-smoke.sh` (the frozen contract test)
- `scripts/pipeline-pair-smoke.sh` (`formation_and_ordered_landing_smoke`, `conflict_escalation_smoke` and the card 113 block: existing callers that must stay green)
- `docs/tick-loop.md` (the "Landing is strict queue order" paragraph)

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/tick.sh`: rewrite the save, move and restore steps of `pipeline_prepare_tail_rebase`. Everything before them is unchanged: the pair and `rebase_required` guard, `return 2` while the tail worker is live, the input check and the actual-diff overlap check with its `pipeline-actual-diff-overlap` escalation. The new steps:
   - Record the tail worktree's `HEAD` before touching anything.
   - Save uncommitted and untracked work (excluding `state`) to an object or ref private to this call, never to `refs/stash`: for example stage it with `git add -A -- . ':(exclude)state'`, capture it with `git stash create` (which writes no ref) and clean the tree with `reset --hard HEAD`; or commit it to a temporary ref under `refs/autometta/`. `git stash create` alone ignores untracked files, and `git stash push`, `pop`, `drop`, `list` and `save` all use the shared ref; the function must not use any of them or name `refs/stash`.
   - If saving fails, nothing has moved yet: escalate without resetting anything.
   - Move the tail onto the landed base with `git rebase <base_branch>` in the tail worktree, so commits the worker made are replayed rather than reset away. With no worker commits this is a fast-forward to the base tip. Git's default rebase behaviour is accepted (a commit whose change is already upstream may be dropped by git as usual; worker merges and empty commits are not expected and need no special handling).
   - Re-apply the saved work (`git stash apply --index <sha>` accepts a `stash create` object).
   - On a failed rebase or re-apply: abort any rebase in progress, reset the tail worktree to the recorded `HEAD`, re-apply the saved work, and escalate exactly as today (`pipeline_escalate_tail ... "pipeline-rebase-conflict" "tail-rebase-failed"`, return 1).
   - File contents are what must survive; whether a restored change comes back staged or unstaged does not matter, because the landing commit stages everything (`git add -- . ':(exclude)state'`).
   - On success the state transition and log line are unchanged (`phase = "tail-rebased"`, `rebase_required = false`, `pair_rebased_onto`).
   - Leave no ref behind outside `refs/heads/`: remove any temporary ref you create, on both paths.
2. `docs/tick-loop.md`: the "Landing is strict queue order" paragraph says the tail's uncommitted work is saved privately (never on the shared stash list), its commits are rebased onto the new base, and a failure restores the tail as the worker left it before escalating. Replace "stashed, reset onto the new base, and restored".
3. The frozen smoke `scripts/tail-rebase-stash-smoke.sh` passes. Do not edit it.

## Constraints

- `refs/stash` and the operator's stash list are never read or changed by the tick, on any path.
- No change to the overlap rule, the escalation reasons and causes, the `return 2` deferral, `pipeline_pair` state fields, `rebase_disjoint_run_branch`, `ensure_run_worktree`, or any other function in `tick.sh`.
- The tail worktree's `state` symlink survives: every pathspec-taking command (`status`, `add`, `diff`, `clean`) excludes `state`. `reset --hard` takes no pathspec and leaves the untracked symlink alone, which the frozen smoke checks.
- No new dependency; git 2.x and the system bash (3.2 on macOS) only.
- Offline only: the smokes build throwaway repos under `mktemp -d`.
- The worker makes no commits and runs no git command that changes its own checkout; the smokes create and destroy their own fixture repos. The tick commits on PASS.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. **Worker and verifier:** `scripts/tail-rebase-stash-smoke.sh` exits 0 and prints `PASS: tail-rebase-stash-smoke`. Its frozen cases, each a fresh fixture repo whose tail worktree is cut by the real `ensure_run_worktree`: (1) the review's reproduction, a self-committed tail with nothing uncommitted and an operator stash in the main checkout: `refs/stash` and the one-entry stash list are unchanged, `op.txt` is not in the tail, the call returns 0 with phase `tail-rebased`, the worker's commit sits above `dev` on the run branch, which descends from the landed head, and `t.txt` and `h.txt` are in the tail; (2) the same plus an uncommitted edit and an untracked file, both restored; (2b) a committed-only tail with no stash anywhere rebases, and leaves `refs/stash` absent; (3) the ordinary uncommitted-only tail with an operator stash ends exactly on the landed head with its work restored and the stash untouched; (4) a tail whose own commit conflicts with a later `dev` commit (file-disjoint from the head, so the overlap check passes) returns 1, escalates (`controller-escalation`, tail `stalled`), keeps the run branch and worktree `HEAD` on the worker's commit, restores the uncommitted edit and untracked file, leaves no rebase in progress and the operator's stash untouched; (4b) a tail whose uncommitted edit cannot be re-applied over a later `dev` commit returns 1, escalates, is back on its recorded `HEAD` with the edit and untracked file restored, and leaves the stash list at the operator's one entry; (5) a live tail worker returns 2 and nothing moves. Cases 1 to 4b also check that no ref outside `refs/heads/` is left changed and that the tail's `state` symlink still resolves to the subscriber's `state` (the tick's own `assert_run_worktree_state_link`). Last, `declare -f pipeline_prepare_tail_rebase` must not contain `refs/stash`, `stash push`, `stash pop`, `stash drop`, `stash list` or `stash save`. Base: red, first at case 1 (`the operator's stash was popped or replaced (refs/stash none, ...)`); cases 3 and 5 are green on the base.
2. **Worker and verifier:** `scripts/pipeline-pair-smoke.sh` exits 0 (existing pair formation, ordered landing, overlap escalation and the card 113 frozen block). Base: green. Its pair formation passes the tick's network preflight, which resolves `api.anthropic.com` with `dig`; a sandboxed seat with no DNS runs it with a stub first on `PATH` (a `dig` script that prints `192.0.2.1`), since the preflight is not under test, and says so in its evidence. `scripts/tail-rebase-stash-smoke.sh` does not reach the preflight.
3. **Worker and verifier:** `scripts/landing-dispatch-smoke.sh` exits 0. Base: green.
4. **Verifier:** `bash -n scripts/tick.sh` passes and `shellcheck -S warning scripts/tick.sh` reports only the base's two warnings (SC2034 `unit` near line 652, SC2154 `autometta_vendor_stamp_name` near line 3211).
5. **Verifier:** the diff to `scripts/tick.sh` is confined to `pipeline_prepare_tail_rebase`, read from `git diff dev -- scripts/tick.sh`. In `docs/tick-loop.md` the paragraph no longer says the tail is "stashed, reset onto the new base", and by reading it states the three guarantees of Deliverable 2 (private save, commits rebased, failure restores the tail as the worker left it).

## Contract test

- **Test file:** scripts/tail-rebase-stash-smoke.sh
- **Assertions digest:** sha256:2df66db90c44910afd89d4cee74e7c67caa4fc7f7b6d78e1dbdf06a4bd40f302
- **Oracle proof:** red on `dev` at `8c2675d`, first at case 1: `the operator's stash was popped or replaced (refs/stash none, was <sha>)`. A diagnostic copy that does not stop at the first failure shows every intended defect on the base: the operator's stash popped and `op.txt` in the tail (case 1), the worker's commit dropped (cases 1, 2, 2b), the committed-only tail escalated with its commit gone (2b), the conflict case returning 0 as `tail-rebased` after dropping its commit (4), the failed pop leaving the tail's own entry on the operator's stash list (4b), and the function body naming `refs/stash`, `stash push` and `stash pop`; cases 3 and 5 pass on the base. A throwaway reference in a detached scratch worktree (record `HEAD`; `add -A` excluding `state`, `stash create`, `reset --hard HEAD`; `git rebase <base>`; `stash apply --index <sha>`; on failure `rebase --abort`, `reset --hard <recorded HEAD>`, re-apply, escalate) passed every assertion and left `pipeline-pair-smoke.sh` and `landing-dispatch-smoke.sh` green; it was removed and not committed. Traps for the worker: `git stash create` skips untracked files unless they are staged first; `git status` lists the run worktree's `state` symlink as untracked, so exclude `state` from every status, add and clean; `stash apply` of a `stash create` object needs the full sha, not `stash@{n}`.

## Out of scope

- The verified-branch landing rebase (`rebase_disjoint_run_branch`) and every other landing route.
- Forbidding or detecting worker self-commits; this card only stops the tail rebase from losing them.
- Any other finding in the review (verdict binding, budget reads, panel mode, process and lock handling are separate cards).
- Deploying the change. The live fleet tick runs the installed Homebrew keg, not this checkout; reinstalling the keg after this lands is a separate operator step.

## Budget

- **Worker wall-clock:** 30 minutes
- **Verifier wall-clock:** 25 minutes
- **Spend basis:** comparable to card 164 (about 0.7M tokens across both roles); one function and one paragraph. Preparation spent: about 20 minutes of orchestrator time and one 61k-token Codex cold read.

## Dispatch envelope

Return the standard envelope: status, the output of the worker's acceptance commands (criteria 1 to 3), the base results recorded above for comparison, and the list of changed files.

## Family-specific notes

None.

## Cold read

Read by GPT-6.1 Sol (Codex, read-only sandbox), 2026-11-15, against the first draft. Folded in:

1. Whether staged versus unstaged must be preserved: no, file contents only (Deliverable 1), because landing stages everything.
2. Merges, empty and already-upstream commits: git's default rebase behaviour is accepted (Deliverable 1).
3. A failed save must not reset anything: now explicit (Deliverable 1).
4. The card and its oracle are committed to `dev` before queueing, so the run worktree carries both.
5. `pipeline-pair-smoke.sh` needs DNS for the network preflight: criterion 2 now names the `dig` stub for a sandboxed seat.
6. `reset --hard` cannot exclude `state`: the constraint now names the pathspec commands, and the smoke asserts the symlink survives.
7. The re-apply failure path was untested: case 4b added. The save-failure path is not reproducible offline without breaking git itself; the verifier reads it (Deliverable 1).
8. Temporary refs and the "never read" constraint were unchecked: the smoke now asserts no ref outside `refs/heads/` is left changed and that the function body names no stash-list command.
9. The docs criterion only checked removal: criterion 5 now has the verifier read the paragraph for the three guarantees.
10. The envelope asked the worker for verifier-only output: now criteria 1 to 3.
