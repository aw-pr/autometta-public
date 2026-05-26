---
name: decision-audit-card-budgets-shorter
description: Audit-only stage cards (no code modifications, only written deliverables) should set Worker wall-clock to 20–30 minutes, not 60. Observed during emergence-lab adoption where the GPU-acceleration audit card budgeted 60 min and finished well under.
metadata:
  type: decision
  run:
    adopter: emergence-lab
    stage_examples:
      - 06-gpu-acceleration-audit
      - 05a-phat-controller-hardening
    raised_by: orchestrator
    back_port: stage-card-template
---

For stage cards whose only deliverable is a written audit, comparison
document, or analysis report (no code changes, no test changes), set
the Worker wall-clock budget in the 20–30 minute band, not 60.

**Why:** The `worker_budget_seconds_from_card` parser uses the budget
to compute the stall threshold (`budget + 50% grace`). A 60-minute
budget tolerates a 90-minute stall before the tick state machine
kills the worker and records a failure. That window is overly generous
for what is effectively a read-and-write task and slows down failure
detection when an audit worker silently hangs (no diff to inspect).
A 25-minute budget gives a 37.5-minute stall threshold, which is the
right zone for an audit worker doing a moderate codebase trawl.

Observed runtime in `emergence-lab` for the
`06-gpu-acceleration-audit` card: the worker produced the deliverable
file `docs/audits/gpu-acceleration-audit.md` well within 30 minutes;
the 60-minute budget had no effective use.

**How to apply:**

- Code-change cards (kernel edits, renderer edits, refactors): keep
  the 45–90 minute band depending on diff size.
- Audit / report / written-deliverable cards: 20–30 minutes.
- Hybrid cards (small code + written report): 30–45 minutes.
- Reserve the 60+ minute band for cards with multiple genuinely
  parallelisable subtasks or new external dependencies.

**What this is NOT:** a per-card hard limit. The budget is a stall
detector, not a productivity target. Workers that finish in under
budget cause no harm; budgets that are wildly larger than reality
cause harm by hiding real stalls.

Cross-reference:
[[feedback-acceptance-criterion-stage-card-exemption]],
[[adopters/emergence-lab/feedback-card-input-vs-deliverable-when-userintent-needs-both]].
