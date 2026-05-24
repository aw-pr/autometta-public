---
name: decision-failure-budget-clock-tick
description: Timeouts come from a clock tick count, implemented per repo with filesystem state per the memory directive.
metadata:
  type: project
---

Timeouts come from a clock tick count, implemented per repo with filesystem state as per the memory directive.

**Why:** This resolves the failure-budget question in `docs/philosophy.md` about whether token limits should also include time-based limits.

**How to apply:** Keep per-repo filesystem state for clock-tick timeout counting, consistent with [[decision-loop-name-phat-controller]] and [[decision-single-tick-multi-repo-subscribe]].
