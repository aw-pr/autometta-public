# Autometta

A pattern library for headless agent orchestration on a single machine.

## Why this exists

Token-maxing is the gateway drug to AI psychosis. Managing several agent threads across several projects is draining. Patterns like Steve Yegge's Gas Town show that autonomous agent runs over long periods can yield good result, provided enough effort goes into specs, design, and verification artefacts.

The open source or comercial orchestrators are either token heavy and api biased or cede control to higher-level interface surfaces. Some vendors are fussy about running their CLI inside another harness at all.

Autometta is a small implementation of agent orchestration. Cron is the heartbeat that survives laptop lid close with power, as long as the machine is configued appropriatley. The contract dispatches worker and verifier roles as needed and runs against whichever auth the operator already has. Cross-family verification (Sonnet checking Codex, or the reverse) catches a class of failure that same-family self-verification silently misses.

## Two families, one tree

This repo is designed for Claude Code and Codex CLI to work in the same tree without prejudice. State and memory that agents need across sessions lives in the repo (`memory/`, `state/`, stage cards under `examples/`), not in any one harness's private directory. Every agent picks up the same context.

Not a framework. Not a runtime. Not a hosted service. A set of contracts, templates, and (eventually) thin shell scaffolding for running Claude Code + Codex CLI workers unattended, with cross-family verification, on a solo developer's laptop.

## Status

Pre-alpha. Both passes are shipped.

Pass 1 (dispatch contract) and pass 2 (phat-controller autonomous loop) have both been self-hosted end to end against this repo through stage 6.

The first end-to-end benchmark (BENCH-005) drove the dispatch contract against a multi-stage Swift refactor in two parallel orchestrator lanes. Both escalated at the 2-loop budget. Codex went 12/20 then 18/20 on the FLAP-rate acceptance command; Claude Opus stayed pinned at 20/20 across both loops. The pass condition (0 FLAP) was not met by either lane, but the cross-family asymmetry is the interesting finding: Codex got closer then regressed, Claude was stuck at maximum throughout. See `[examples/benchmarks/bench-005/](./examples/benchmarks/bench-005/)` for the lane summaries and escalation notes. A green benchmark on a non-trivial backlog remains the next milestone.

## What this is for

You're a solo developer. You have Claude Code and Codex CLI on one machine. You want to run multi-agent work - implementer + verifier, or N parallel workers on independent stages - sometimes interactively, sometimes overnight. You don't want to take a framework dependency to do it.

Autometta packages the contracts that make this work without surprise.

## What this is not for

- Teams. The patterns assume one human, one machine, one OAuth session per agent family.
- Production agent systems. No SLA, no observability, no retry semantics beyond what the FSM provides.
- LLM-call orchestration inside a single process. Use LangGraph, CrewAI, or the Claude Agent SDK directly. Autometta is for the case where the worker is a CLI subprocess and the state lives on the filesystem.

## Two layers

| Layer                 | What it is                                                                                                                                                 | Driver                       | Status             |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------- | ------------------ |
| **Dispatch contract** | The contract between an orchestrator and a worker for one unit of work. Stage card, worker prompt, acceptance command, sandbox boundary, verifier handoff. | Human (orchestrator session) | Pass 1 - this repo |
| **Autonomous loop**   | A cron-driven tick that reads `state.yaml`, dispatches one worker and/or verifier, writes the next state, and exits. Budget file is the only safety.       | `cron` + `tick.sh`           | Pass 2 - shipped   |

The loop layer is built on top of the dispatch layer. You can use dispatch without the loop. You cannot use the loop without dispatch.

## Decision tree - which layer do I want?

- **One stage, in front of me, I want to step through it** -> use the dispatch contract directly. Open an orchestrator session (Claude Code), fill in `templates/stage-card.md`, dispatch a Codex worker with `templates/worker-prompt.md`, verify yourself, commit.
- **Many stages, well-defined, I want to run them overnight** -> use the autonomous loop. Author N stage cards, subscribe the repo via `scripts/subscribe-repo.sh`, install a cron entry per `docs/setup.md`, walk away. Inspect `state/state.yaml` and `~/.phat-controller/log/cron.log` in the morning.
- **One stage, exploratory, I'm not sure what "done" looks like** -> don't use Autometta. Use a normal Claude Code session.

## Adopted patterns (and what we ignored)

