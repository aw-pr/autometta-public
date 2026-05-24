---
name: feedback-subagent-budget-enforcement
description: Wall-clock budgets stated in a sub-agent brief are advisory, not enforced. Tighten scope per worker rather than trusting the budget.
metadata:
  type: feedback
---

Wall-clock budgets in a sub-agent brief (e.g. "Report back within 6 minutes") are advisory. The harness does not kill the sub-agent at the stated budget. A worker can and will continue past it, and the orchestrator only finds out when the call returns or errors.

**Why:** Stage 0 worker (Sonnet via Task tool) was briefed for 6 minutes, ran 20 minutes (3.3x budget), and only stopped because of a connection error after 10 tool uses. The orchestrator waited blindly.

**How to apply:** Do not rely on budget statements alone for sub-agents. Prefer narrower scope per dispatch so even an unbounded sub-agent completes quickly. For bash sub-processes (codex exec, gemini, gh), use the Bash tool's `timeout` parameter plus a `timeout Ns ...` wrapper, per the [[agent-orchestrator]] skill's Step 4a. For Task/Agent sub-agents, keep deliverable count low (1-2 files) and inputs bounded.

Cross-reference: [[project-stage-0-self-host-run]].
