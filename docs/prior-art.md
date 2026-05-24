# Prior art and orchestration research

> Captured 2026-05-21 during Autometta repo init. Skim-grade research
> report, not a final design doc. Findings feed into `philosophy.md`
> and the dispatch contract; recommendations are starting positions,
> not committed scope.

Scope: lightweight, single-machine, long-running orchestration of Claude Code + Codex CLI workers. Mid-2026 snapshot. Skim-grade - judgements not hedges.

## (a) Native orchestrators shipped by the vendors

**Claude Code (Anthropic).** Four primitives matter:

1. **Subagents / Agent tool.** A subagent runs in a fresh context with its own system prompt, tool subset, and permissions. Cheap to spawn, no persistent identity, no scheduling. Fine for fan-out within a single session, useless across sessions.
2. **Tasks** (shipped 2026). A filesystem-backed DAG under `~/.claude/tasks`. Supports explicit `blocks`/`depends_on`, survives session restart, queryable via CLI. This is the closest Anthropic ships to a state machine; the contract is "task = JSON record with status + dependencies + history". UNIX-philosophy - no daemon, just files.
3. **Headless dispatch.** `claude -p "<prompt>"` runs non-interactive, prints to stdout, exits. Combined with hooks (PreToolUse, Stop, SessionStart) you can wire side-effects without a wrapping process. OAuth session is shared across invocations on the same host.
4. **Scheduled execution.** `CronCreate` / `ScheduleWakeup` register host-side cron entries that re-enter Claude on a schedule. State across ticks lives wherever you put it - there is no provided store beyond Tasks and the filesystem.

Verification: nothing native. The Task tool can route work to a fresh subagent for "judge" duty, but Anthropic doesn't ship a verifier loop. You build it.

**Codex CLI (OpenAI).** Three things matter:

1. **`codex exec`** - non-interactive prompt -> stdout -> exit. The headless primitive. Critical gotcha (already in your fractals notes): reads stdin after consuming the prompt arg; **must** redirect `</dev/null` from any wrapping harness.
2. **Sandbox modes** - `read-only`, `workspace-write`, `danger-full-access`. `workspace-write` is the useful one; it blocks `.git/index.lock` writes and most network calls. As you observed, this is **load-bearing** as a role boundary: the sandbox makes worker-self-verification impossible, so the implementer/verifier split is enforced by the OS, not by prompting.
3. **`codex remote-control`** (v0.130, May 2026) - an app-server entrypoint for headless remote drive. Newer, less battle-tested than `exec`; probably not worth adopting yet for a solo setup.

State: Codex itself stores nothing useful between invocations. `AGENTS.md` is the equivalent of `CLAUDE.md` - a static brief, not a state store.

Verification: also nothing native. Sandbox-as-boundary is the only structural assist.

## (b) Third-party frameworks - one-line verdicts

