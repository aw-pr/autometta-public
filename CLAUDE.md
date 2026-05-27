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

Pass 2 also ships **agent observability**: a per-agent liveness registry at `state/active-agents/<pid>.json`, a heartbeat watchdog at `scripts/heartbeat.sh` that surfaces stalls / over-budget conditions to `state/heartbeat.json`, a tmux agent ticker in the third pane of the `autometta-<repo>` viewer (`scripts/agent-ticker.sh`), and a polling primitive (`scripts/watch-agent.sh`) that any orchestrator-led manual dispatch can block on to catch silent agent deaths. See `docs/observability.md`.

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
6. `claude -p` does not stream its log - the file stays at 0 bytes until the run completes and is then written in a single burst. Log-mtime staleness is *not* a stuck signal for the claude family; only over-budget is. The heartbeat encodes this asymmetry (see `scripts/heartbeat.sh`).
7. `claude -p` needs `--dangerously-skip-permissions` to act autonomously; `--permission-mode bypassPermissions` combined with `-p` exits silently with an empty log.

## Conventions specific to this repo

- **British English** in prose. No em dashes. No "AI-tell" vocabulary (`delve`, `leverage`, `seamless`, `robust`). The persona-west audit rules apply to all committed prose.
- **Markdown is the deliverable for pass 1.** Treat docs and templates as the product, not as docs *about* the product.
- **Inline `<ALW>...</ALW>` tags anywhere in the repo are Tony's open notes**, not committed decisions. Resolve in conversation before treating as scope. None should remain in `docs/philosophy.md` at this point; if you see one, that is a regression worth flagging.
- **Per-agent git author attribution** is enforced globally (see `~/.claude/rules/mcp-hub-dev-rules.md`). Committer is always `anthonylwest`; author is the agent identity string. Atomic commits.
- **Don't edit `AGENTS.md` directly** - it is a symlink to this file.
- **Don't edit `skills/agent-orchestrator/` from outside this repo** - the `mcp-hub` copy is a symlink back here.

## Skills hosted by this repo

- `skills/agent-orchestrator/` - canonical home. Loaded into `~/.claude/skills/agent-orchestrator` via the `mcp-hub` symlink chain. Edits here are the source of truth for every consumer.

## Auth routes — subscription vs API key (agents: read this before any dispatch)

Aligned to the `auth-route-security` skill. Every dispatch goes through `op-fetch`, which exec's the child via `env -i` + allowlist + only the named refs.

- **Mode lives in** `.autometta.local.yaml` (gitignored) in the **subscribed repo**, under `auth.<family>.mode`. Default for both `codex` and `claude` is `subscription`; `api` is opt-in.
- **Refs live in** `op-refs.sh` (committed, placeholders) + `op-refs.local.sh` (gitignored, real op:// refs) at the autometta repo root. Variables: `OP_REF_OPENAI_API_KEY`, `OP_REF_ANTHROPIC_API_KEY`, optional `OP_REF_CLAUDE_CODE_OAUTH_TOKEN`.
- **Service-account token** for `op-fetch` is read from `$OP_SERVICE_ACCOUNT_ENV` (default `~/.config/op/service-account.env`); no biometric prompt.
- **Dispatch-time override**: `AUTOMETTA_CODEX_MODE=api` / `AUTOMETTA_CLAUDE_MODE=api` (or the reverse). Beats the manifest.
- **Verify before dispatching**: `autometta auth status` (per-family table + op-fetch presence) and `autometta auth check <family>` (PASS / FAIL / subscription, with redacted credential, no token spend).
- **Fail-closed**: missing `op-fetch`, unset `OP_REF_*`, or an unresolved `op://YOUR_VAULT/...` placeholder aborts the spawn before any token is spent.

`scripts/auth-route.sh <family>` emits the `NAME=$OP_REF_NAME` pair (empty in subscription). `scripts/spawn-worker.sh` and `scripts/spawn-verifier.sh` source `op-refs.sh`, call the resolver, then `op-fetch <pairs> -- codex exec ...` / `op-fetch <pairs> -- claude -p ...`. Subscription mode still goes through `op-fetch`, so any stray `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` in the parent shell is stripped rather than silently redirecting billing. Full surface in `docs/setup.md` section 7 and `README.md` section "Billing routes".

## Upgrading the local install (agents: read this when picking up a session)

The CLI ships as a local Homebrew tap rendered from this checkout. If the installed version (`autometta --version`) is older than the publish-branch HEAD (`git -C /Users/AnthonyWest/repos/autometta rev-parse --short HEAD`), the in-flight agent is on a stale toolchain and may not see recent scripts (heartbeat, watch-agent, agent-ticker, install-launchagent, etc.).

Canonical upgrade from any session:

```sh
cd /Users/AnthonyWest/repos/autometta
git pull --ff-only
scripts/install-homebrew-local.sh
autometta --version             # should match git HEAD short SHA
autometta attach <repo>         # picks up the third tmux pane (ticker)
```

The brew tap is rendered at install time; `brew update` alone is not enough. Re-run `scripts/install-homebrew-local.sh` after every `git pull` of this repo.

## Manual orchestrator dispatch pattern

When an orchestrator session dispatches a worker or verifier directly (not via `phat-controller` cron), the canonical pattern is:

```sh
# Source the op:// reference table (autometta repo root)
source "$autometta_root/op-refs.sh"

# Resolve the auth route for this family (emits NAME=ref pairs or empty)
auth_pairs="$(REPO_ROOT="$repo" scripts/auth-route.sh codex)"

# Launch via op-fetch (env -i + allowlist + named refs only)
op-fetch $auth_pairs -- codex exec -C "$repo" --sandbox workspace-write "$(cat prompt.txt)" </dev/null >log.txt 2>&1 &
pid=$!
disown

# Register so the heartbeat / ticker can see it
scripts/register-agent.sh "$repo" "$pid" worker codex "$identity" "$card" "$log" "$budget_secs"

# Block until done or stuck — the harness notifies on return
scripts/watch-agent.sh "$repo" "$pid" "stage-NN-worker"
```

`watch-agent.sh` exit code: `0` clean, `2` STUCK, `3` bad input. STUCK escalates when the heartbeat first flags `silent` and the grace window expires (defaults 60s poll, 120s grace, both env-overridable). For the `claude` family swap the launch line for `( cd "$repo" && op-fetch $auth_pairs -- claude -p "$prompt" </dev/null >log 2>&1 ) &` and pass `claude` as the family arg to `auth-route.sh` and `register-agent.sh`.

`op-fetch` resolves any named refs via the 1Password service-account token at `$OP_SERVICE_ACCOUNT_ENV` (default `~/.config/op/service-account.env`) and exec's the child with a sanitised env. No biometric prompt, works under cron / LaunchAgent. See `docs/setup.md` section 7 and `docs/observability.md` for the full surface.
