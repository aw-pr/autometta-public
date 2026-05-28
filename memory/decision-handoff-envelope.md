---
name: decision-handoff-envelope
description: Why workers write a JSON handoff envelope as their sole completion signal and why it is mandatory for new stages.
metadata:
  type: project
---

Worker handoff envelope is a JSON file at `state/handoffs/<stage-id>.json`, written by the worker as its final action. tick.sh polls for this file and treats it as the sole signal that worker work is done.

**Why JSON file rather than tool call or log pattern**
Tool calls are family-specific; log patterns are fragile. A file on disk is the only completion signal that works identically for Codex (`workspace-write` sandbox) and Claude (headless `claude -p`). It is atomic on POSIX and inspectable without re-running the worker.

**Why this is a worker contract, not a per-family extension**
The envelope shape is identical for both families. The dispatch contract already requires the worker to write its deliverables as files; adding one more file is a natural extension. No family-specific parse logic needed in tick.sh.

**Why the envelope is mandatory for new stages but legacy stages are grandfathered**
Retroactive enforcement would require re-running already-verified and committed stages, which violates the "git is the state store" principle and breaks the audit trail. Stages completed before stage 17 used process exit + log tail as the completion signal; those signals remain in tick.sh as fallback stuck-worker detectors (not success detectors) to handle edge cases during the transition window.

**Why:** Envelope pattern enforced in stage 17. Grandfathering keeps the loop stable during rollout.
**How to apply:** When reviewing or writing stage cards after stage 17, verify the card's deliverables section includes the envelope path and the worker prompt uses the updated template.