After surveying the mid-2026 landscape:

**Adopted:**

- Git-backed ledger as the state store. From [Gas Town](https://github.com/gastownhall/gastown) (Beads).
- Per-agent persistent identity with ephemeral sessions. From `agent-whoami`.
- Stall-detection as a first-class state. From Gas Town's "mountain convoy" semantics.
- Architect / coder / verifier role split. From Aider's architect mode; cross-family verifier from pass-29.
- Sandbox-as-role-boundary. From the Codex `workspace-write` accident.
- MCP as the only integration boundary for tools.

**Ignored:**

- LangGraph, CrewAI, AutoGen - wrong abstraction level (in-process LLM, not CLI worker).
- OpenHands - competitor to Claude Code, not a wrapper.
- Vibe Kanban / Conductor / Claude Squad / Crystal - human-in-loop GUI shells, wrong audience.
- Gas Town the runtime - too heavy for 2-3 workers; we mine the patterns, not the code.

See `docs/philosophy.md` for the long-form version.

## Layout

```
autometta/
├── README.md                 # this file
├── LICENSE
├── CLAUDE.md / AGENTS.md     # shared agent brief (AGENTS.md is a symlink)
├── docs/
│   ├── philosophy.md         # design philosophy, scope, non-goals
│   ├── dispatch-contract.md  # pass 1 - the contract
│   ├── verification.md       # pass 1 - the gate model
│   ├── lessons.md            # hard-won failure modes
│   ├── phat-controller.md    # pass 2 - the autonomous loop design
│   ├── setup.md              # pass 2 - operator setup guide
│   └── prior-art.md          # what was adopted and what was ignored
├── templates/
│   ├── stage-card.md         # one card per dispatch
│   ├── worker-prompt.md      # the prompt the worker reads
│   └── orchestrator-checklist.md
├── scripts/                  # pass 2 runtime: tick, spawn, budget, init
├── schemas/                  # state.yaml + budget.json schemas
├── state/                    # per-repo runtime state (gitignored content)
├── memory/                   # cross-session agent memory (in-repo)
├── skills/                   # skills hosted by this repo
└── examples/
    ├── fractals-stage-cards/ # real cards as illustrations
    └── self-host/            # the cards Autometta used to build itself
```

## Reading order

1. `docs/philosophy.md` - what we believe and why.
2. `docs/dispatch-contract.md` - the load-bearing document.
3. `docs/lessons.md` - five gotchas that will bite you on day one.
4. `templates/stage-card.md` and `templates/worker-prompt.md` - copy these, fill them in.
5. `docs/verification.md` - how to gate the worker's output.
6. `docs/phat-controller.md` and `docs/setup.md` - when you want to put the dispatch contract under cron.

## Your first dispatch (five minutes)

The fastest way to see what this is.

1. Clone Autometta somewhere you can reach from your target project.
2. In the target project, open an orchestrator session in Claude Code (or Codex CLI; the orchestrator role is family-agnostic).
3. Copy three files into the target repo:
  ```sh
   mkdir -p docs/stages
   cp <Autometta>/templates/stage-card.md docs/stages/01-my-first-stage.md
   cp <Autometta>/templates/worker-prompt.md /tmp/worker-prompt.md
   cp <Autometta>/templates/orchestrator-checklist.md /tmp/checklist.md
  ```
4. Fill in `docs/stages/01-my-first-stage.md` - one objective, one deliverable, one acceptance command. Walk through the orchestrator checklist in `/tmp/checklist.md` as you go.
5. Dispatch a worker from the orchestrator session. Read it the stage card path. The worker writes code; you run the acceptance command yourself; if it passes, fire a verifier (a different model family) to audit the change. Commit on green.

That is pass 1. No `scripts/`, no `tick.sh`, no cron. Read `docs/dispatch-contract.md` for the full seven-step protocol; read `docs/lessons.md` for the five gotchas before your second dispatch.

When the same loop is worth automating, follow `docs/setup.md` to subscribe the repo to phat-controller and put it under cron.

## About the name

Metta is Pali for loving-kindness. Autometta is a form of automata that tries to be kind to the human driving it: an orchestrator that spins up the right worker for each unit of work and a verifier from a different model family to check it, so the operator stays the director rather than becoming a micro-manager.

## Licence

MIT. See `[LICENSE](./LICENSE)`.
