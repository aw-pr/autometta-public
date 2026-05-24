---
name: decision-single-tick-multi-repo-subscribe
description: Repos use one cron tick and subscribe to it, potentially by publishing a call into phat-controller.
metadata:
  type: project
---

Repos use a single cron tick and subscribe to it, potentially by publishing a call into `phat-controller`.

**Why:** This resolves the single-tenant versus multi-project question in `docs/philosophy.md`.

**How to apply:** Design pass-2 scheduling around one shared tick model for participating repos, aligned with [[decision-loop-name-phat-controller]].
