# Philosophy

## One-line pitch

A lightweight agent orchestrator for long-running coding work toward a defined outcome. The philosophy of Gas Town without the bulk, and the power of Claude Code and Codex CLI without the model lock-in. Autometta uses the multi-agent capabilities of existing harnesses, facilitates cross-family execution and validation, and minimises the human-in-the-loop babysitting that operational runs otherwise demand. The human remains the orchestrator and director, not a micro-managing facilitator.

## What problem is Autometta solving?

The problem in plain language:

- I have two CLI agent families on my machine (Claude Code, Codex CLI).
- I want to run multi-agent work ; implementer + verifier, or N parallel workers ; across hours or overnight, on a single laptop.
- Every existing framework is either (a) the wrong abstraction level (LangGraph, CrewAI ; they assume the worker is an in-process LLM call, not a CLI subprocess), or (b) the wrong audience (Vibe Kanban, Conductor ; human-in-loop GUI shells).
- The patterns that actually work ; stage cards, sandbox-as-role- boundary, cron-tick state machines, cross-family verification ; are scattered across blog posts and personal repos. Nobody has packaged them at the right altitude for a solo developer.

Autometta is that packaging.

## Beliefs we're betting on

1. **Git is the state store.** State lives in files, files live in git, git is the audit log. No daemon, no database, no service.
2. **The filesystem is the message bus.** One stage card per dispatch. The card path is the prompt. The worker reads it, the verifier reads it, nothing is in flight.
3. **Sandbox is the role boundary.** The Codex `workspace-write` sandbox makes worker-self-verification structurally impossible. We exploit this accident rather than try to lift it.
4. **Cross-family verification by default.** Worker in family A, verifier in family B. Reduces collusion on hallucinated green.
5. **Cron + tick > daemon.** Long-running != resident process. A tick that reads state, makes one transition, writes state, exits, is easier to reason about, debug, kill, and resume than any long-lived process. *Exception:* a sweep stage (opt-in, `Sweep: true` on the card) dispatches N workers in parallel into N scratch worktrees, then a synthesis agent. The tick model still holds; the exception is in the number of dispatches per card, not in the tick structure.
6. **Budget files, not retries.** The only safety against runaway spend is a budget file checked at the top of every tick. No exponential backoff, no circuit breakers ; bounded total spend, hard stop.
7. **Operational failures are normal.** Tests fail, code crashes, agents hang. The cron tick detects and recovers from operational failure without human intervention; the operator only gets pulled back in when the work itself stalls.
8. **Observability is plain text plus tmux.** A lightweight observability plane: per-stage logs on disk, a live agent graph on top, and tmux panes for attaching to workers and orchestrators when an operator does want to look. No dashboards, no services.

*Considered and deferred:* serving stage cards as MCP resources rather than file paths (multi-machine readiness). The server would read cards from git and the filesystem path stays the mandatory fallback. Design only, see [`docs/design/mcp-cards.md`](design/mcp-cards.md).

## Non-goals

- **Teams.** Multi-developer state is not in scope. Beads / Gas Town scale to a team; Autometta intentionally does not.
- **Cloud agents.** Single-machine. If the laptop is asleep, the loop is asleep.
- **Generic workflow engine.** This is for coding work. Not data pipelines. Not document workflows. Not "any task with a DAG".
- **A new agent family.** Autometta drives existing CLIs. It does not ship its own model, its own prompting layer, or its own sandbox.

## Scope decisions we've already made

- **Two CLI families to start: Claude Code + Codex CLI.** Patterns should generalise to a third (Gemini CLI, Cursor agent), but the reference implementation assumes these two.
- **macOS is the reference platform.** Linux should work; Windows is not tested.
- **Bash + Python for the loop scaffold, markdown for the contracts.** No Go, no Rust, no TypeScript runtime. The dispatch contract is language-agnostic by virtue of being prose + templates.
- **MCP is the only tool integration boundary.** Workers expose tools via MCP; orchestrator consumes via MCP. No bespoke RPC.

## Inspirations and prior art

Patterns are adopted, not invented. Autometta stands on:

- **Gas Town** (Steve Yegge / gastownhall) ; Beads ledger, Polecat identity, Mayor + Convoy semantics. Autometta's `state.yaml` + Mayor tmux is a sub-architecture of this. We mine the patterns; we don't take the runtime dependency.
- **Aider architect/coder** ; the role split between planner and diff-emitter, with the diff format as the boundary. We extend this to a third role (verifier) and use the sandbox as the boundary.
- **The Unix philosophy.** Small tools, plain text, pipes. `state.yaml` is just a file; `tick.sh` is just a shell script; `events.log` is just append-only text.
- **fractals-from-the-90s** ; the five headless gotchas (stdin hang, card-sync race, opaque log paths, sandbox-as-role-boundary, prior- gate regressions). Canonical for the lessons file.
- **agentic-rag-kimble pass 28-29** ; the autonomous loop scaffold, the budget file pattern, the cron tick contract, the cross-family verification protocol, the four production quirks (codex sandbox flag, state.yaml authority, publish-guard exemption, result.json rename).

## Decisions banked before pass 2

These were the open questions when pass 1 shipped. Each has been resolved and recorded in `memory/`; the resolutions shape the phat-controller layer.

- **Name of the autonomous-loop layer.** "Mayor" is a Gas Town term. We picked our own: `phat-controller`. See [`memory/decision-loop-name-phat-controller.md`](../memory/decision-loop-name-phat-controller.md).
- **Single-tenant vs multi-project.** One cron tick services multiple project repos via a filesystem-based subscriber registry in `~/.phat-controller/subscribers/`. See [`memory/decision-single-tick-multi-repo-subscribe.md`](../memory/decision-single-tick-multi-repo-subscribe.md).
- **Identity drift.** `agent-whoami` resolves the current model at dispatch time; the orchestrator skill maintains the cross-family tier mapping. Stage cards record the model that was current when authored, and the loop respects that. See [`memory/decision-identity-via-orchestrator-skill.md`](../memory/decision-identity-via-orchestrator-skill.md).
- **Verifier handoff format.** Pass 28's `result.json -> result.worker.json` rename is gone. Verifier output lands at `state/verifiers/<stage-id>.json`. See [`memory/decision-verifier-handoff-naming.md`](../memory/decision-verifier-handoff-naming.md).
- **Failure budget.** The primary safety is a clock-tick count per repo, complemented by a token cap and a consecutive-failure cap in `state/budget.json`. See [`memory/decision-failure-budget-clock-tick.md`](../memory/decision-failure-budget-clock-tick.md).


Autometta is successful if:

1. A new project can easily adopt the dispatch contract ; copy the templates, fill them in, dispatch a worker.
2. The same operator can convert that project to autonomous loop readily ; install the cron tick, author N cards, walk away.
3. The five fractals lessons and the four kimble quirks are never relearned the hard way again.
4. The patterns hold up when a new agent family ships (Gemini CLI, or whatever comes next) ; the dispatch contract accepts a third worker without rewriting.

If Autometta is doing more than that, it's drifted out of scope.
