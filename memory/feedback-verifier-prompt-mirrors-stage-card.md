---
name: feedback-verifier-prompt-mirrors-stage-card
description: The verifier prompt's deliverables list must mirror the stage card's exactly, including any open-ended clauses like "new decision files banked under the anchored-decisions rule". Hard-coding a fixed file list in the verifier prompt produces false-negative criterion failures when a re-brief adds files.
metadata:
  type: feedback
---

When dispatching the verifier, the prompt that names the expected deliverables must reflect the stage card's full permission set, not a snapshot of the file list at prompt-authoring time. Stage cards frequently include clauses like "any new `memory/decision-*.md` file banked under the anchored-decisions rule is part of the deliverables set" or "the orchestrator-authored stage card is exempt". A verifier prompt that hard-codes only the initial file list will FAIL criteria on artefacts the stage card explicitly permits.

**Why:** Stage 4 verifier flipped from FAIL to FAIL to PASS across three runs. The first FAIL was a real worker defect (unanchored decisions); the re-brief banked them as a third memory entry. The second FAIL was a verifier-prompt-side defect: the prompt's "DELIVERABLES PRODUCED BY WORKER" list named only two new memory entries, so the verifier correctly flagged the third as "outside declared deliverables", even though the stage card explicitly permits it. Orchestrator override would have worked but a corrected verifier prompt was cleaner and produced an unambiguous PASS.

**How to apply:** When authoring the verifier prompt, copy the stage card's "Out of scope" and "Acceptance criteria" sections verbatim rather than enumerating files. Where files must be enumerated, also enumerate the rule that permits new files. Better: derive the file list at dispatch time from `git status --porcelain` plus the stage card's deliverables section, rather than freezing it at prompt authoring.

Cross-reference: [[feedback-acceptance-criterion-stage-card-exemption]], [[feedback-style-constraints-pre-check]].
