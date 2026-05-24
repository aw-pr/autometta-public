# CLAUDE.md / AGENTS.md

This file is the shared brief for **any agent** working in this repo - Claude Code, Codex CLI, or any future CLI family. `AGENTS.md` is a symlink to this file; do not edit them separately. One source of truth, two conventional filenames.

## Two-family invariant

Autometta is built for Claude Code **and** Codex CLI to operate in the same working tree without prejudice. Every change should make sense from both sides. If a doc, template, or script implicitly assumes only one family, flag it.

State and memory that agents need across sessions live **in the repo**, not in any one harness's private directory:

- `memory/` - append-only agent memory shared across families. See `memory/README.md` for the contract. **Do not** mirror this into `~/.claude/projects/.../memory/` or any Codex-side equivalent; the in-repo copy is authoritative.
- `state/` - `state.yaml` plus per-task JSON for the autonomous loop. Runtime contents are gitignored; the directory itself is part of the contract.
- `skills/` - agent skills hosted by this repo. `agent-orchestrator` lives here canonically; `mcp-hub/skills/agent-orchestrator` is a symlink back.

## What this repo is

Autometta is a **pattern library**, not a runtime. Pre-alpha. The repo contains prose (`README.md`, `docs/`), markdown templates, the `agent-orchestrator` and `autometta-setup` skills, a shared `memory/` store, and the bash scaffolding for the phat-controller loop (`scripts/`, `schemas/`, `state/`). There is no build, no test suite, and no package manifest - do not invent one.

The repo extracts patterns from two prior projects (`fractals-from-the-90s` dispatch contract; `agentic-rag-kimble` pass 28-29 autonomous loop) and packages them for solo single-machine multi-agent CLI work. See `README.md` for the pitch and `docs/philosophy.md` for the long-form scope.

## Two layers, shipped in two passes

1. **Dispatch contract (pass 1 - shipped):** the contract between an orchestrator and one worker for one unit of work. Stage card -> worker prompt -> sandbox boundary -> acceptance command -> verifier handoff. Human drives the orchestrator session. Deliverables live in `docs/` and `templates/`.
2. **Autonomous loop / `phat-controller` (pass 2 - shipped):** cron-driven tick that reads `state.yaml`, dispatches one worker and/or verifier, writes the next state, exits. Budget file is the only safety. The loop layer **sits on top of** the dispatch contract - never modify the loop in ways that bypass it. Runtime in `scripts/`, schemas in `schemas/`, per-repo state in `state/`. See `docs/phat-controller.md` for the design and `docs/setup.md` for the operator flow.

## Load-bearing beliefs (read before proposing changes)

Decisions, not preferences. Diverging needs an explicit conversation, not a quiet refactor:

- **Git is the state store; filesystem is the message bus.** No daemons, no databases, no services. One stage card per dispatch; the card path is the prompt.
- **Sandbox is the role boundary.** Codex `workspace-write` makes worker-self-verification structurally impossible. We *exploit* this rather than lift it. Verifier always runs outside the worker sandbox.
- **Cross-family verification by default.** Worker in family A, verifier in family B (typically Codex worker, Claude verifier).
- **Cron + tick > daemon.** A tick reads state, makes one transition, writes state, exits. Resumable, killable, debuggable.
- **Budget file, not retries.** Hard stop on bounded total spend. No exponential backoff, no circuit breakers.
- **MCP is the only tool integration boundary.** No bespoke RPC.

## Headless gotchas to never re-learn

Invariants when reviewing or writing scaffolding (full write-up lands in `docs/lessons.md`):

1. `codex exec` reads stdin after the prompt arg - always redirect `</dev/null` from any wrapping harness.
2. Card-sync race across git worktrees - verifier and worker must see the same card content; serialise writes.
3. Log paths must be predictable (e.g. `/tmp/codex-<stage>.log`), not harness-generated task IDs.
4. Sandbox shadows: a worker that *appears* to pass acceptance inside its sandbox may be lying about side-effects it couldn't perform.
5. Prior-gate regressions: re-running acceptance after a later change can surface a regression in an earlier stage.

## Conventions specific to this repo

- **British English** in prose. No em dashes. No "AI-tell" vocabulary (`delve`, `leverage`, `seamless`, `robust`). The persona-west audit rules apply to all committed prose.
- **Markdown is the deliverable for pass 1.** Treat docs and templates as the product, not as docs *about* the product.
- **Inline `<ALW>...</ALW>` tags anywhere in the repo are Tony's open notes**, not committed decisions. Resolve in conversation before treating as scope. None should remain in `docs/philosophy.md` at this point; if you see one, that is a regression worth flagging.
- **Per-agent git author attribution** is enforced globally (see `~/.claude/rules/mcp-hub-dev-rules.md`). Committer is always `anthonylwest`; author is the agent identity string. Atomic commits.
- **Don't edit `AGENTS.md` directly** - it is a symlink to this file.
- **Don't edit `skills/agent-orchestrator/` from outside this repo** - the `mcp-hub` copy is a symlink back here.

## Skills hosted by this repo

- `skills/agent-orchestrator/` - canonical home. Loaded into `~/.claude/skills/agent-orchestrator` via the `mcp-hub` symlink chain. Edits here are the source of truth for every consumer.
