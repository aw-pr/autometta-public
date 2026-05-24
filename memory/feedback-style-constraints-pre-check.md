---
name: feedback-style-constraints-pre-check
description: Style constraints (em dashes, AI-tell words) need a pre-verifier check, not just verifier catch. Writer is blind to its own dashes.
metadata:
  type: feedback
---

A worker writing prose under "no em dashes" and "no AI-tell vocabulary" will produce both anyway, because the rule does not fire during generation. The cross-family verifier catches it after the fact, but that costs a full re-brief cycle.

**Why:** Stage 0 worker (Claude Sonnet) emitted 18 em dashes in `docs/dispatch-contract.md` and a further 12 across the three templates, despite the constraint being stated explicitly in the stage card. The orchestrator (Claude Opus) also wrote em dashes when filling in the missing dispatch-contract.md directly. Both same-family agents were blind to their own usage. Codex (cross-family) flagged every one.

**How to apply:** Add a deterministic style scan to the orchestrator flow before handing off to the verifier. A single `grep -n '-'` and a banned-word regex catches every instance and lets the worker (or orchestrator) fix in-place without spending a verifier round-trip. The post-hoc verifier still runs as the structural check; the pre-check removes the most predictable failure class from the verifier's budget.

Cross-reference: [[project-stage-0-self-host-run]], [[feedback-subagent-budget-enforcement]].
