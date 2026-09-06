# Graph engineering and autometta

> Assessment captured 2026-08-31 from Karpathy's Stanford lecture and the
> playbook literature that grew around it. Judgements, not hedges. Findings
> feed the graph-layer stage cards; nothing here is committed scope until a
> card exists and the load-bearing beliefs conversation has happened.

## The concept

Andrej Karpathy's Stanford lecture ["Delete Everything, Keep
Graph"](https://www.youtube.com/watch?v=XdbpCM4yGyE) runs the progression
LLM, prompt, agent, loop, graph: once an agentic loop works, the durable
asset is not the transcripts or even the code but the graph of what was
learned. His `autoresearch` project ran roughly 700 experiments in two days
and kept about 20 optimisations; the complaint that motivates the lecture is
that the loop forgets. "The agent forgets; the graph does not." His
coordination layer, AgentHub, replaced branches with a sprawling commit DAG
traversed by `ah children` and `ah leaves`.

The playbook that grew around the lecture (the "Graph Engineering" PDF plus
Anthropic's knowledge-graph cookbook) has six steps:

1. **Reflective loop.** Generate, critique, revise. Works only with
   verifiable outcomes, reversible actions (git reset), short feedback
   cycles, and a bounded action space.
2. **Parallel execution.** Workers in isolated worktrees, a reducer
   synthesising results rather than the orchestrator accumulating debris.
3. **Knowledge graph.** Typed entities and subject-predicate-object edges,
   provenance on every triple.
4. **Grounded evaluation.** Evaluators fact-check claims against supported
   edges rather than giving free-form feedback.
5. **Shared memory layer.** Workers publish structured updates (nodes,
   edges, `run_id`, `agent_id`), validated and merged transactionally,
   linked to the commit DAG.
6. **Dual graph architecture.** A commit DAG for "what changed" and a
   knowledge graph for "what is true", connected but separate.

Production write-ups add a five-plane model: Control (objectives, budgets),
Execution (sandboxed tools), Artifact (versioned code and plans), Graph
(entities and lineage), Evaluation (deterministic plus model scorers).

## Where autometta already stands

Four of the five planes are implemented, and `docs/prior-art.md` arrived at
the same consensus ("git as the state backbone", "state machine over
messages") before the lecture landed.

| Playbook element | Autometta today | Verdict |
| --- | --- | --- |
| Reflective loop | Tick loop: acceptance commands (verifiable), run worktrees + git reset (reversible), one transition per tick (short horizon), sandbox + `budget.json` (bounded) | done |
| Parallel execution | Pipeline pairs with declared disjoint path claims, per-agent worktrees, liveness registry, heartbeat | done, deliberately small-scale |
| Grounded evaluation | Cross-family verifier outside the worker sandbox; rubric schema, verifier panel, retro-grade | ahead of the playbook: the boundary is structural, not advisory |
| Provenance | `Autometta-Orchestrator/Worker/Verifier` trailers on every landed commit, queryable via `git log --format='%(trailers:...)'` | done; a typed edge set living in the commit DAG |
| Commit DAG ("what changed") | State branch, run branches, dispatch envelopes keyed to stages | done |
| Knowledge graph ("what is true") | `memory/` prose files with untyped `[[wikilinks]]` | the gap |

## The gap: the knowledge layer

`memory/` is the right idea (in-repo, cross-family, authoritative, indexed,
with a staleness discipline) but the wrong shape for graph engineering:

- **Untyped edges.** A `[[wikilink]]` carries no predicate; a traversal
  learns nothing from it.
- **No transactional writes.** Workers do not publish structured facts from
  runs. `state/cost-log.jsonl` is the only structured per-run fact stream,
  and it records spend only.
- **No bounded query.** Recall is "read `INDEX.md` and grep", which stops
  scaling exactly where Karpathy hit the wall. Autometta's equivalent is a
  long run history in `state/envelopes/` (or the legacy `state/handoffs/`
  for a stale subscriber) that nothing aggregates into knowledge.
- **Evaluators do not read it.** Verifiers check acceptance commands, not
  accumulated facts, so a lesson learned in stage 12 does not structurally
  constrain stage 40.

The fit for closing the gap is natural. The load-bearing belief is "git is
the state store; the filesystem is the message bus; no databases", and the
pattern does not need a database. A committed typed-triple file (JSONL of
`{subject, predicate, object, source_commit, agent_id, run_id, confidence}`)
with a schema in `schemas/`, written by the tick on verifier PASS and read
by a subgraph-selection script, is pure autometta idiom. The existing
trailers already give the commit-DAG linkage step 6 wants.

Changing `memory/` or the tick is a load-bearing area: explicit
conversation first, per `CLAUDE.md`.

## What the vendors ship natively

**Anthropic** is furthest along and has effectively blessed the pattern:

- **Dynamic Workflows** (the Workflow tool in Claude Code): Claude writes
  JavaScript orchestration, 16 concurrent sub-agents, 1,000 per run. Covers
  the dispatch and fan-out layer, single-vendor only, no cross-family
  verification, no persistent cross-session state beyond Tasks.
- **Knowledge Graph Construction cookbook**: the reference implementation of
  steps 3 and 4. Haiku extracts schema-constrained triples, Sonnet resolves
  aliases, NetworkX MultiDiGraph assembly, bounded queries with edge
  citations. A cookbook, not a runtime; the shared-memory layer is still
  yours to build, which is exactly the slot `memory/` occupies.
- **Tasks**: filesystem DAG with dependencies, the nearest native thing to
  `state.yaml`, but per-harness and untyped.

**OpenAI** has less: `codex exec` plus sandbox modes (which autometta
exploits as its role boundary) and the Agents SDK for in-process
orchestration with tracing and guardrails. AgentHub is Karpathy's own layer,
not an OpenAI product; there is no native OpenAI answer to the graph plane.

## Verdict

Autometta is a strong substrate for graph engineering: better than either
vendor on evaluation grounding, provenance, and vendor-neutrality, since
both native stacks assume a single family while the playbook's "workers
write, evaluators fact-check" split maps directly onto the cross-family
contract. The one real deficit is the typed knowledge layer, and the
Anthropic cookbook pipeline is adaptable to fill it without breaking a
single load-bearing belief. The lecture's title is close to a description of
what this repo already does: delete the transcripts, keep the git DAG. The
second graph is the missing half.

## Sources

- [Karpathy, "Delete Everything, Keep Graph" (Stanford lecture)](https://www.youtube.com/watch?v=XdbpCM4yGyE)
- [Graph Engineering: From Karpathy's Loops to Shared Knowledge Graphs](https://pkhamdee.blog/2026/07/21/graph-engineering-from-karpathys-loops-to-shared-knowledge-graphs/)
- [The Karpathy Loop (Dooza)](https://www.dooza.ai/blog/karpathy-loop-graph-engineering)
- [Graph engineering playbook PDF (casys.ai mirror)](https://casys.ai/downloads/graph-engineering-multi-agentic-systems-playbook.pdf)
- [Graph Engineering for AI Agents: When the Graph Earns Its Cost (wavect)](https://wavect.io/blog/graph-engineering-ai-agents/)
