# CLAUDE.md / AGENTS.md

This file is the shared brief for **any agent** working in this repo - Claude Code, Codex CLI, or any future CLI family. `AGENTS.md` is a symlink to this file; do not edit them separately. One source of truth, two conventional filenames.

## Two-family invariant

Autometta is built for Claude Code **and** Codex CLI to operate in the same working tree without prejudice. Every change should make sense from both sides. If a doc, template, or script implicitly assumes only one family, flag it.

State and memory that agents need across sessions live **in the repo**, not in any one harness's private directory:

- `memory/` - append-only agent memory shared across families. See `memory/README.md` for the contract. **Do not** mirror this into `~/.claude/projects/.../memory/` or any Codex-side equivalent; the in-repo copy is authoritative.
- `state/` - `state.yaml` plus per-task JSON for the autonomous loop. Runtime contents are gitignored; the directory itself is part of the contract.
- `skills/` - agent skills hosted by this repo. `agent-orchestrator` lives here canonically; `mcp-hub/skills/agent-orchestrator` is a symlink back.

## What this repo is

Autometta is a **pattern library**, not a runtime. Pre-alpha. The repo contains prose (`README.md`, `docs/`), markdown templates, the `agent-orchestrator` and `autometta-setup` skills, a shared `memory/` store, and the bash scaffolding for the tick loop (`scripts/`, `schemas/`, `state/`). There is no build, no test suite, and no package manifest - do not invent one.

The repo extracts patterns from two prior projects (`fractals-from-the-90s` dispatch contract; `agentic-rag-kimble` pass 28-29 autonomous loop) and packages them for solo single-machine multi-agent CLI work. See `README.md` for the pitch and `docs/philosophy.md` for the long-form scope.

## Two layers, shipped in two passes

1. **Dispatch contract (pass 1 - shipped):** the contract between an orchestrator and one worker for one unit of work. Stage card -> worker prompt -> sandbox boundary -> acceptance command -> verifier handoff. Human drives the orchestrator session. Deliverables live in `docs/` and `templates/`.
2. **Autonomous tick loop (pass 2 - shipped):** cron-driven tick that reads `state.yaml`, dispatches one worker and/or verifier, writes the next state, exits. Two adjacent stages with declared, disjoint path claims may run as a pipeline pair, while verification and landing remain ordered. Budget file is the only safety. The loop layer **sits on top of** the dispatch contract - never modify the loop in ways that bypass it. Runtime in `scripts/`, schemas in `schemas/`, per-repo state in `state/`. See `docs/tick-loop.md` for the design and `docs/setup.md` for the operator flow.

The operational roles are the human or interactive orchestrator, the worker,
the verifier, and **phat-controller**, the scheduled queue minder. The tick
loop is the mechanism phat-controller supervises, not an agent role.

