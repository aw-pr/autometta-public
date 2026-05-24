---
name: decision-identity-via-orchestrator-skill
description: Agent identity drift across model families is managed through the agent-orchestrator skill and family equivalents.
metadata:
  type: project
---

Identity drift is handled through the `agent-orchestrator` skill to maintain agents and their equivalents in model families.

**Why:** This resolves the question in `docs/philosophy.md` about pinning or floating model identity in stage cards in flight.

**How to apply:** Use the `agent-orchestrator` skill as the reference point when mapping or maintaining equivalent agents across families during dispatch planning.
