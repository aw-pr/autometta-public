---
name: feedback-acceptance-criterion-stage-card-exemption
description: Acceptance criteria that check "no files outside deliverables dir" must explicitly exempt the stage card itself, or the verifier will FAIL the stage on a contract-mandated artefact.
metadata:
  type: feedback
---

When an acceptance criterion checks "no files outside the deliverables directory are modified", it must explicitly exempt the stage card path in `examples/self-host/<NN>-*.md`. The stage card is authored by the orchestrator, not the worker, and is committed alongside the deliverables as the audit trail per `docs/dispatch-contract.md#step-7-commit`. A verifier checking `git status` will see the card as an untracked outsider and FAIL the criterion, even though the worker's scope is clean.

**Why:** Stage 2 verifier (Codex GPT-5.3) correctly flagged criterion 7 FAIL because the stage card sat outside `examples/fractals-stage-cards/`. The criterion as worded was the defect, not the worker's output. The orchestrator overrode the verdict under contract step 6 (orchestrator integration) and amended the criterion text to exempt the stage card path. Re-verification was skipped because the override was deterministic and the diff well understood.

**How to apply:** From stage 3 onwards, every acceptance criterion that references "files outside the deliverables directory" must add the clause: "The stage card at `examples/self-host/<NN>-*.md` is authored by the orchestrator and exempt." Better: a small reusable phrase in the stage-card template's constraints section would prevent the recurrence. Consider amending `templates/stage-card.md` to include this exemption as a standard footnote, or fold it into a single criterion convention.

Cross-reference: [[project-stage-0-self-host-run]], [[feedback-style-constraints-pre-check]].
