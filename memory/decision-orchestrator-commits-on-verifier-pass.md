---
name: decision-orchestrator-commits-on-verifier-pass
description: The orchestrator (not the worker) commits the worker's working-tree changes, and only after the verifier artefact reports overall=PASS. On FAIL the working tree is left intact and the stage moves to verifier_failed for operator review.
metadata:
  type: decision
---

The worker leaves a dirty working tree as its deliverable. The verifier reads that dirty tree, writes a JSON artefact under `state/verifiers/<stage-id>.json`, and exits. The orchestrator (`scripts/tick.sh`) reads `jq -r '.overall'` from the artefact and decides:

- `overall: PASS` — orchestrator stages the non-state working-tree changes and commits with `--author=<worker-identity>` plus a `Co-Authored-By: <verifier-identity>` trailer drawn from `state/state.yaml`. Commit subject: `<stage-id>: <headline>`. Stage status moves to `completed`; the commit SHA is recorded back into `stages[].commit`.
- `overall: FAIL` (or missing / malformed, treated as FAIL by the fail-safe path) — no commit. Stage status moves to the new `verifier_failed` enum value, `current_stage` is cleared, and the dirty tree is left intact for the operator to inspect.
- Clean working tree on a PASS artefact — backward-compat path for adopters whose workers still self-commit. Log a deprecated-path warning and mark the stage `completed` without erroring.

**Why:** Adopters running the dispatch loop end-to-end (`emergence-lab` was the first) observed three failure modes of worker self-commits:

1. The worker commit lands before the verifier has reported a verdict. The verifier identity is therefore unknown at commit time, and the `Co-Authored-By` trailer that records cross-family verification (the load-bearing belief recorded in `project-cross-family-verification-validated.md`) is missing on every worker-authored commit.
2. A worker that self-committed a failing diff cannot be cleanly rejected. The operator has to `git revert` after the fact, which churns history and decouples the rejection from the verifier verdict.
3. The dispatch contract's "cross-family verification is the default" claim becomes invisible in `git log`. The verdict only lives in `state/state.yaml` and the verifier artefact JSON, which most downstream readers (and most future humans inspecting the repo) will not discover.

Concentrating the commit at the one point where the verifier verdict is known fixes all three: the cross-family co-author trailer appears on every accepted commit; rejection is a state transition (`verifier_failed`) rather than a history rewrite; and `git log` carries the verification audit trail.

**Rejected alternatives:**

- *Worker amends.* The worker commits a placeholder, the orchestrator amends it on PASS to add the verifier as co-author. Rejected because amend requires the orchestrator to rewrite a commit the worker authored, which conflicts with the per-agent author attribution rule (`~/.claude/rules/mcp-hub-dev-rules.md`) and creates a moment where the commit message claims a verifier identity that has not yet been computed. It also breaks the FAIL path: amending a failing commit to record FAIL is worse than never committing it.
- *Two-commit pattern.* The worker commits its diff under its own identity; the orchestrator then commits an empty "verifier accepted" marker commit. Rejected because it doubles the commit count per stage, leaves a failing worker commit in history when the verifier reports FAIL (the same revert problem as the status quo), and dilutes the audit trail (`git log --author` for a worker now shows commits the verifier never accepted).
- *Verifier commits.* The verifier commits the worker's diff on PASS. Rejected because the verifier sandbox is read-only by design (`docs/dispatch-contract.md` § Sandbox-as-role-boundary). A verifier with commit rights is a verifier that can hallucinate green and ship it; the sandbox boundary is load-bearing.

**How to apply:**

- Worker prompt: explicit "do not run `git commit`" instruction.
- Verifier prompt: clarify the verifier reads the dirty tree and writes only the artefact; `overall` drives the orchestrator's commit decision.
- Orchestrator checklist: section 8 records the canonical `--author=<worker>` + `Co-Authored-By: <verifier>` invocation, the FAIL path, and the backward-compat clean-tree fallback.
- `scripts/tick.sh`: `_process_verifier_artefact` branches on `overall` and either commits-on-PASS or marks `verifier_failed`. Missing / malformed `overall` is fail-safe FAIL.
- `schemas/state.yaml.json`: `verifier_failed` added to the `stage.status` enum.

Cross-reference: [[project-cross-family-verification-validated]], [[feedback-stage-6-runtime-bugs]].