Pass 2 also ships **agent observability**: a per-agent liveness registry at `state/active-agents/<pid>.json`, a heartbeat watchdog at `scripts/heartbeat.sh` that surfaces stalls / over-budget conditions to `state/heartbeat.json`, a full-window repo ticker (`scripts/repo-ticker.sh`), the `autometta tui` run/history/messages view, and a polling primitive (`scripts/watch-agent.sh`) that any orchestrator-led manual dispatch can block on to catch silent agent deaths. See `docs/observability.md`. Spend is instrumented separately: `tick.sh` appends one cost-log line per dispatched role to `state/cost-log.jsonl` (per-tier `cost_usd_est` from `scripts/rates.sh`, `cached_input_tokens` vs `input_tokens`, `cache_hit_rate`). Schema and the prompt-caching notes are in `docs/cost-log.md`.

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
8. Codex CLI prefers `$CODEX_HOME/auth.json` over the `OPENAI_API_KEY` env var. If `~/.codex/auth.json` has `auth_mode: "chatgpt"` (the default after `codex login`), an `op-fetch OPENAI_API_KEY=... -- codex exec` dispatch still bills the subscription. Fix: a sibling `CODEX_HOME` (default `~/.codex-api-only`) with `auth_mode: "apikey"`; spawn scripts export and `--pass CODEX_HOME` through op-fetch in api mode and fail closed if the sibling is missing.
9. Claude worker subshell (`( ... ) &`) receives SIGHUP when the LaunchAgent tick exits, silently killing the worker at ~21s with a 0-byte log. Codex is unaffected (no wrapping subshell). Fix is two complementary parts: `disown "$pid"` immediately after capturing `$!` in `spawn-worker.sh`, `spawn-verifier.sh`, and `spawn-verifier-panel.sh` (shell job-control SIGHUP), AND `AbandonProcessGroup` in `templates/launchagent.plist.tpl` (launchd reaping the tick's process group on exit). Keep both. Verified 2026-05-29 with a real LaunchAgent dispatch: a claude worker survived the tick exit and ran to completion. See `docs/lessons.md` gotcha 9.
10. A tick can destroy the gitignored `state/state.yaml`: `commit_state_branch`'s `git add state/state.yaml` is a silent no-op (gitignored), so the state branch never backs it up, and a degenerate read/write in `state_apply_json` can overwrite the only on-disk copy with an empty `stages: []` stub. Fix: `state_apply_json` read/write guards + a rolling `state/state.yaml.bak`, plus a top-of-tick integrity guard that restores `.bak` or halts `state-corrupt`. See `docs/lessons.md` gotcha 10.
11. `op read` can block forever on a macOS TCC prompt no one is there to answer, hanging an overnight dispatch with an empty log. `op-fetch` wraps every read in a watchdog (`OP_FETCH_TIMEOUT`, default 60s). The TCC grant does not survive a `brew upgrade 1password-cli`. See `docs/lessons.md` gotcha 11.
12. `IFS=$'\n\t'` has no space in it, so an unquoted expansion of a space-joined flag string is a silent no-op split: `--effort high` reached the CLI as one option name containing a space and every Claude verifier with a declared effort died instantly (`error: unknown option '--effort high'`), burning all three `verifier_attempt_cap` retries. Multi-token argument lists travel in a bash array (`AUTOMETTA_EFFORT_ARGV`), expanded quoted, never through word splitting; `# shellcheck disable=SC2086` documents such an intent while hiding its failure. Codex was unaffected: clap attaches a short option's value, and codex trims the leading space, so its effort was honoured throughout. See `docs/lessons.md` gotcha 12.
13. `codex exec --oss` refuses any Ollama model without thinking support (`"<model>" does not support thinking`), which as of codex-cli 0.149.1 leaves only the gpt-oss family usable on the free local route. `llama3.3:70b`, `llama4:scout`, `qwen3-coder:30b` and `devstral` are all refused, and the last four ran fine in the 2026-08-24 bake-off, so this is a CLI regression under a documented result rather than a standing limit. `codex_local_preflight` checked only that the model was *pulled*, so the failure landed after the stage was `in_progress`; it now reads the `Capabilities` block from `ollama show` and fails closed before the spawn, failing open only when that block cannot be read. See `docs/lessons.md` gotcha 13.

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

- **Mode lives in** `.autometta.local.yaml` (gitignored) in the **subscribed repo**, under `auth.<family>.mode`. Resolver fallback (no manifest present) is `subscription` for both. The shipped template recommends `codex: api` + `claude: subscription`; flip per repo as needed.
- **Refs live in** `op-refs.sh` (committed, placeholders, in the autometta repo) + `~/.config/autometta/op-refs.local.sh` (gitignored, real op:// refs, mode 0600). Variables: `OP_REF_OPENAI_API_KEY`, `OP_REF_ANTHROPIC_API_KEY`, optional `OP_REF_CLAUDE_CODE_OAUTH_TOKEN`. The XDG location is visible to both the dev checkout and the brew-installed CLI; `<repo>/op-refs.local.sh` works for dev only.
- **Sibling CODEX_HOME** at `${AUTOMETTA_CODEX_HOME:-~/.codex-api-only}` is required for codex api mode (codex prefers `~/.codex/auth.json` over `OPENAI_API_KEY` — see lessons.md gotcha #8). One-time setup: `mkdir -p ~/.codex-api-only && chmod 700 ~/.codex-api-only && op-fetch --print "$OP_REF_OPENAI_API_KEY" | CODEX_HOME=~/.codex-api-only codex login --with-api-key`. Spawn scripts export and pass it through op-fetch via `--pass CODEX_HOME` whenever codex is in api mode. `autometta auth check codex` verifies both the ref and the sibling.
- **Service-account token** for `op-fetch` is read from `$OP_SERVICE_ACCOUNT_ENV` (default `~/.config/op/service-account.env`); no biometric prompt.
- **Dispatch-time override**: `AUTOMETTA_CODEX_MODE=api` / `AUTOMETTA_CLAUDE_MODE=api` (or the reverse). Beats the manifest.
- **Verify before dispatching**: `autometta auth status` (per-family table + op-fetch presence) and `autometta auth check <family>` (PASS / FAIL / subscription, with redacted credential, no token spend).
- **Fail-closed**: missing `op-fetch`, unset `OP_REF_*`, or an unresolved `op://YOUR_VAULT/...` placeholder aborts the spawn before any token is spent.

`scripts/auth-route.sh <family>` emits the `NAME=$OP_REF_NAME` pair (empty in subscription). `scripts/spawn-worker.sh` and `scripts/spawn-verifier.sh` source `op-refs.sh`, call the resolver, then `op-fetch <pairs> -- codex exec ...` / `op-fetch <pairs> -- claude -p ...`. Subscription mode still goes through `op-fetch`, so any stray `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` in the parent shell is stripped rather than silently redirecting billing. Full surface in `docs/setup.md` section 7 and `README.md` section "Billing routes".

## Upgrading the local install (agents: read this when picking up a session)

The CLI ships as a local Homebrew tap rendered from this checkout. If the installed version (`autometta --version`) is older than the publish-branch HEAD (run `git rev-parse --short HEAD` in the autometta checkout), the in-flight agent is on a stale toolchain and may not see recent scripts (heartbeat, watch-agent, agent-ticker, install-launchagent, etc.).

Canonical upgrade from any session:

```sh
cd /path/to/autometta
git pull --ff-only
scripts/install-homebrew-local.sh
autometta --version             # should match git HEAD short SHA
autometta attach <repo>         # refreshes the two-window tmux viewer
```

The brew tap is rendered at install time; `brew update` alone is not enough. Re-run `scripts/install-homebrew-local.sh` after every `git pull` of this repo.

## Manual orchestrator dispatch pattern

When an orchestrator session dispatches a worker or verifier directly (not via the tick loop), the canonical pattern is:

```sh
# Source the op:// reference table (autometta repo root)
source "$autometta_root/op-refs.sh"

# Resolve the auth route for this family (emits NAME=ref pairs or empty)
auth_pairs="$(REPO_ROOT="$repo" scripts/auth-route.sh codex)"

# Launch via op-fetch (env -i + allowlist + named refs only). For codex+api
# also export CODEX_HOME pointing at the sibling auth dir so codex reads
# auth_mode: apikey instead of the chatgpt-mode ~/.codex/auth.json
# (see gotcha #8). Pass it through via --pass CODEX_HOME.
CODEX_HOME="${AUTOMETTA_CODEX_HOME:-$HOME/.codex-api-only}" \
  op-fetch $auth_pairs --pass CODEX_HOME -- \
  codex exec -C "$repo" --sandbox workspace-write "$(cat prompt.txt)" </dev/null >log.txt 2>&1 &
pid=$!
disown

# Register so the heartbeat / ticker can see it
scripts/register-agent.sh "$repo" "$pid" worker codex "$identity" "$card" "$log" "$budget_secs"

# Block until done or stuck — the harness notifies on return
scripts/watch-agent.sh "$repo" "$pid" "stage-NN-worker"
```

`watch-agent.sh` exit code: `0` clean, `2` STUCK, `3` bad input. STUCK escalates when the heartbeat first flags `silent` and the grace window expires (defaults 60s poll, 120s grace, both env-overridable). For the `claude` family swap the launch line for `( cd "$repo" && op-fetch $auth_pairs -- claude -p "$prompt" </dev/null >log 2>&1 ) &` and pass `claude` as the family arg to `auth-route.sh` and `register-agent.sh`.

`op-fetch` resolves any named refs via the 1Password service-account token at `$OP_SERVICE_ACCOUNT_ENV` (default `~/.config/op/service-account.env`) and exec's the child with a sanitised env. No biometric prompt, works under cron / LaunchAgent. See `docs/setup.md` section 7 and `docs/observability.md` for the full surface.

When using the claude family as a verifier, `spawn-verifier.sh` may take the SDK route instead of `claude -p` if the repo's manifest sets `verifier.claude.transport: sdk` (requires `auth.claude.mode: api`; env override: `AUTOMETTA_CLAUDE_TRANSPORT`). See `docs/sdk-verifier.md`.

On verifier PASS, a manual orchestrator commit carries the same role attribution the autonomous loop emits (`scripts/tick.sh`): author is the worker, the orchestrator and verifier are role-named `Co-Authored-By` lines, and the `Autometta-*` trailers hold the clean canonical identity for analysis. The orchestrator identity is the card's `Orchestrator` metadata line. The `${id/ </ (role) <}` substitution inserts the role into the display name (the email still keys co-authorship).

```sh
git -C "$repo" commit \
  --author="$worker_identity" \
  -m "$stage_id: $headline" \
  -m "Co-Authored-By: ${orchestrator_identity/ </ (orchestrator) <}
Co-Authored-By: ${verifier_identity/ </ (verifier) <}
Autometta-Orchestrator: $orchestrator_identity
Autometta-Worker: $worker_identity
Autometta-Verifier: $verifier_identity"
```

All trailer lines go in one `-m` so git parses them as a single trailer block; query a role with `git log --format='%(trailers:key=Autometta-Worker,valueonly)'`. See `docs/dispatch-contract.md` step 7.
