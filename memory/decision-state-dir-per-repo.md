---
name: decision-state-dir-per-repo
description: phat-controller stores all per-repo state in a single state/ directory at the repo root containing state.yaml, budget.json, and verifiers/<stage-id>.json.
metadata:
  type: project
---

phat-controller stores all per-repo state in a single `state/` directory at the repo root. It contains `state.yaml`, `budget.json`, and a `verifiers/` subdirectory holding `<stage-id>.json` files per the verifier-handoff naming convention.

**Why:** The single-tick multi-repo subscribe model ([[decision-single-tick-multi-repo-subscribe]]) requires each repo's state to be self-contained and discoverable from the repo root. A flat `state.yaml` at the repo root would conflict with the verifier artefacts; sibling files at the repo root would clutter. One directory groups them and keeps git diffs scoped. The directory name `state/` was chosen over `.phat/` or `phat-state/` because state is the dominant concept, not the controller.

**How to apply:** When stage 5 writes `scripts/tick.sh`, all file-path constants are relative to the repo root: `state/state.yaml`, `state/budget.json`, `state/verifiers/<stage-id>.json`, `state/logs/<stage-id>-<role>.log`. New repos subscribing to a phat-controller create the `state/` directory on first tick. The `state/` directory is gitignored only at the `logs/` level; the rest is tracked so the audit trail lives in git.

Cross-reference: [[decision-loop-name-phat-controller]], [[decision-single-tick-multi-repo-subscribe]], [[decision-verifier-handoff-naming]], [[decision-failure-budget-clock-tick]].
