# Design: sweep stage

A sweep stage dispatches N parallel workers onto N scratch worktrees, each exploring a different approach to the same problem. A synthesis agent then reads all N outputs and produces a single decision document. The result is a prose decision, not a code commit.

## Problem statement

Some stages have high upstream uncertainty. When the right library, architecture, or contract shape is unclear, a single worker commits to one path before exploration is complete. If that path turns out to be wrong, the cost is a stall and a re-brief. A sweep stage trades token cost for certainty by exploring multiple approaches simultaneously before any branch is committed.

This is distinct from the panel verifier (stage 18): panel = N verifiers on one worker's output; sweep = N workers on one problem.

## Card schema additions

A sweep card adds the following fields to the Metadata section:

```
- **Sweep:** true
- **Sweep workers:** 3
- **Sweep approach prompts:** approaches/stage-NN-approach-*.md
```

`Sweep: true` triggers the sweep dispatch path in `spawn-worker.sh`. `Sweep workers` sets N (minimum 2, no defined maximum for v1). `Sweep approach prompts` is a glob of one-per-approach prompt files, each containing the approach-specific variation on the base worker prompt. If the glob resolves to fewer files than N, the dispatch fails closed.

The `Worker:` identity field on a sweep card names the synthesis agent. The per-approach workers are named in the approach prompt files.

## Dispatch flow

`spawn-worker.sh` detects `Sweep: true` and delegates to `scripts/spawn-sweep.sh`, analogous to the panel verifier delegation to `spawn-verifier-panel.sh`.

`spawn-sweep.sh`:

1. Creates N scratch git worktrees at `state/sweep/<stage-id>/approach-{0..N-1}/`, each on a fresh branch named `sweep/<stage-id>/approach-{i}`.
2. Writes the approach prompt file into each worktree as `/tmp/autometta-sweep-<stage>-<i>-prompt.txt`.
3. Dispatches N workers in parallel via `op-fetch ... codex exec` (or `claude -p`), each running inside its own worktree. Uses `register-agent.sh` for liveness tracking.
4. Polls with `watch-agent.sh` semantics, waiting for each worker's handoff envelope at `state/handoffs/<stage-id>-approach-{i}.json`.
5. Once all N envelopes are present (or the deadline is reached), dispatches the synthesis agent.

Each approach worker runs inside its own worktree with `--sandbox workspace-write`. The sandbox boundary still holds: a worker in approach-0's worktree cannot see approach-1's files until the synthesis agent reads all worktrees.

## Synthesis pass

The synthesis agent is a separate dispatched worker, not in-process aggregation.

In-process aggregation (bash + jq reading N worktree outputs) can select among proposals, but cannot synthesise across them. The synthesis agent reads all N approach outputs in its context and produces a genuine decision: which approach to adopt, what to borrow from the others, and what the residual risks are. This requires an LLM call.

The synthesis agent runs outside any worktree sandbox, reading N worktrees as inputs. It writes its deliverable (the decision document) to the main tree. It does not commit. The orchestrator commits on synthesis verifier pass, as normal.

## Deliverable shape

The synthesis output is `docs/decisions/<stage-id>.md`: a prose decision document. It does not include code. The decision records: which approach was selected, why, what was discarded, and what open questions remain. If any approach produced a viable prototype, the prototype path in the approach worktree is referenced by path.

If any approach produced code worth keeping, the synthesis card's "Inputs" section should include that worktree path, and the decision document should explicitly say "adopt approach-{i} code". A separate implementation card then cherry-picks the worktree content. The sweep stage itself never commits code to the main branch.

## Sandbox and git-state implications

Each approach worktree is on its own branch. `spawn-sweep.sh` must not run from within an existing worktree (the main checkout only). Worktrees are cleaned up after synthesis completes, or left for operator inspection if synthesis stalls.

The main checkout's `state/` dir is the shared message bus. All handoff envelopes land there regardless of which worktree the worker ran in; the worker must use the repo root's `state/handoffs/` path, not a worktree-relative path.

The `git worktree prune` command is idempotent and safe to call after synthesis; `spawn-sweep.sh` runs it on clean exit.

## Boundary against panel-verifier and research-sweeper

| Pattern | What runs in parallel | Output |
|---|---|---|
| Panel verifier (18) | N verifiers on one worker's output | Synthesised PASS/FAIL verdict |
| Sweep stage (this design) | N workers on one problem | Prose decision document |
| Research-sweeper (MCP skill) | N search/fetch operations | Notes and summaries |

Panel is about confidence in a judgement. Sweep is about exploring a problem space before committing. Research-sweeper produces notes; sweep stages produce binding design decisions that shape subsequent implementation cards.

## Load-bearing beliefs

| Belief | Status |
|---|---|
| Git is the state store | Respected: worktrees are git branches; outputs are tracked commits. |
| Filesystem is the message bus | Respected: handoff envelopes at `state/handoffs/<stage-id>-approach-{i}.json` are the completion signals. |
| Sandbox is the role boundary | Respected: each approach worker runs in its own worktree; workers cannot see each other's files during the parallel phase. |
| Cross-family verification by default | Respected: synthesis worker and verifier follow normal cross-family pairing. |
| Cron + tick > daemon | Tension, mitigated: one card produces N+2 dispatches. The tick still exits after one state transition. Exception named in `docs/philosophy.md` belief 5. |
| Budget files, not retries | Respected: each dispatch consumes from the shared budget; the card names N+2 costs explicitly. |
| Operational failures are normal | Respected: a crashed approach worker leaves a stalled handoff; `spawn-sweep.sh` waits up to the deadline, then dispatches synthesis on available outputs (or stalls). |
| Observability is plain text plus tmux | Respected: each approach worker registers via `register-agent.sh`; the ticker shows N+1 concurrent registrations. |

## Risks and open questions

- **Worktree accumulation.** If synthesis stalls, N worktrees remain on disk. `spawn-sweep.sh` writes a marker file for `autometta sweep-prune <stage-id>`.
- **Approach divergence.** Workers on different approaches must write to distinct output directories to avoid collision in the synthesis agent's view.
- **Synthesis quality.** For v1, N=2 or N=3 is recommended; larger N risks overloading the synthesis agent's context.
- **Cost.** N+2 LLM calls (N workers + synthesis + verifier). The card's budget section should name the total.

## Smallest-possible prototype card outline

**Stage NN-sweep-proto**: two Sonnet workers in scratch worktrees explore two library choices for one problem. Synthesis agent produces `docs/decisions/NN-sweep-proto.md`. No code lands in main tree.

Deliverables: `docs/decisions/NN-sweep-proto.md`, `approaches/NN-sweep-proto-approach-{0,1}.md` (approach prompts, written by orchestrator before dispatch), `state/sweep/NN-sweep-proto/` (worktrees, cleaned after synthesis).

New scripts introduced: `scripts/spawn-sweep.sh` (approach dispatch + worktree management), `scripts/spawn-sweep-synthesis.sh` (synthesis dispatch), cleanup subcommand in `bin/autometta`.
