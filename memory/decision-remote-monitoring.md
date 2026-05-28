---
name: decision-remote-monitoring
description: Why hosted scheduled agents file PRs only (no dispatch authority), and why three separate routines for v1 monitoring surfaces.
metadata:
  type: project
---

The autometta loop is local-machine. It cannot observe whether the public mirror has drifted, whether `brew install` from a fresh machine still works, or whether upstream skills (agent-orchestrator) have moved incompatibly. Hosted scheduled agents (Claude Code `/schedule` routines) fill this gap cheaply without creating a second control plane.

**Why hosted (not local cron):** The local LaunchAgent only runs when the machine is awake and the user is active. A hosted routine runs on a predictable cadence regardless of machine state, which is exactly what mirror and install health checks need.

**Why PR-only (no dispatch authority):** Monitoring agents have no credentials for `op`, `op-fetch`, or 1Password. They cannot read `state.yaml` safely (no write lock) and must not advance the loop. The operator decides what to do with a finding; the loop does not. This constraint is structural, not just policy.

**Why three routines for v1:** Each of the three surfaces fails independently and at different rates. A single combined check would obscure which surface is failing and would need different cadences (mirror: 6h; brew: daily; skills: weekly). Three routines also means one stale routine does not block the others.

**Linked decisions:** [[decision-handoff-envelope]] (the loop's completion signal pattern — monitoring sits outside this envelope, which is why it can be read-only).
