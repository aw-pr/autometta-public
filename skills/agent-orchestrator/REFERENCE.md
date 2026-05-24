# agent-orchestrator - reference material

Supplementary worked example and extended heuristics. The orchestrator may read this on demand; it is not loaded into the active session by default.

## Worked example - GPU compute backend in a Go project (Metal via purego)

**User request**: "Add a Metal compute backend to this Go project using purego so we can run compute shaders on Apple Silicon without CGo."

### Decomposition

| # | Sub-task | Tier | Rationale |
|---|----------|------|-----------|
| 1 | Explore repo: find existing backend interface, build tags, test harness | T4 | Pure retrieval; no reasoning. |
| 2 | Explore Metal/purego FFI patterns: read `purego` README and prior art | T4 | Pure retrieval; feeds sub-task 4. |
| 3 | Decide whether to extend the existing interface or wrap it | T0 (orchestrator) | Architecture decision; cross-cutting; stays in main session. |
| 4 | Implement the Metal dylib loader and symbol binding via purego | T1 | Sparse docs, platform-specific FFI, high failure cost if symbols are wrong. |
| 5 | Write the Go backend struct implementing the existing interface | T2 | Interface now specified (sub-task 3); criteria are the interface methods. |
| 6 | Generate table-driven tests and a build-tag guard (`//go:build darwin && arm64`) | T3 | Mechanical; pattern clear from tests found in sub-task 1. |
| 7 | Integration review: compile, run tests, check no CGo leakage | T0 (orchestrator) | Final validation; stays in main session. |

### Execution plan

- Batch A (parallel): sub-tasks 1 and 2 (T4).
- Orchestrator decision: sub-task 3 (T0, uses Batch A output).
- Batch B (parallel, isolated worktrees/sandboxes - disjoint files: loader vs struct vs tests): sub-tasks 4, 5, 6 (T1, T2, T3 - briefs include interface spec from 3 and repo excerpts from A).
- Final: sub-task 7 (T0).

**Why not all top-tier?** Sub-tasks 5 and 6 are fully specified once the interface is decided; T2/T3 saves meaningful cost with no quality loss. Sub-tasks 1 and 2 need no reasoning; T4 is sufficient and fast.

## Failure-mode heuristics

- Sub-agent returns a confident summary but the diff is empty -> likely brief was under-specified or sub-agent could not access required context. Re-brief at the same tier with explicit file paths.
- Two parallel writers touch the same file -> orchestration bug; you violated disjoint-file-set rule. Abort batch, re-decompose so file sets do not overlap.
- T3 mechanical task fails twice -> the task is not actually mechanical. Re-tier to T2 with explicit acceptance criteria, or de-scope.
