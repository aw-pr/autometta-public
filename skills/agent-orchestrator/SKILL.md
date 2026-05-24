---
name: agent-orchestrator
description: Decomposes an explicitly-requested multi-agent engineering task, routes each sub-task to the right capability tier, and runs sub-agents in parallel to minimise token cost without dropping quality. Trigger ONLY when the user explicitly asks for orchestration - phrases like "orchestrate this", "multi-agent", "agent orchestration", "decompose and route", "tiered agents", "spin up agents". Do NOT trigger on ordinary multi-step tasks; single-session work is the default and orchestration is opt-in.
---

## When NOT to orchestrate

Orchestration has fixed overhead (decomposition, briefing, integration, extra token spend across sub-agent contexts). Skip it and work in the main session when:

- The task touches a single file or is a localised fix.
- The work is inherently sequential with no parallelisable branches.
- Total estimated sub-agents would be 1-2 (the orchestration tax exceeds the gain).
- The user did not explicitly ask for orchestration (see trigger rule above).

If you start decomposing and the plan collapses to <=2 trivial sub-tasks, abandon orchestration and just do the work.

---

## Role

You are the orchestrator. Plan, delegate, integrate, review. You do not implement details yourself unless the task is genuinely irreducible. Keep your own context lean: delegate exploration and file-dumping to sub-agents and absorb only their conclusions.

This skill is harness-agnostic. Decomposition, tiering, briefing, and integration logic are identical across Claude Code, Codex CLI, Cursor, and Gemini CLI. Only the *dispatch mechanism* differs - see the Delegation adapter below.

---

## Step 1 - Decompose the task

Break the user's request into discrete sub-tasks. For each: **what** must be produced, **inputs** required, **dependencies**, and **tier**.

Write the decomposition as a numbered list before spawning any sub-agents. Show it to the user if the plan is non-trivial or spawns more than ~4 sub-agents.

---

## Step 2 - Assign capability tiers

Tiers are defined by *capability and cost*, not by a specific model name.

| Tier | Capability | Thinking | Use when |
|------|-----------|----------|----------|
| T0 - Orchestrator | Top reasoning model, in main session | High | Integration, architecture decisions, final review. Stay in main session; never spawn a T0 sub-agent. |
| T1 - Hard Reasoning | Top reasoning model, focused sub-agent | High | Novel algorithm; security/correctness review; sparse or contradictory docs; high failure cost. |
| T2 - Specified Implementation | Mid-tier model | Medium | Well-scoped features with clear acceptance criteria; refactors with existing test coverage. |
| T3 - Mechanical / Glue | Mid- or low-tier model | Low | Boilerplate, generated types, repetitive test scaffolding, spec-driven config, migrations with a known transformation. |
| T4 - Retrieval / Exploration | Cheapest available / read-only explore agent | None | Listing files, grepping symbols, reading docs, summarising existing code without modifying it. |

### Per-harness tier mapping (adapter)

| Tier | Claude Code | Codex CLI | Cursor | Gemini CLI |
|------|-------------|-----------|--------|------------|
| T0/T1 | Opus, high thinking | top reasoning model, `worker` or custom role | top model, agent window | Gemini Pro subagent |
| T2/T3 | Sonnet | mid model role | mid model | Gemini Pro/Flash |
| T4 | Haiku / Explore agent | `explorer` role (sandbox **read-only by design** - perfect T4 fit) | subagent, read-only | codebase-investigation built-in |

### Model identities per tier (Anthropic <-> OpenAI <-> Google)

Concrete model names attached to the tiers above for paired or comparative work. **Match tiers across families.** Pairing T1-Anthropic against T2-OpenAI confounds the signal you are trying to read - see the [[reference_model_family_equivalents]] memory entry for the underlying rule.

| Tier | Anthropic | OpenAI | Google |
|------|-----------|--------|--------|
| **T0/T1 - Frontier** | Claude Opus 4.7 (`claude-opus-4-7`) | GPT-5.5 (`gpt-5.5`) | Gemini Pro (current) |
| **T2/T3 - Workhorse** | Claude Sonnet 4.6 (`claude-sonnet-4-6`) | Codex GPT-5.3 (`gpt-5.3-codex`) | Gemini Pro / Flash |
| **T4 - Light** | Claude Haiku 4.5 (`claude-haiku-4-5`) | GPT-5 mini (`gpt-5-mini`) | Gemini Flash |

When dispatching paired multi-family work (comparative reviews, A/B benchmarks, independence-checking lanes), the tier governs which row of the table you pull from on each side. Solo execution can pick a tier-appropriate model from any single family - only paired or comparative work has to lock the row.

### Heuristics

- **Failure cost** high (broken contract, corrupt data, manual rollback)? -> T1.
- **Specification completeness** - fully specified by tests/types/docs? -> T2/T3. Ambiguous? -> T1.
- **Synthesis vs retrieval** - original reasoning vs reading and reporting? Retrieval is always T4.
- **Reversibility** - easily reverted -> T2/T3; hard to undo (schema migration, published artifact) -> T1.

---

## Step 3 - Write sub-agent briefs

Each brief is self-contained: **Objective** (one sentence), **Inputs** (paths/symbols/prior outputs), **Constraints** (style, interface, perf budget), **Acceptance criteria** (concrete, checkable), **Out of scope**.

**Token economy:** paste *small* excerpts directly into briefs. For *large* inputs, instruct the sub-agent to read the named file in its own context. Never re-explore from the main session; if exploration is needed, run a T4 sub-agent first and pass distilled output downward.

---

## Step 4 - Parallelise where possible

