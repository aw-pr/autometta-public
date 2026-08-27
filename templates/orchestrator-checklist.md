<!--
Orchestrator pre-dispatch checklist, part of the dispatch-contract pattern library. Reusable in any repo. Do not add project-specific content here. Run through this checklist before dispatching any worker. -->

# Orchestrator pre-dispatch checklist

Run through every item below before dispatching a worker. A stage card that fails this checklist will likely produce a failed or incomplete stage, which costs more to recover than to prevent.

## 0. Worktree dispatch pre-flight

The shared checkout is never dispatched into and its dirtiness is never a
precondition. Every stage runs in its own ephemeral worktree, cut from the
card's declared base branch, so an unrelated dirty file (an uncommitted
HANDOFF.md, a stray `.DS_Store`) can no longer false-positive a stage or
block dispatch. See `memory/adopters/emergence-viewer/feedback-worktree-dispatch-thinned-preflight.md`
for the pilot this backports.

- [ ] The stage card declares `Base branch` and `Run branch` (`autometta/<stage-id>`) in its Metadata section. Pin both to branch names, never a commit SHA (no `expected_head`) — the run branch is cut from the base branch fresh at dispatch time, so a SHA pin is stale the moment the base moves.
- [ ] Remove any worktree or branch left standing by a prior attempt at this stage before cutting a new one:

  ```sh
  git worktree remove --force ../<repo>-run-<stage-id> 2>/dev/null || true
  git branch -D autometta/<stage-id> 2>/dev/null || true
  ```

- [ ] Cut the run worktree as a sibling of the repo, not a subdirectory, so `../sibling-repo`-style card inputs still resolve the same way they do from the main checkout:

  ```sh
  git worktree add ../<repo>-run-<stage-id> -b autometta/<stage-id> <base-branch>
  ```

- [ ] Dispatch the worker and verifier into that worktree. All work — reads, writes, the dirty tree the verifier evaluates — happens there. The main checkout is never modified by dispatch and its working-tree state is irrelevant to this stage.
- [ ] **Budget window auto-reset.** At the start of a run window, if `state/budget.json` is `halted` or any counter sits at its cap, reset the counters to zero (caps unchanged) and log the reset, rather than treating a stale halt from a prior window as terminal for this one. See `docs/plans/2026-08-01-control-plane-review.md` and the pilot note for the incident this fixes (a three-week-old tick-cap halt blocking every later window).
- [ ] **Codex seat probe.** Before a Codex dispatch, run one trivial `codex exec` ping. On failure, skip the Codex seat for this stage and substitute another worker/verifier family — never attempt an interactive login unattended.
- [ ] **On PASS:** fast-forward-merge the run branch into the base branch if the base hasn't moved since the worktree was cut. If the base has moved, push the run branch instead and note the unmerged branch in HANDOFF for manual integration.
- [ ] **On FAIL:** leave the run branch and worktree standing for operator inspection. Do not delete either; re-running the stage removes and recuts them (first checklist item above).
- [ ] If a gitignored file is still tracked in the shared checkout (the classic `.DS_Store` case), either revert it or untrack it permanently with `git rm --cached <file>` and commit — this is now a hygiene item, not a dispatch blocker.

## 1. Stage card completeness

- [ ] The stage card exists at the path you intend to give the worker.
- [ ] Every `<<placeholder>>` in the card has been filled in.
- [ ] The "Objective" section states the goal in one or two sentences without referencing artefacts that do not yet exist.
- [ ] The "Inputs" section lists only files that currently exist on disk.
- [ ] All input paths are relative to repo root. No absolute paths, no `/Users/...`, no `~`. Cards must remain portable across clones and machines.
- [ ] The "Deliverables" section lists specific file paths, not vague descriptions.
- [ ] Each deliverable has enough description that the worker could produce it without asking a follow-up question.
- [ ] Every file the implementation must plausibly touch is in the Deliverables list, not just Inputs. Walk the data path end to end (e.g. a new shader uniform needs the CPU-side struct and the per-frame population, not just the shader). A correct worker will refuse the stage rather than edit an input-only file, burning a dispatch on a card fix.
- [ ] The "Constraints" section lists hard rules the worker must not violate (language, naming, placeholder syntax, etc.).

## 2. Acceptance criteria

- [ ] Every acceptance criterion in the card is independently checkable by the verifier without human judgement.
- [ ] The criteria together cover every deliverable.
- [ ] At least one criterion is a machine-checkable structural test (file exists, no forbidden string, round-trip fidelity, etc.).
- [ ] The acceptance command (or set of checks) is stated or clearly implied, the verifier should not have to invent its own test surface.

## 3. Scope boundaries

