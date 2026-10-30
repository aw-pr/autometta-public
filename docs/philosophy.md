# Philosophy

## One-line pitch

A contract and a lightweight tick loop for coding agents working towards a defined outcome. Claude Code and Codex CLI take separate implementation and verification roles. The human defines the work and resolves decisions; deterministic scripts handle scheduling, bookkeeping and mechanical recovery.

## What problem is Autometta solving?

The problem in plain language:

- I have two CLI agent families on my machine (Claude Code, Codex CLI).
- I want implementation and independent verification to run across hours or overnight, on a single laptop, with bounded overlap between independent stages.
- The worker is an existing CLI subprocess. I need a delivery contract around it, including permissions, acceptance evidence and integration, rather than an in-process model workflow.
- Stage cards, worktree isolation, a tick state machine and cross-family verification need to fit together without depending on a hosted orchestration service.

Autometta is that packaging.

## Beliefs we're betting on

1. **Git is the state store.** Cards and changes are versioned; the tick snapshots runtime state onto the `autometta/state` ref without checking it out. Live logs and local configuration need not be tracked to participate in that audit trail. No orchestration daemon or database.
2. **The filesystem is the message bus.** One stage card per dispatch. Both roles read the same brief and exchange structured completion and verdict artefacts through known file paths.
3. **Sandbox is the role boundary.** The Codex `workspace-write` sandbox prevents checks and writes that require wider permissions. The worker's self-check cannot substitute for independent acceptance in the verifier's declared seat. GUI or network requirements must be explicit.
   See [the bounded worker SDK postmortem](experiments/worker-sdk-postmortem.md): an SDK worker still needs an independently enforced role boundary.
4. **Cross-family verification by default.** Worker in family A, verifier in family B. This separates authorship from judgement; it does not eliminate shared model errors or faults in the requirement.
5. **Cron + tick > daemon.** Long-running work does not require a resident orchestration process. A tick reads state, makes one transition per stage, writes state and exits. A terminal landing may dispatch an eligible next stage in the same fire. A declared pipeline pair may overlap worker N+1 with verifier N, with landing kept in order. An N-worker sweep remains [design-only](design/sweep-stage.md).
   See [the bounded SDK controller postmortem](experiments/sdk-controller-postmortem.md).
6. **Budget files, not retries.** A budget file is the authority for bounded spend, checked before further dispatch. Bounded mechanical recovery does not replace it. Token accounting happens after dispatch, so work already admitted can overshoot a cap; quota admission and heartbeat limits add controls, not a promise of an exact cash ceiling.
7. **Operational failures are normal.** Tests fail, code crashes, agents hang. The tick handles bounded mechanical recovery and preserves failed attempts. Decisions about criteria, frozen contracts or further attempts belong to the operator's orchestration chat, delivered as escalations.
8. **Observability reads the same files.** Logs, a liveness registry and heartbeat reports feed tmux tickers, the terminal UI and a browser dashboard. No separate telemetry database. Dashboard cost equivalents are estimates, not subscription invoices.

*Considered and deferred:* serving stage cards as MCP resources rather than file paths (multi-machine readiness). The server would read cards from git and the filesystem path stays the mandatory fallback. Design only, see [`docs/design/mcp-cards.md`](design/mcp-cards.md).

*Shipped, opt-in:* a Fable-as-advisor verifier, where a cheap request model consults Claude Fable only at the decision point instead of running a frontier model for the whole verification. Set `verifier.claude.advisor` in the manifest or `AUTOMETTA_CLAUDE_ADVISOR` for one dispatch; it sits under the sdk transport on `auth.claude.mode: api` only and fails closed elsewhere (`scripts/advisor-order-smoke.sh` guards the ordering). An addition to a verifier and not a replacement for cross-family pairing. Design in [`docs/design/advisor-verifier.md`](design/advisor-verifier.md).

## Non-goals

- **Teams.** Multi-developer state and distributed coordination are not in scope.
- **Cloud agents.** Single-machine. If the laptop is asleep, the loop is asleep.
- **Generic workflow engine.** This is for coding work. Not data pipelines. Not document workflows. Not "any task with a DAG".
- **A new agent family.** Autometta drives existing CLIs. It does not ship its own model, its own prompting layer, or its own sandbox.

## Scope decisions we've already made

- **Two CLI families to start: Claude Code + Codex CLI.** Patterns should generalise to a third (Gemini CLI, Cursor agent), but the reference implementation assumes these two.
- **macOS is the reference platform.** Linux has a cron path. Native Windows is unsupported and WSL2 is untested.
- **Bash + Python for the loop scaffold, markdown for the contracts.** No Go, no Rust, no TypeScript runtime. The dispatch contract is language-agnostic by virtue of being prose + templates.
- **MCP is the only tool integration boundary.** Workers expose tools via MCP; orchestrator consumes via MCP. No bespoke RPC.

## Inspirations and prior art

Patterns are adopted, not invented. Autometta stands on:

- **Gas Town** (Steve Yegge / gastownhall): the git-backed ledger, persistent agent identity and explicit stall detection informed this design. Autometta does not take a runtime dependency on it.
- **Aider architect/coder**: the role split between planning and implementation informed the protocol. Autometta adds an independent verifier and uses permissions to enforce the role boundary.
- **The Unix philosophy.** Small tools, plain text, pipes. `state.yaml` is just a file; `tick.sh` is just a shell script; `events.log` is just append-only text.
- **fractals-from-the-90s**: the original dispatch contract and five headless gotchas, recorded in the lessons file.
- **agentic-rag-kimble pass 28-29**: the autonomous loop scaffold, budget file pattern and cross-family verification protocol.

## Decisions banked before pass 2

These were the open questions when pass 1 shipped. Each has been resolved and recorded in `memory/`; the resolutions shape the tick-loop layer.

- **Name of the autonomous-loop layer.** It is the tick loop. The former scheduled queue-minding role is [retired](proposals/controller-retired.md); `phat-controller.sh` remains a set of deterministic verbs.
- **Single-tenant vs multi-project.** One cron tick services multiple project repos via a filesystem-based subscriber registry in `~/.autometta/subscribers/`. See [`memory/decision-single-tick-multi-repo-subscribe.md`](../memory/decision-single-tick-multi-repo-subscribe.md).
- **Identity drift.** `agent-whoami` resolves the current model at dispatch time; the orchestrator skill maintains the cross-family tier mapping. Stage cards record the model that was current when authored, and the loop respects that. See [`memory/decision-identity-via-orchestrator-skill.md`](../memory/decision-identity-via-orchestrator-skill.md).
- **Verifier handoff format.** Pass 28's `result.json -> result.worker.json` rename is gone. Verifier output lands at `state/verifiers/<stage-id>.json`. See [`memory/decision-verifier-handoff-naming.md`](../memory/decision-verifier-handoff-naming.md).
- **Failure budget.** The primary safety is a clock-tick count per repo, complemented by a token cap and a consecutive-failure cap in `state/budget.json`. See [`memory/decision-failure-budget-clock-tick.md`](../memory/decision-failure-budget-clock-tick.md).


Autometta is successful if:

1. A new project can adopt the dispatch contract: copy the templates, define acceptance and dispatch a worker and verifier.
2. The same operator can automate that contract: install the tick, review a bounded queue and budget, then let the scheduler run it.
3. The five fractals lessons and the four kimble quirks are never relearned the hard way again.
4. The protocol remains clear enough to extend to another CLI family without rewriting the contract. The reference implementation currently supports Claude Code and Codex CLI.

If Autometta is doing more than that, it's drifted out of scope.
