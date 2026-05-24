---
name: feedback-tick-switches-working-dir-branch
description: scripts/tick.sh switches the working-tree branch to phat-controller/state without restoring it on exit. Fine under cron, footgun under interactive invocation.
metadata:
  type: feedback
---

`scripts/tick.sh::commit_state_branch` runs `git checkout -B phat-controller/state` inside the subscribed repo's working tree. The function commits state, but never switches the branch back. The next shell command in the calling terminal finds itself on `phat-controller/state` rather than wherever the operator was before.

Under cron, the tick runs in its own subprocess with no human-facing shell, so this is invisible and harmless. Under interactive invocation (operator firing `tick.sh` from a terminal for testing or debugging, or any future TUI), the branch silently changes underneath the operator. Next git command surprises.

**Why:** Surfaced during the stage-6 dry run while firing tick.sh manually to validate the loop end-to-end. The operator (orchestrator session) ran `scripts/tick.sh` once, then `git status` showed the branch had changed to `phat-controller/state`. No data was lost; the discovery was non-destructive, but a future operator without the context could push a state-branch commit to the wrong remote, or accumulate unrelated work on the state branch by accident.

**How to apply:** Two reasonable fixes:

1. `commit_state_branch` records the original branch via `git rev-parse --abbrev-ref HEAD` before checkout, and restores it (via a trap or explicit checkout) before returning. Pros: transparent to interactive callers. Cons: a worker dispatched later in the same tick run from the wrong branch is wrong; the restore would mask that.

2. The tick performs all state-branch work via a temporary worktree (`git worktree add /tmp/phat-state-<repo-slug> phat-controller/state`) that lives outside the main working tree. The operator's branch is untouched. Pros: full isolation, matches the `state-branch-as-separate-write-domain` design intent. Cons: one more directory to manage; worktree cleanup on stall.

Option 2 is more invasive but cleaner. Option 1 is a one-liner.

Cross-reference: [[feedback-stage-6-runtime-bugs]], [[decision-tick-implementation-parameters]].
