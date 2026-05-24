<!--
Orchestrator pre-dispatch checklist, part of the dispatch-contract pattern library. Reusable in any repo. Do not add project-specific content here. Run through this checklist before dispatching any worker. -->

# Orchestrator pre-dispatch checklist

Run through every item below before dispatching a worker. A stage card that fails this checklist will likely produce a failed or incomplete stage, which costs more to recover than to prevent.

## 0. Working-tree pre-flight

- [ ] `git status -s` shows no unrelated modifications. Acceptance criteria of the form "no files outside the deliverables set are modified" treat the operator's full working tree as the worker's; any pre-existing dirty file will surface as a false-positive FAIL. Stash, revert, or commit on a different branch before dispatch.
- [ ] If a gitignored file is still tracked (the classic `.DS_Store` case), either revert it or untrack it permanently with `git rm --cached <file>` and commit.

## 1. Stage card completeness

- [ ] The stage card exists at the path you intend to give the worker.
- [ ] Every `<<placeholder>>` in the card has been filled in.
- [ ] The "Objective" section states the goal in one or two sentences without referencing artefacts that do not yet exist.
- [ ] The "Inputs" section lists only files that currently exist on disk.
- [ ] All input paths are relative to repo root. No absolute paths, no `/Users/...`, no `~`. Cards must remain portable across clones and machines.
- [ ] The "Deliverables" section lists specific file paths, not vague descriptions.
- [ ] Each deliverable has enough description that the worker could produce it without asking a follow-up question.
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

## 7. Integration plan

- [ ] You know where the worker's output will land after the verifier passes (which branch, which commit, which merge step).
- [ ] The commit attribution is clear: committer is the human user; author is the agent identity string of the primary agent.
- [ ] If a co-author trailer is needed (two agents contributed), it is planned.

## Family-specific notes

<!--
Add any family-specific pre-dispatch steps here (e.g. confirming an OAuth session is active, confirming sandbox mode flags, etc.). Leave as "None" if no family-specific steps apply to this dispatch. -->

<<family-specific-notes-or-none>>
