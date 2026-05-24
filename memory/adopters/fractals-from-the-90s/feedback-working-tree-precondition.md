---
name: feedback-working-tree-precondition
description: The "no files outside deliverables modified" acceptance criterion fires on any unrelated dirty tracked file in the working tree, not just files the worker touched. Clean the working tree before dispatching.
metadata:
  type: feedback
  run:
    repo: fractals-from-the-90s
    stage_id: 01-adoption-readme
    outcome: pass_after_rebrief
    category: card-flaw
    severity: medium
    worker_family: claude
    verifier_family: codex
    cost_extra: one-extra-verifier-run
    back_port_target:
      - templates/orchestrator-checklist.md
      - skills/autometta-setup/SKILL.md (Step 4 pre-flight)
    surfaced_on: 2026-05-22
---

The "no files outside the deliverables set are modified" criterion reads `git status` and treats any modification, tracked or otherwise, as a violation. On the first dispatch of stage card `01-adoption-readme` in fractals, the Codex verifier returned overall=FAIL on criterion 10 because of a pre-existing tracked `.DS_Store` modification that predated the worker run. The worker's deliverable was genuinely clean; the verifier's verdict was correct against the literal criterion text.

**Why:** The criterion is written for the worker, but `git status` reports the operator's full working tree state. Any drift before dispatch leaks into the verifier's view. The card's criterion has no way to distinguish "the worker touched this" from "the operator already had this dirty before the worker ran".

**How to apply:**

1. Before dispatching the worker, the orchestrator should run `git status -s` and resolve every unrelated modification: stash, revert, or commit on a different branch.
2. If a file is gitignored but still tracked (the `.DS_Store` case), either revert it for now or untrack it permanently with `git rm --cached <file>` and commit.
3. The card template's criterion-10 wording is fine as written; the fix is in the operator pre-flight, not the card.
4. If the false-positive lands anyway, `git checkout -- <file>` plus a verifier re-dispatch is the cheapest recovery (one verifier-budget of extra spend).

**Back-port targets:**

- `templates/orchestrator-checklist.md`: add a "pre-flight: confirm clean working tree" step before dispatch.
- `skills/autometta-setup/SKILL.md`: fold the same pre-flight into Step 4 of pass-1 adoption.

Cross-reference: [[feedback-acceptance-criterion-stage-card-exemption]] is the sibling lesson on the same criterion. Both are about the gap between literal-criterion-text and operator-intent.