- [ ] The "Out of scope" section names every file or deliverable the worker might plausibly touch but must not.
- [ ] The card does not ask the worker to read files beyond the "Inputs" list (keeping context lean is a constraint, not a suggestion).

## 4. Worker and verifier assignment

- [ ] The worker identity is named (agent family + tier).
- [ ] The verifier identity is named (agent family + tier).
- [ ] Worker and verifier are from different agent families, or there is an explicit rationale for why same-family verification is acceptable in this case.
- [ ] The pairing rationale in the card's "Metadata" section explains the choice.
- [ ] The sandbox role for the verifier is set correctly: verifier runs outside the worker's sandbox so it can observe side-effects the worker cannot fake.

## 5. Budget and timing

- [ ] A wall-clock budget is stated for the worker.
- [ ] A wall-clock budget is stated for the verifier.
- [ ] Both budgets are realistic given the scope of the deliverables.
- [ ] The card instructs the worker to surface a partial result and stop if it cannot complete within budget.

## 6. Headless gotchas (checklist before any headless dispatch)

- [ ] **stdin redirect:** if the worker is a non-interactive CLI invocation, stdin is redirected from `/dev/null`. A worker waiting for stdin input will hang silently until the wall-clock budget expires.
- [ ] **Card-sync race:** the stage card is committed (or at minimum flushed to disk) before the worker is dispatched. If the worker and verifier run from different git worktrees, both must see the same card content. Serialise writes before dispatch.
- [ ] **Log path:** the worker's log path is predictable and stated in the card or the worker prompt. Do not rely on harness-generated task IDs that change between runs.
- [ ] **Sandbox boundary:** verify that the verifier's environment is genuinely outside the worker's sandbox. A verifier that runs inside the same sandbox cannot observe side-effects the worker was prevented from making.
- [ ] **Prior-gate regression:** if acceptance criteria overlap with those of an earlier stage, running the verifier for this stage may surface a regression in that earlier stage. Note any such overlap and decide in advance whether a regression here is a blocker.
- [ ] **No artefacts outside the repo:** every file a headless run must read exists inside the repo (or the run home) before dispatch. Copy external inputs in at scheduling time, while an interactive session still holds the macOS privacy (TCC) grants — a launchd-spawned agent reading Desktop/Documents/Downloads or CloudStorage paths raises a consent dialog nobody can click and blocks silently until the next interactive wake. If copying in is genuinely inappropriate, flag the external dependency on the card/brief at creation and pre-test read access from a non-interactive context.
- [ ] **Headless orchestrators block on child dispatches:** a `claude -p` orchestrator exits the moment its final turn ends, and its exit kills any background children it spawned. Inside a headless orchestrator, worker and verifier dispatches must run as foreground (blocking) commands; "dispatch in background, reap next turn" is only valid in interactive sessions that outlive the child.

## 7. Integration plan

- [ ] You know where the worker's output will land after the verifier passes (which branch, which commit, which merge step).
- [ ] The commit attribution is clear: committer is the human user; author is the agent identity string of the primary agent.
- [ ] If a co-author trailer is needed (two agents contributed), it is planned.

## 8. Commit responsibility (orchestrator-commits-on-verifier-pass)

The worker does not commit. The orchestrator commits the worker's working-tree changes only after the verifier artefact reports `overall: PASS`. On `overall: FAIL` (or a missing / malformed `overall` field, which is treated as FAIL) the orchestrator does NOT commit; the stage is marked `verifier_failed` and surfaced for operator review.

- [ ] The worker prompt instructs the worker not to run `git commit`. The working tree is the deliverable.
- [ ] On `overall: PASS`, the orchestrator stages non-state changes and commits with:

  ```sh
  git commit \
    --author="<worker-identity>" \
    -m "<stage-id>: <one-line summary>" \
    -m "Co-Authored-By: <verifier-identity>"
  ```

  The `<worker-identity>` and `<verifier-identity>` strings come from the stage's `worker` and `verifier` fields in `state/state.yaml`. The summary line comes from the verifier artefact's `headline` field if present, otherwise from the stage card's `# Stage card ... :` title line.

- [ ] On `overall: FAIL` (or missing / malformed), do NOT commit. Set `stage.status = "verifier_failed"`, clear `current_stage`, and leave the dirty working tree intact for operator inspection.
- [ ] Backward-compat fallback: if the working tree is clean on a PASS artefact (a worker on an older prompt self-committed), log "no diff to commit, presumably worker self-committed (deprecated path)" and mark the stage `completed` without erroring.

## Family-specific notes

<!--
Add any family-specific pre-dispatch steps here (e.g. confirming an OAuth session is active, confirming sandbox mode flags, etc.). Leave as "None" if no family-specific steps apply to this dispatch. -->

<<family-specific-notes-or-none>>
