---
name: decision-tick-implementation-parameters
description: Default implementation parameters fixed by the phat-controller design that are not yet code: branch name, repair entry point, per-fire cap location, stall grace factor.
metadata:
  type: project
---

The phat-controller design (`docs/phat-controller.md`) fixes four implementation parameters that are decisions in their own right. They are banked here rather than scattered through the design doc so stage 5 has a single reference when implementing `scripts/tick.sh`.

1. **Working branch name: `phat-controller/state`.** The tick commits state updates on a branch named `phat-controller/state`, not on `dev` or `main`. Reason: state writes interleave poorly with human commits on the working branch and the audit trail is easier to follow when controller commits live on their own branch.

2. **Repair entry point: `tick.sh --repair`.** When a human edits `state.yaml` directly (against the design's "humans should not edit" rule), the next normal tick may produce inconsistent counts. The repair entry point reconciles `tick_count`, `last_tick_at`, and any orphan `state/verifiers/` files without dispatching new work. Implementation deferred to stage 5; the entry point is the commitment.

3. **Per-fire iteration cap location: `~/.phat-controller/config.yaml`.** A single controller-level config file holds top-level settings, beginning with `max_per_fire`. The file lives in the singleton home dir alongside `subscribers/`. Schema for this file is deferred to stage 5; the location and the existence of the file are the commitments.

4. **Stall grace factor: 1.5x default.** When deciding whether a worker or verifier process is stalled, the tick allows 1.5x the wall-clock budget stated in the stage card before declaring stall. Adjustable per-stage; default is 1.5x. Reason: budgets are estimates; a hard kill at exactly 1.0x produces too many false stalls.

**Why:** The stage-4 verifier flagged these four as unanchored decisions. They were embedded in the design prose without explicit banking, which violates the anchored-decisions criterion (the design doc claimed every decision was either anchored or in "new decisions", and these four were neither). Banking them here pulls them into the audit trail.

**How to apply:** Stage 5 reads this entry alongside `docs/phat-controller.md`. When implementing `scripts/tick.sh`, the four parameters are the defaults; any deviation must be flagged in the stage-5 deliverables and banked as a further decision.

Cross-reference: [[decision-loop-name-phat-controller]], [[decision-state-dir-per-repo]], [[decision-phat-controller-no-daemon-subscriber-registry]], [[decision-failure-budget-clock-tick]].
