# Autometta

**A lightweight pattern library for headless agent orchestration on a single machine. It spins up worker agents with cross-family validation: Codex verifies Claude, and vice versa.**

![License](https://img.shields.io/badge/license-MIT-green) ![Status](https://img.shields.io/badge/status-pre--alpha-orange)

## Why this exists

Token-maxing is the gateway drug to AI psychosis. Managing several agent threads across several projects is draining. Patterns like Steve Yegge's Gas Town show how multiple autonomous agents can run for long periods and produce good results, provided enough effort goes into specs, design, and verification artefacts.

The open source or commercial orchestrators are either token-heavy and API-biased, or cede control to higher-level interface surfaces. Some vendors are fussy about running their CLI inside another harness at all.

Autometta is a small implementation of agent orchestration. Cron is the heartbeat that survives laptop lid close with power, as long as the machine is configured appropriately. The contract dispatches worker and verifier roles as needed and runs against whichever auth the operator already has. Cross-family verification (Sonnet checking Codex, or the reverse) catches a class of failure that same-family self-verification silently misses.

## Two families, one tree

This repo is designed for Claude Code and Codex CLI to work in the same tree without prejudice. State and memory that agents need across sessions lives in the repo (`memory/`, `state/`, stage cards under `examples/`), not in any one harness's private directory. Every agent picks up the same context.

Not a framework. Not a runtime. Not a hosted service. A set of contracts, templates, and (eventually) thin shell scaffolding for running Claude Code + Codex CLI workers unattended, with cross-family verification, on a solo developer's laptop.

## Status

Pre-alpha. Pass 1 is shipped and proven; pass 2 is shipped but the unattended path has a known caveat (see "Feature status" below and "Known limitations").

Pass 1 (dispatch contract) and pass 2 (phat-controller autonomous loop) have both been self-hosted end to end against this repo through stage 6. The macOS launchd path that lets the loop run unattended carries a known limitation pending a fresh smoke test: see "Known limitations".

The first end-to-end benchmark (BENCH-005) drove the dispatch contract against a multi-stage Swift refactor in two parallel orchestrator lanes. Both escalated at the 2-loop budget. Codex went 12/20 then 18/20 on the FLAP-rate acceptance command; Claude Opus stayed pinned at 20/20 across both loops. The pass condition (0 FLAP) was not met by either lane, but the cross-family asymmetry is the interesting finding: Codex got closer then regressed, Claude was stuck at maximum throughout. See `[examples/benchmarks/bench-005/](./examples/benchmarks/bench-005/)` for the lane summaries and escalation notes. A green benchmark on a non-trivial backlog remains the next milestone.

## Supported platforms

macOS and Linux only. The scaffolding is bash plus standard POSIX tools and assumes either `cron` or (on macOS) `launchd` as the heartbeat. Windows is not supported - there is no native bash, no `cron`/`launchd`, no native `tmux`, and the `codex` CLI itself has no native Windows binary as of mid-2026. WSL2 may work as an effective Linux host but is untested and undocumented; treat it as unsupported.

| Platform | Pass 1 (dispatch contract) | Pass 2 (autonomous loop) | Notes |
|---|---|---|---|
| macOS | supported | supported | First-class. Homebrew-local install. Heartbeat via `launchd` LaunchAgent (per-repo) or `cron` fallback. |
| Linux | supported | supported | Heartbeat via `cron`. Homebrew-local install is macOS-first; manual install or Linuxbrew elsewhere. |
| Windows | not supported | not supported | No native bash, `cron`, `launchd`, `tmux`, or native `codex` binary. WSL2 is untested. |

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
| **Agent observability** | Per-agent liveness registry (`state/active-agents/`), heartbeat watchdog (`scripts/heartbeat.sh`), tmux agent ticker (`scripts/agent-ticker.sh`), polling primitive (`scripts/watch-agent.sh`). Catches silent agent deaths in both manual and loop dispatches. | `scripts/heartbeat.sh` + tmux | Shipped (on top of pass 2) |

The loop layer is built on top of the dispatch layer. You can use dispatch without the loop. You cannot use the loop without dispatch. The agent observability layer plugs into both: any dispatcher registers via `scripts/register-agent.sh`, and the heartbeat + ticker surface that registry without further coupling.

## Decision tree - which layer do I want?

- **One stage, in front of me, I want to step through it** -> use the dispatch contract directly. Open an orchestrator session (Claude Code), fill in `templates/stage-card.md`, dispatch a Codex worker with `templates/worker-prompt.md`, verify yourself, commit.
- **Many stages, well-defined, I want to run them overnight** -> use the autonomous loop. Author N stage cards, subscribe the repo via `autometta init`, install a cron entry per `docs/setup.md`, walk away. Inspect `autometta status`, `state/state.yaml`, and the controller log in the morning.
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
├── bin/
│   └── autometta              # CLI wrapper over the shell scripts
├── docs/
│   ├── philosophy.md         # design philosophy, scope, non-goals
│   ├── dispatch-contract.md  # pass 1 - the contract
│   ├── verification.md       # pass 1 - the gate model
│   ├── lessons.md            # hard-won failure modes
│   ├── phat-controller.md    # pass 2 - the autonomous loop design
│   ├── setup.md              # pass 2 - operator setup guide
│   ├── deployment.md         # central install, manifests, submodule escape hatch
│   ├── observability.md      # status and attachable viewer model
│   ├── prior-art.md          # what was adopted and what was ignored
│   └── PUBLISH-WORKFLOW.md   # private dev / public publish branch model and gate
├── templates/
│   ├── stage-card.md         # one card per dispatch
│   ├── worker-prompt.md      # the prompt the worker reads
│   ├── verifier-prompt.md    # the prompt the verifier reads
│   └── orchestrator-checklist.md
├── scripts/                  # pass 2 runtime + observability: tick, spawn-worker, spawn-verifier,
│                             #   register-agent, heartbeat, watch-agent, agent-ticker, list-cards,
│                             #   install-launchagent, uninstall-launchagent, install-homebrew-local,
│                             #   install-guards, publish-guard git-hooks, status, attach, add-stage
├── packaging/                # local Homebrew formula template
├── schemas/                  # state.yaml + budget.json schemas
├── state/                    # per-repo runtime state (gitignored content)
├── memory/                   # cross-session agent memory (in-repo)
├── skills/                   # skills hosted by this repo
│   ├── agent-orchestrator/   # canonical home (mcp-hub copy is a symlink back)
│   └── autometta-setup/      # adopt the dispatch contract in another repo
└── examples/
    ├── fractals-stage-cards/ # real cards as illustrations
    ├── benchmarks/           # end-to-end benchmark runs (e.g. bench-005)
    └── self-host/            # the cards Autometta used to build itself
```

## Reading order

1. `docs/philosophy.md` - what we believe and why.
2. `docs/dispatch-contract.md` - the load-bearing document.
3. `docs/lessons.md` - five gotchas that will bite you on day one.
4. `templates/stage-card.md` and `templates/worker-prompt.md` - copy these, fill them in.
5. `docs/verification.md` - how to gate the worker's output.
6. `docs/phat-controller.md` and `docs/setup.md` - when you want to put the dispatch contract under cron. `docs/setup.md` section 7 covers auth-route configuration (subscription vs API key).
7. `docs/deployment.md` and `docs/observability.md` - when you want to adopt it across repos and watch the loop.

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

When the same loop is worth automating, install the local CLI and initialise the repo:

```sh
scripts/install-homebrew-local.sh
autometta init /path/to/target-repo
git -C /path/to/target-repo add .gitignore state/state.yaml state/budget.json
git -C /path/to/target-repo commit -m "Initialise Autometta"
autometta status
autometta attach /path/to/target-repo
```

Then follow `docs/setup.md` to put `autometta tick` under cron. Read `docs/deployment.md` first if the repo needs pinned provenance rather than the default central install.

## Updating an existing repo

For an already-subscribed repo such as `fractals-from-the-90s`, update the
installed Autometta CLI from this checkout, then check the subscriber:

```sh
cd /path/to/autometta
git pull --ff-only
scripts/install-homebrew-local.sh
autometta --version        # should match `git rev-parse --short HEAD`
autometta status
autometta attach /path/to/target-repo   # picks up the third tmux pane (agent ticker)
```

You do not normally rerun `autometta init` for the target repo unless its
subscription or local manifest is missing. The current local Homebrew path is a
rendered formula, so `brew update` alone is not enough; rerun
`scripts/install-homebrew-local.sh` after updating this checkout.

If the running orchestrator session was started before the upgrade, the
session's `$PATH`-resolved `autometta` and its child scripts are still
pinned to the old Cellar version. Re-source the shell or restart the
session after `install-homebrew-local.sh` to pick up new scripts
(`heartbeat`, `watch-agent`, `agent-ticker`, `install-launchagent`, etc.).

## Billing routes (subscription vs API key)

Every dispatched worker or verifier runs on either an OAuth subscription session (Claude Pro / ChatGPT plan) or an API key (`OPENAI_API_KEY` for Codex, `ANTHROPIC_API_KEY` for Claude). Resolver fallback (no manifest) is `subscription` for both; the shipped template recommends `codex: api` + `claude: subscription`. Flip per repo or per dispatch.

Aligned to the `auth-route-security` skill — every launch goes through `op-fetch`, which exec's the child via `env -i` plus an allowlist plus only the named refs. Subscription mode still goes through `op-fetch`, so any stray `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` in your parent shell is **stripped** rather than silently flipping you to API billing.

### Three files

```
op-refs.sh                                  # COMMITTED — placeholder op:// refs
op-refs.local.sh.example                    # COMMITTED — template
~/.config/autometta/op-refs.local.sh        # GITIGNORED — your real op:// references
```

`op-refs.sh` carries placeholders like `op://YOUR_VAULT/openai-api-key/credential`. Plant your real values at `~/.config/autometta/op-refs.local.sh`:

```sh
mkdir -p ~/.config/autometta
cp op-refs.local.sh.example ~/.config/autometta/op-refs.local.sh
chmod 600 ~/.config/autometta/op-refs.local.sh
# Then edit ~/.config/autometta/op-refs.local.sh with the real op:// refs.
```

**Why XDG rather than in-repo?** Two reasons. (1) The brew-installed CLI runs from a Cellar snapshot at `/opt/homebrew/Cellar/autometta/<sha>/libexec/` — it cannot see files inside your dev checkout. XDG is the one location both can read. (2) A single set of credentials is shared across every subscribed repo on the machine; XDG avoids duplicating them per-repo. `autometta auth status` always prints which file it actually loaded so you can verify the path in effect.

Resolution order: `$AUTOMETTA_LOCAL_REFS` env var, then `~/.config/autometta/op-refs.local.sh`, then `<repo>/op-refs.local.sh` (dev only — not visible to the brew install).

### Per-repo mode toggle

`.autometta.local.yaml` in the **subscribed repo** (gitignored under `*.local`) carries only the mode:

```yaml
auth:
  codex:
    mode: api          # subscription | api
  claude:
    mode: subscription
```

Dispatch-time override beats the manifest:

```sh
AUTOMETTA_CODEX_MODE=api  autometta tick
AUTOMETTA_CLAUDE_MODE=api autometta tick
```

### Verify before any dispatch

```sh
autometta auth status         # mode + ref provenance per family + op-fetch presence
autometta auth check codex    # resolves the ref via op-fetch --print, no token spend
autometta auth check claude
```

`auth check` returns `PASS` with a redacted credential, `subscription` (no key needed), or `FAIL` with the resolver error path. **Run this first** — the spawn fails closed on a missing `op-fetch`, unset `OP_REF_*`, or unresolved placeholder, but a fast probe is cheaper than discovering it mid-dispatch.

### Sibling CODEX_HOME (required for codex api mode)

Codex prefers `~/.codex/auth.json` over `OPENAI_API_KEY` from the env. Without isolation, the OpenAI key injected by op-fetch is silently overridden by your existing ChatGPT-mode auth and the dispatch still bills the subscription. One-time setup:

```sh
mkdir -p ~/.codex-api-only && chmod 700 ~/.codex-api-only
op-fetch --print "$OP_REF_OPENAI_API_KEY" | \
  CODEX_HOME=~/.codex-api-only codex login --with-api-key
```

The spawn scripts and the manual dispatch pattern both export `CODEX_HOME=$AUTOMETTA_CODEX_HOME` (default `~/.codex-api-only`) when codex is in api mode and pass it through op-fetch via `--pass CODEX_HOME`. They fail closed if the sibling is missing or has the wrong `auth_mode`. Claude has no equivalent — `claude -p` honours `ANTHROPIC_API_KEY` directly.

### How it dispatches (for agents picking this up cold)

- `scripts/auth-route.sh <family>` — emits the `NAME=$OP_REF_NAME` pair for op-fetch (or nothing for subscription).
- `scripts/spawn-worker.sh` and `scripts/spawn-verifier.sh` — source `op-refs.sh`, call `auth-route.sh`, then `op-fetch <pairs> -- codex exec ...` or `op-fetch <pairs> -- claude -p ...`. For codex+api they prepend `CODEX_HOME=...` and `--pass CODEX_HOME`.
- `op-fetch` (typically at `~/Scripts/op-fetch`) — resolves refs via the 1Password service-account token from `$OP_SERVICE_ACCOUNT_ENV` (default `~/.config/op/service-account.env`), then exec's the child with `env -i` + allowlist + named keys only. No biometric prompt; works under cron and the macOS LaunchAgent.

### What does NOT work

- Putting raw keys in `.autometta.local.yaml`. Only the mode goes there; refs go in `op-refs.local.sh`.
- Putting the SA token or any API key in a committed file. The publish-guard's pre-commit hook catches common patterns; `op-refs.local.sh`, `.env.local`, `*.local` are gitignored.
- Auto-injecting keys into the macOS LaunchAgent plist. The LaunchAgent invokes `op-fetch` at tick time; the SA token comes from `~/.config/op/service-account.env`. Keys never land in the plist.

## Known limitations

- **Unattended launchd runs (macOS) are unverified.** The loop dispatches fine interactively and via cron, but the per-repo launchd LaunchAgent path needs a fresh smoke test after the `AbandonProcessGroup` fix. Earlier, claude workers spawned by the tick under launchd could exit silently (0-byte log) when the tick process returned, because launchd reaped the worker's process group. The plist template now sets `AbandonProcessGroup`; re-run `autometta install-launchagent <repo>` to re-render and re-bootstrap, then confirm a worker survives a full tick cycle before relying on overnight runs.
- **No green end-to-end benchmark yet.** BENCH-005 drove the contract against a multi-stage Swift refactor; neither lane met the pass condition (see `examples/benchmarks/bench-005/`). A green benchmark on a non-trivial backlog is the next milestone.
- **Pre-alpha, single operator.** No SLA, no retry semantics beyond the budget FSM, one OAuth session per agent family.

## Feature status

| Feature | Status | Notes |
|---|---|---|
| Dispatch contract (pass 1) | shipped | Self-hosted through stage 6. |
| Agent observability | shipped | Registry, heartbeat, ticker, watch primitive. |
| Auth routing (subscription / API) | shipped | `op-fetch`, fail-closed, per-family toggle. |
| SDK verifier route + prompt caching | shipped | Claude family only (stages 15-16). |
| Worker handoff envelope | shipped | Sole worker completion signal (stage 17). |
| Autonomous loop (pass 2) | experimental | Unattended launchd path unverified; see Known limitations. |
| OpenAI SDK verifier route | planned | Card 28; codex parallel to the Claude route. |
| Per-role, per-family SDK transport matrix | design-only | Card 28; orchestrator portion gated on card 23. |
| Cloud-hosted orchestration | planned | Card 27; future phase. |

## Licence


MIT. See `[LICENSE](./LICENSE)`.