- **Gas Town** (Steve Yegge / gastownhall) - directly in this niche. Mayor + Polecats + Beads (git-backed ledger) + git-worktree per agent. Hooks for persistence. Scales to 20-30 agents. **Worth a serious look - your own state.yaml/Mayor-tmux pattern is a sub-architecture of this.** Heavyweight if all you want is 2-3 workers.
- **Gas City** - Gas Town's reusable SDK (orchestration-builder). The bits you'd extract if you wanted Gas Town's runtime without the cattle-town metaphor.
- **Conductor / Vibe Kanban / Claude Squad / Crystal** - GUI/Kanban shells over git worktrees. Human-in-loop tier-2 tools. Bloop (Vibe Kanban's parent) shut down early 2026; project lives on. **Skip - wrong shape for autonomous loops.**
- **OpenHands** (ex-OpenDevin) - full agent runtime with its own sandbox/browser. Heavy; not a wrapper, a competitor to Claude Code. **Skip.**
- **Aider architect/coder** - clean two-role split (planner + diff-emitter) inside one process. Worth stealing the *idea* (role split with sandbox/diff format as boundary), not the implementation. **Pattern yes, dependency no.**
- **LangGraph** - graph-as-state-machine, durable execution, checkpoints, replay. Excellent if your worker is an LLM call you control. Awkward fit for "the worker is a CLI subprocess and the state is a shell script's output". **Skip for Autometta - wrong abstraction level.**
- **CrewAI / AutoGen** - role-based teams and conversational debates respectively. AutoGen now on maintenance mode (folded into MS Agent Framework). Both assume in-process LLM calls, not CLI workers. **Skip.**
- **wshobson/agents, oh-my-claudecode, Claude-Code-Workflow** - config-pack ecosystems on top of Claude Code subagents. Useful as inspiration for subagent definitions; not orchestration runtimes. **Skim, don't adopt.**
- **MCP** - not an orchestrator, but the standard wire format for tool exposure across Claude Code / Codex / Cline. Adopt as the integration substrate.

## (c) Consensus patterns (mid-2026)

What everyone landed on, regardless of framework:

1. **Git as the state backbone.** Worktree-per-agent for isolation. Beads (Gas Town), Tasks (Claude Code), and your own `runs/experiment/tasks/<phase>/result.worker.json` are all the same shape: structured JSON/YAML, committed, replayable.
2. **State machine over messages.** `state.yaml` / Beads ledger / LangGraph checkpoints / Tasks DAG - all converge on "the agent reads the current state from a file, makes one transition, writes the next state". Pure message-passing (AutoGen-style) is out of fashion for coding work.
3. **Stage-card / ticket-as-brief.** One card per dispatch. The card path *is* the prompt. Self-contained: hard constraints, acceptance command, expected return. Your fractals dispatch contract is canonical; matches Gas Town convoys/beads exactly.
4. **Implementer != verifier, enforced by sandbox.** Codex `workspace-write` is the load-bearing example. Worker can't commit, can't run the full Acceptance suite, can't lift its own sandbox. Verifier runs outside. This is now the consensus pattern, written up in multiple 2026 posts.
5. **Cross-family verification.** Worker in family A (Codex), verifier in family B (Claude Sonnet/Opus), or vice versa. Reduces collusion on hallucinated green. Your pass-29 autonomous loop does this; Gas Town's Polecat-identity model formalises it.
6. **Stable log path handshake.** `/tmp/codex-<stage>.log` (yours) > harness-generated task IDs. Watchers and verifiers need a predictable path. Universal lesson.
7. **Cron + tick + budget.** Long-running != daemon. The pattern is a cron-driven tick that reads state, decides one action, executes, writes new state, exits. Bounded by a budget file. Your pass-29 setup is textbook; Gas Town's "mountain convoy" stall-detection is the same idea with more ceremony.
8. **Headless gotchas (stop being surprised by these):** stdin redirect, sandbox shadows, prompt-arg-isn't-full-input, card-sync race across worktrees, prior-gate regressions in Acceptance.

## Recommendation for `Autometta`

- **Roll your own runtime, but stop calling it novel.** Your pass-29 cron-tick + `state.yaml` + tmux Mayor + spawn-worker/spawn-verifier is the consensus pattern with a personal accent. Extract it as-is; don't rebase on LangGraph or CrewAI.
- **Adopt three things from Gas Town verbatim:** (i) git-backed ledger as the state store (Beads-style - you already have `state.yaml` + per-task JSON, formalise it), (ii) per-agent persistent identity with ephemeral sessions (already in `agent-whoami`), (iii) stall-detection as a first-class state ("mountain convoy" semantics). Don't pull in Gas Town the runtime - too heavy.
- **Steal Aider's architect/coder split as the role taxonomy.** Map: architect -> Claude Opus/Sonnet, coder -> Codex GPT-5.3 worker, verifier -> cross-family Claude. You already do this implicitly; name it.
- **Ignore LangGraph, CrewAI, AutoGen, OpenHands, the Kanban GUIs.** Wrong abstraction level (in-process LLM) or wrong audience (human-in-loop). Re-evaluate only if you grow past ~10 concurrent workers.
- **Adopt MCP as the only integration boundary.** Workers expose tools via MCP; orchestrator consumes via MCP. No bespoke RPC. This is the bet Anthropic, OpenAI and Cline are all making.

Net: Autometta should ship a thin, opinionated runtime - cron-tick + state.yaml FSM + stage-card dispatch + sandbox-as-role-boundary + cross-family verifier - that does one thing the existing tools don't: run *unattended overnight* on a solo developer's laptop with a budget file as the only safety. The lessons file from fractals already encodes the failure modes; the pass-29 scaffold already encodes the happy path. Package those, name the patterns, write the bugs into tests, and don't take a framework dependency.

## Sources

- [Claude Code subagents (Anthropic)](https://code.claude.com/docs/en/sub-agents)
- [Claude Code agent teams (Anthropic)](https://code.claude.com/docs/en/agent-teams)
- [Tasks update - VentureBeat](https://venturebeat.com/orchestration/claude-codes-tasks-update-lets-agents-work-longer-and-coordinate-across)
- [Shipyard - multi-agent orchestration for Claude Code](https://shipyard.build/blog/claude-code-multi-agent/)
- [Codex CLI reference (OpenAI)](https://developers.openai.com/codex/cli/reference)
- [Codex CLI non-interactive mode](https://developers.openai.com/codex/noninteractive)
- [Codex sandboxing](https://developers.openai.com/codex/concepts/sandboxing)
- [Codex v0.130 - remote-control](https://blakecrosley.com/guides/codex)
- [Gas Town (gastownhall/gastown)](https://github.com/gastownhall/gastown)
- [Gas City SDK](https://github.com/gastownhall/gascity)
- [A Day in Gas Town - DoltHub](https://www.dolthub.com/blog/2026-01-15-a-day-in-gas-town/)
- [Aider architect/editor mode](https://aider.chat/2024/09/26/architect.html)
- [Addy Osmani - The Code Agent Orchestra](https://addyosmani.com/blog/code-agent-orchestra/)
- [Awesome agent orchestrators](https://github.com/andyrewlee/awesome-agent-orchestrators)
- [LangGraph vs CrewAI vs AutoGen 2026](https://medium.com/data-science-collective/langgraph-vs-crewai-vs-autogen-which-agent-framework-should-you-actually-use-in-2026-b8b2c84f1229)
- [Blackboard architectures for LLM multi-agent systems (arXiv 2507.01701)](https://arxiv.org/abs/2507.01701)
