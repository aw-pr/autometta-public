---
name: worker-sdk-experiment
description: Decision record for the bounded Claude Agent SDK worker experiment.
metadata:
  type: decision
---

# Worker SDK experiment decision

**Why:** Workers need a reliable role boundary and recovery path. This
experiment tested whether a Claude Agent SDK worker could keep those properties
while providing live per-message usage and structured handoffs.

**Decision:** Workers stay CLI. With `CLAUDE_CONFIG_DIR` contained in the
worker's throwaway worktree, the SDK stopped at `Not logged in` before its
first tool call. Copying credentials or opening the scope would compromise the
boundary being tested. The experiment therefore did not establish the scoped
refusal, handoff or live-usage path, and it does not provide the CLI worker's
established heartbeat or recovery behaviour.

**How to apply:** Link future SDK-worker proposals to
[[decision-per-role-family-sdk-transport]] and this experiment. Require the
existing `op-fetch` subscription route to authenticate a worktree-local Claude
session, plus independently enforced worker boundary, observability and
recovery evidence, before reopening the decision.

See [[worker-sdk-postmortem]].
