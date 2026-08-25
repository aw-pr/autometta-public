# Stage card 07-orchestrator-commits-not-workers: Move commit responsibility from worker to orchestrator-on-pass

## Metadata

- **Authored:** 2026-05-26
- **Orchestrator:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Worker:** Codex GPT-5.3 <codex-gpt-5-3@local>
- **Verifier:** Claude Sonnet 4.6 <claude-sonnet-4-6@local>
- **Pairing rationale:** Cross-family per `memory/project-cross-family-verification-validated.md`. Touches templates, tick.sh, and the dispatch contract doc — Claude verifier confirms the documented protocol matches the implemented behaviour end-to-end.

## Objective

Stop workers self-committing. After a worker phase, the working tree is left dirty; the verifier runs against that dirty tree; on PASS, `tick.sh` commits the working-tree changes with `--author=<worker-identity>` and a `Co-Authored-By: <verifier-identity>` trailer. On FAIL the changes are NOT committed; the operator decides whether to amend the stage card and re-run, or revert.

**Why this matters.** Adopters running the dispatch loop end-to-end (currently `emergence-lab` is the first real one) observed:

- Worker self-commits land before the verifier runs. The verifier identity is therefore unknown at commit time, and the `Co-Authored-By` trailer that should record cross-family verification is missing on every worker-authored commit.
- A worker that self-commits a failing diff cannot be cleanly rejected; the operator must `git revert` after the fact.
- The dispatch contract's "cross-family verification is the default" claim becomes invisible in `git log` history — it only lives in `state/state.yaml` and the verifier artefact JSON, which most readers will not discover.

The fix preserves the worker's freedom to use the working tree however it likes during its phase (test, iterate, scratch files) and concentrates the commit decision at the one place where the verifier verdict is known.

## Inputs (read these in your own context)

- `templates/worker-prompt.md`
- `templates/verifier-prompt.md`
- `templates/orchestrator-checklist.md`
- `scripts/tick.sh` (the artefact-found branch in `_process_repo_locked`)
- `scripts/spawn-worker.sh`
- `scripts/spawn-verifier.sh`
- `docs/dispatch-contract.md`
- `docs/verification.md`
- `memory/project-cross-family-verification-validated.md`

Do not read anything else unless you need to.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. `templates/worker-prompt.md` — explicit "do not run `git commit`" instruction. State that the working tree is the deliverable; the orchestrator will commit on verifier-pass.
2. `templates/verifier-prompt.md` — clarify that the verifier reads the dirty working tree (not a committed snapshot) and writes its artefact to `state/verifiers/<stage-id>.json`. The verdict field (`overall: PASS | FAIL`) drives the orchestrator's commit decision.
3. `templates/orchestrator-checklist.md` — add the on-pass commit step with the canonical author + co-author trailer pattern. Explicit fallback for FAIL: do not commit; operator review.
4. `scripts/tick.sh` — in the artefact-found branch of `_process_repo_locked`:
   - Read the artefact JSON; extract `overall` (PASS / FAIL).
   - If PASS: stage all non-state working-tree changes, commit with `--author="<worker_identity>"` and a `Co-Authored-By: <verifier_identity>` trailer derived from `state.yaml`. Commit message format: `<stage-id>: <one-line summary>` (the summary may come from the artefact's `headline` field if present, otherwise the stage card's title).
   - If FAIL: do not commit working-tree changes. Set `stage.status` to `verifier_failed` (new status) instead of `completed`, log the failure, and clear `current_stage` so the operator can inspect.
   - Existing state-branch commit (`commit_state_branch`) continues unchanged.
5. `docs/dispatch-contract.md` — document the new model in the lifecycle section.
6. `docs/verification.md` — update to describe the PASS-commits / FAIL-no-commit branching.
7. `memory/decision-orchestrator-commits-on-verifier-pass.md` — new decision memory recording the rationale and the rejected alternatives (worker amends, two-commit pattern).