Group sub-tasks with no shared dependency into one batch and spawn in parallel.

```
Batch A (parallel): T4 retrieval - gather all facts needed.
Batch B (parallel): T2/T3 implementation - each has full briefs from Batch A.
Batch C (sequential): T1 integration review - runs after B completes.
```

**Parallel-write isolation (mandatory):**
- If the harness supports isolated execution, use it for any parallel batch that writes files (Cursor worktrees, Codex sandboxes).
- If the harness has no isolation primitive, enforce **disjoint file sets** - no two parallel sub-agents may write the same file. Never parallelise writes to one file.

**Budget guard:** estimate count before spawning. If it exceeds ~6, or any T1 batch has >3 agents, surface the plan and per-batch count and confirm.

---

## Step 4a - Timeout discipline (mandatory)

A sub-agent that hangs silently is the worst failure mode: the orchestrator waits, the user waits, and no signal tells anyone the work has stopped. Every dispatched call carries an explicit wall-clock budget.

**Per-tier wall-clock budgets** (kill threshold = 1.5x budget):

| Tier | Budget | Kill at |
|------|--------|---------|
| T4 retrieval / explore (read-only) | 120 s | 180 s |
| T3 mechanical implementation | 240 s | 360 s |
| T2 specified implementation | 360 s | 540 s |
| T1 hard reasoning / cross-family review | 480 s | 720 s |

**How to enforce, by dispatch channel:**

- **Bash sub-process** (codex exec, gemini, gh, npm test, etc.): pass an explicit `timeout` parameter to the Bash tool, AND wrap the command in `timeout <N>s ...` as belt-and-braces. Cross-harness CLIs must also use their own non-interactive flags (`--sandbox read-only`, `--yes`, `--non-interactive`) so they cannot block on a permission prompt.
- **Sub-agent (Task/Agent tool)**: include the budget in the brief as a hard constraint ("Report back within N minutes; if you cannot, surface a partial result and stop."). The harness may not enforce it, but the budget anchors the sub-agent's planning.
- **Background commands**: every `run_in_background` Bash call MUST set `timeout`. Never spawn an unbounded background process.

**Stall detection (no output is failure, not progress):**

- If a background tool's output file is still 0 bytes past the kill threshold, treat as hung. Kill the process, log the failure, do not silently re-spawn.
- Empty stdout with exit code 0 from a CLI that was asked to produce a written report = failure (the CLI hit a sandbox or permission issue silently). Re-brief once with the underlying cause addressed.

**Re-brief vs surface (combines with the Step 5 failure budget):**

1. First timeout -> kill, diagnose, re-brief the same tier once with the timeout cause fixed (tighter scope, different sandbox flag, smaller prompt).
2. Second timeout -> surface to the user. Do not silently re-spawn a third attempt.

**Future cron-supervised enforcement:** when an orchestration run is launched under a cron tick (a routine that fires the orchestrator on a schedule), the tick itself supervises a hard per-routine wall-clock max above the per-sub-agent budgets here. The per-sub-agent timeouts in this section are the *first* line of defence; the cron tick is the second. Routine authors should pick a wall-clock max = sum(sub-agent budgets) + 20% integration overhead.

---

## Step 5 - Integrate

After sub-agents return, you (orchestrator, main session) integrate. Do not trust self-reports.

- Run the test suite or build yourself.
- Read the diff of every changed file, not just the summary.
- Check public interfaces and types remain consistent across sub-task boundaries.
- Confirm acceptance criteria from each brief are actually met.

**Failure budget:** if a sub-task output fails its acceptance criteria, re-brief the *same* tier agent once. If it fails a second time, surface to the user - do not silently re-spawn a third time. Re-tiering is only justified when the failure reveals the task was under-specified, not as a quiet escalation path.

---

## Token-economy rules

- Keep the orchestrator context lean. Delegate file-reading to T4 sub-agents; never paste entire files into the main session.
- Small inputs: paste excerpts; large inputs: instruct the sub-agent to read in its own context.
- Reserve T1 for genuine ambiguity or high failure cost.
- Prefer one parallel batch of T3 agents over sequential single-model calls for mechanical work.
- Retire sub-agent context after output is absorbed.

---

## Delegation adapter (harness mechanics)

Decomposition and briefs are identical everywhere. Dispatch them as follows:

- **Claude Code** - spawn parallel sub-agents via the Task/Agent tool; use the `Explore` agent for T4.
- **Codex CLI** - define roles in `config.toml` (`worker`, `explorer`, `monitor`, or custom). Requires the experimental subagent opt-in flag.
- **Cursor** - `/multitask` fans out async subagents; each runs in its own git worktree (free write isolation).
- **Gemini CLI** - define subagents as markdown + YAML frontmatter in `.gemini/agents`; main session dispatches.

If a harness lacks parallel-spawn, fall back to sequential phased execution with the same briefs - quality is preserved; only wall-clock and parallel token spread are lost.

---

## Definition of done

1. For code: build passes cleanly with no new warnings. For research/docs: every deliverable produced and internally consistent.
2. All acceptance criteria from every sub-task brief satisfied - verified by the orchestrator, not reported by the sub-agent.
3. No public interface changed without explicit user approval.
4. The orchestrator has read and understood the final diff in full.
5. A commit message has been *proposed* to the user (not committed without explicit instruction - see `[[project-solo-workflow]]`). When multiple agents contributed, attribute primary author via `--author=` and any helpers via `Co-Authored-By:` trailers per `[[commit-discipline]]`.

See `REFERENCE.md` (in this skill directory) for a worked example and failure-mode heuristics.
