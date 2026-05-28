---
name: decision-sweep-stage
description: Sweep stage design decisions: opt-in, synthesis as worker, worktrees not branches, output is docs/decisions/
metadata:
  type: project
---

Sweep stage is the design for exploring multiple approaches to a single problem before committing. The decisions below are load-bearing; changing them needs a conversation.

**Why opt-in, not default**

Sweep stages cost N+2 LLM calls and leave N scratch worktrees on disk. Applying them by default would make every stage expensive and messy. The card author opts in with `Sweep: true` precisely when the upstream uncertainty justifies the cost.

**Why synthesis is a worker, not in-process aggregation**

In-process aggregation (bash + jq reading N worktrees) can select the best approach but cannot synthesise across proposals. A synthesis agent reading all N outputs can produce a genuine decision: adopt X from approach-0, borrow Y from approach-2, discard approach-1. This requires an LLM call and follows the same dispatch contract as any other worker.

**Why worktrees, not branches in the main checkout**

A branch in the main checkout requires `git checkout` to switch context, which disturbs the working tree. Worktrees give each approach its own filesystem path without moving the HEAD of the main checkout. The sandbox-as-role-boundary belief holds: each worker sees only its own worktree.

**Why the synthesis output is docs/decisions/, not a code commit**

The sweep stage's value is the decision, not the code. If code from one of the approaches is worth adopting, a follow-up implementation card cherry-picks it. Combining decision and implementation in a single sweep stage would blur the boundary between exploration and commitment.

**Relationship to [[decision-handoff-envelope]]**

Each approach worker writes a handoff envelope at `state/handoffs/<stage-id>-approach-{i}.json`. The synthesis agent's envelope lives at `state/handoffs/<stage-id>.json`. The poll logic in `spawn-sweep.sh` waits for all approach envelopes before dispatching synthesis.