## Constraints

- The new behaviour must coexist with adopters that have not yet updated their workers to the new prompt (graceful degradation): if `tick.sh` sees a clean working tree on a PASS artefact, log "no diff to commit, presumably worker self-committed (deprecated path)" and proceed to mark completed without erroring.
- No changes to the `SimKernel`-style contracts in any adopter. This is purely autometta-internal.
- `state/state.yaml` schema: `verifier_failed` is a new permitted value for `stage.status`. Update any schema validation in `tick.sh` or `add-stage.sh` if present.
- `npm run verify` (in adopter repos) is unaffected — they don't depend on autometta scripts.
- All shell scripts must pass `bash -n` syntax check.
- The artefact JSON's `overall` field is treated as the source of truth. If `overall` is missing or malformed, treat the artefact as FAIL (fail-safe).
- No absolute paths in committed content. No secrets.
- Atomic commits per `~/.claude/rules/mcp-hub-dev-rules.md`. Author identity tracks the agent that primary-authored the diff. Committer is the human user.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. `bash -n scripts/tick.sh && bash -n scripts/spawn-worker.sh && bash -n scripts/spawn-verifier.sh` passes.
2. `templates/worker-prompt.md` contains an explicit "do not run `git commit`" or equivalent instruction (greppable).
3. `templates/orchestrator-checklist.md` contains the canonical commit-on-pass invocation with `--author="<worker>"` and `Co-Authored-By: <verifier>` (literal strings or placeholder marks).
4. `scripts/tick.sh` has a code path that branches on `jq -r '.overall'` from the artefact JSON and performs the commit-on-pass / no-commit-on-fail logic.
5. The commit message format for orchestrator-committed worker output starts with the stage id (verifiable with a unit-style check or by code reading).
6. `docs/dispatch-contract.md` describes the new commit-responsibility model in its lifecycle section.
7. A new memory file at `memory/decision-orchestrator-commits-on-verifier-pass.md` exists with the canonical frontmatter (`name`, `description`, `metadata.type: decision`).
8. Backward-compat path: when working tree is clean and artefact is PASS, the tick logs the deprecated-path warning and still marks the stage `completed`.
9. The artefact-FAIL path sets `stage.status` to `verifier_failed` and does NOT mutate the working tree.
10. No files outside the deliverables set are modified — except this stage card itself, which is exempt per `memory/feedback-acceptance-criterion-stage-card-exemption.md`.
11. The publish-guard pre-push hook continues to pass on the resulting branch.

## Out of scope

- Multi-author trailers when the worker phase itself involved more than one agent (e.g. a Codex worker handing off to a Claude worker mid-phase). Single-author worker commits only.
- A retroactive cleanup of historical worker-self-commits in adopter repos. The change is forward-looking.
- Changes to verifier-attempt cap, stall thresholds, or budget accounting.
- Any change to the `add-stage` validator or stage-id regex.
- Adopter-side changes (`emergence-lab` etc.) — those are downstream tasks once this lands.

## Budget

- **Worker wall-clock:** 90 minutes
- **Verifier wall-clock:** 30 minutes

## Verifier handoff

Worker returns:

- List of modified files (`git diff --name-only HEAD~`).
- A short note on the commit-message format chosen and where it is documented.
- Confirmation that `bash -n` is green on all touched scripts.
- Confirmation that the backward-compat path was implemented.
- The new `state.status` enum values now permitted.

## Family-specific notes

- Codex worker: headless dispatch must redirect stdin from `</dev/null` per `memory/feedback-stage-6-runtime-bugs.md`. The worker should NOT run `git commit` at any point in its workflow; verify against the new worker-prompt instruction.
- Claude verifier: cross-family pairing per `memory/project-cross-family-verification-validated.md`. The verifier writes its artefact and exits; commit decision is the orchestrator's, not the verifier's.
