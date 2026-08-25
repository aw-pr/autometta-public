# Autometta Operator Manual

This is the single operator reference for Autometta: what has shipped, every
`autometta` command, and the runbooks for driving the system end to end. It
links out to the deep design docs under `docs/` rather than duplicating them.

Autometta is a pattern library for headless agent orchestration on one machine.
It dispatches worker and verifier agents across two CLI families (Claude Code
and Codex CLI) in the same working tree, and uses cross-family verification:
one family checks the other's work. Pre-alpha. macOS and Linux only.

If you are new, read in this order: this manual for orientation, then
`docs/dispatch-contract.md` (the load-bearing document) and `docs/lessons.md`
(the gotchas) before your second dispatch.

---

## 1. What is delivered

Autometta ships in two layers plus an observability layer. All three are
shipped today and have been self-hosted against this repo.

### Layer 1 - Dispatch contract (pass 1)

The contract between an orchestrator session and a single worker for one unit
of work: stage card to worker prompt to sandbox boundary to acceptance command
to verifier handoff to commit. Driven by a human in an orchestrator session.

- Templates: `templates/stage-card.md`, `templates/worker-prompt.md`,
  `templates/verifier-prompt.md`, `templates/orchestrator-checklist.md`.
- Design: `docs/dispatch-contract.md`. Gate model: `docs/verification.md`.

### Layer 2 - Autonomous tick loop (pass 2)

A cron or launchd driven tick that reads `state/state.yaml`, dispatches one
worker and/or verifier, writes the next state, and exits. The budget file is
the only safety: a hard stop on bounded spend, with no retries or backoff.

- Runtime: `scripts/tick.sh`, `scripts/spawn-worker.sh`,
  `scripts/spawn-verifier.sh`, `scripts/budget.sh`.
- Housekeeping: `scripts/reap-worktrees.sh` collects run worktrees
  (`../<repo>-run-<stage>`) that no stage still needs, after every tick.
  Run it by hand with `--dry-run` to see what it would do.
- Schemas: `schemas/state.yaml.json`, `schemas/budget.json`.
- Design: `docs/tick-loop.md`. Operator setup: `docs/setup.md`.

The tick never moves `repo_root`'s HEAD. It snapshots state onto the
`autometta/state` ref with git plumbing rather than checking that
branch out, and it fast-forwards a base branch by moving the ref rather than
checking base out. Both used to run `git checkout` in the shared tree, which
put an operator commit on the wrong branch on 2026-08-23. See
`docs/tick-loop.md` section (j); `scripts/state-branch-smoke.sh` is the
offline proof, and it replays the race rather than arguing about it.

The loop sits on top of the dispatch contract and never bypasses it. You can
use the dispatch contract without the loop; you cannot use the loop without the
contract.

### Layer 3 - Agent observability

Catches silent agent deaths in both manual and loop dispatches.

- Per-agent liveness registry: `state/active-agents/<pid>.json`, written by
  `scripts/register-agent.sh`.
- Heartbeat watchdog: `scripts/heartbeat.sh` surfaces stalls and over-budget
  conditions to `state/heartbeat.json`. It never kills or retries; exit is
  always 0 so it cannot break a tick.
- tmux agent ticker: `scripts/agent-ticker.sh` (third pane of the
  `autometta-<repo>` viewer).
- Polling primitive: `scripts/watch-agent.sh` - a manual dispatch blocks on it
  until the agent exits cleanly (0), goes STUCK (2), or gets bad input (3).
- Design: `docs/observability.md`.

### Cross-cutting features shipped

- **Auth routing (subscription vs API key vs free).** Per-family billing route
  resolved per repo, with a fail-closed `op-fetch` path. See section 5 and
  `docs/setup.md` section 7.
- **SDK verifier route with prompt caching.** The Claude verifier can run via
  the Anthropic SDK instead of `claude -p`, with a cacheable static prompt
  block. `scripts/verify-sdk.py`, `scripts/sdk-cache-smoke.sh`,
  `schemas/verifier.json`, `scripts/validate-verifier-artefacts.sh`. Design:
  `docs/sdk-verifier.md`.
- **Worker handoff envelope.** The worker's structured completion signal,
  validated against `schemas/handoff-envelope.json` by
  `scripts/validate-handoff-envelope.sh`, written to `state/handoffs/`. It is
  the sole completion signal a worker emits. Design: `docs/handoff-envelope.md`.
- **Dashboard.** A static HTML dashboard regenerated from subscriber state.
  `scripts/dashboard.sh`, `scripts/aggregate-dashboard.sh`. See
  `docs/dashboard.md`.
- **Publish workflow.** A private `dev` line and a clean public `publish`
  line, with a fail-closed git gate and publish-guard hooks. See section 7 and
  `docs/PUBLISH-WORKFLOW.md`.
- **Local Homebrew install.** `scripts/install-homebrew-local.sh` renders a
  local tap from the working tree.

---

## 2. CLI command reference

The `autometta` CLI (`bin/autometta`) is a thin wrapper over the scripts in
`scripts/`. Run with no arguments to print usage. Every subcommand below maps
to one backing script.

| Command | What it does |
|---|---|
| `autometta --version` | Print the installed version (from `VERSION`, falling back to the git short SHA). |
| `autometta init-host` | One-time host setup: create the Autometta home (`~/.autometta` by default) and its subdirectories. |
| `autometta init [repo-path]` | Subscribe a repo and prepare it: runs `init-host`, subscribes the repo, and ensures a tmux viewer. Defaults to the current directory. Then review and commit the generated `.gitignore`, `state/state.yaml`, `state/budget.json`. |
| `autometta subscribe [repo-path]` | Subscribe a repo to the controller without the full init flow. Defaults to the current directory. |
| `autometta add-stage <repo-path> <stage-card-path>` | Append a stage to a subscribed repo's `state.yaml` from a stage card. |
| `autometta status` | Per-repo table: enabled flag, current stage, status, budget (ticks/failures), and the live process plus log path. Any stage whose run branch is still waiting to be merged into its base branch gets an `awaiting integration` line under the repo's row, naming the branch to merge. Reads each subscriber's `state.yaml` and `budget.json`. Requires `yq` and `jq`. `scripts/status.sh --repo <path>` narrows the table to one subscriber; the tmux status pane uses it so an attached dash shows the repo you attached to. |
| `autometta attach [repo-path] [--dry-run]` | Open or refresh the tmux viewer (`autometta-<repo>`): status ticker, work pane, and agent ticker. An interactive attach replaces an existing viewer so ticker script changes take effect. `--dry-run` prints what it would do. `--ensure` (used internally by `init`) creates the session only if absent. The `autometta-autometta` session opens on the repo-scoped fleet page for the autometta repo itself (window `repo`); its `status` window carries the ordinary per-repo ticker, and the fleet-wide page (every subscriber) is one window further on (`fleet`), reachable but never the landing view. A separate background job refreshes fleet `data.json` every 120 seconds. Orphaned viewers whose subscriber is disabled or gone are reported. |
| `autometta detach [repo-path\|--all]` | Remove one tmux viewer, defaulting to the current repo, or tear down every `autometta-*` viewer with `--all`. Other tmux sessions are never touched. |
| `autometta tick [--repair\|--reset-halt [--reset-tokens]]` | Run one tick across subscribers: read state, dispatch one worker and/or verifier, write next state, snapshot state onto `autometta/state`, sweep retention and stale run worktrees, exit. It never changes the branch checked out in a subscriber's own checkout. `--reset-halt` clears the halt flag and the counters that cause a halt (`clock_ticks_used`, `idle_ticks_used`, `consecutive_failures`); add `--reset-tokens` to clear `tokens_spent` and `wall_clock_elapsed_seconds` too. `--repair` requeues every stalled or failed stage across all enabled subscribers, via the same reset `scripts/requeue-stage.sh` performs by hand; it leaves `in_progress` and `verifier_failed` alone, refuses a stage whose card no longer resolves (`stall_marker: card_missing`), skips a repo still over a spend cap, and stops at `repair_attempts` 2 per stage (`AUTOMETTA_REPAIR_ATTEMPT_CAP`). |
| `autometta check-deps` | Verify required tooling is present (bash, git, jq, yq, tmux, the CLI families, op-fetch, etc.). |
| `autometta dashboard [--open]` | Regenerate the static dashboard under the controller home; `--open` opens it in the default browser. |
| `autometta failures (<repo-path>\|--fleet) [--json]` | Itemised failures history on demand: every terminal-status stage and every non-pass dispatch, with tokens lost. Moved out of the live ticker panes so they stop competing for space; `--fleet` covers every enabled subscriber instead of one repo. Reads the same aggregated JSON the pane it reports for reads, so the two never disagree. |
| `autometta install-launchagent <repo-path> [--interval N]` | macOS: install a per-repo launchd LaunchAgent that runs the tick on an interval (seconds). |
| `autometta uninstall-launchagent <repo-path>` | macOS: remove the per-repo LaunchAgent. |
| `autometta install-homebrew-local [--dry-run] [--tap owner/name]` | Render and install the local Homebrew tap from the working tree. Rerun after every `git pull` of this repo. |
| `autometta auth status` | Per-family table: mode (`subscription`, `api`, or codex-only `local`), provenance (env, manifest, default), and ref status. Also prints which `op-refs.local.sh` was loaded, whether `op-fetch` is on PATH, and the sibling `CODEX_HOME` state. No token spend. |
| `autometta auth check <codex\|claude>` | Probe one family without spending a token. `subscription` reports no-key-fetch; `api` resolves the ref via `op-fetch --print` and, for codex, checks the sibling `CODEX_HOME`; codex `local` runs the Ollama server/model preflight. Each route returns `PASS`, `FAIL`, or the explicit subscription result. |

Notes:

- The Autometta home is `$AUTOMETTA_HOME` (default `~/.autometta`). The old
  `$PHAT_CONTROLLER_HOME` spelling is a deprecated one-release fallback.
  Subscribers live in `<home>/subscribers/*.yaml`; tick logs in `<home>/log/`.
- After the one-time home migration, rerun `autometta install-launchagent
  <repo>` at a queue gap so the installed plist adopts the new working
  directory.
- `tick` halts the loop (writes `budget.json.halted = true`) on any cap or
  blocking condition rather than retrying. See section 4 for halt reasons.

---

## 3. Runbook - your first dispatch (pass 1, five minutes)

No `scripts/`, no `tick.sh`, no cron. This is the dispatch contract by hand.

1. Clone Autometta somewhere reachable from your target project.
2. In the target project, open an orchestrator session in Claude Code (or
   Codex CLI; the orchestrator role is family-agnostic).
3. Copy three templates into the target repo:
   ```sh
   mkdir -p stage-cards
   cp <Autometta>/templates/stage-card.md stage-cards/01-my-first-stage.md
   cp <Autometta>/templates/worker-prompt.md /tmp/worker-prompt.md
   cp <Autometta>/templates/orchestrator-checklist.md /tmp/checklist.md
   ```
4. Fill in `stage-cards/01-my-first-stage.md`: one objective, one deliverable,
   one acceptance command. Walk the checklist in `/tmp/checklist.md` as you go.
5. Dispatch a worker from the orchestrator session and give it the stage card
   path. The worker writes code; you run the acceptance command yourself; if it
   passes, fire a verifier in a different model family to audit the change.
   Commit on green.

Read `docs/dispatch-contract.md` for the full seven-step protocol and
`docs/lessons.md` for the gotchas before your second dispatch.

---

## 4. Runbook - the autonomous loop (pass 2)

When the same dispatch loop is worth automating, install the CLI and subscribe
the repo.

```sh
cd /path/to/autometta
scripts/install-homebrew-local.sh
autometta init /path/to/target-repo
git -C /path/to/target-repo add .gitignore state/state.yaml state/budget.json
git -C /path/to/target-repo commit -m "Initialise Autometta"
autometta status
autometta attach /path/to/target-repo
```

Author your stage cards and queue them:

```sh
autometta add-stage /path/to/target-repo stage-cards/02-next-stage.md
```

Put the tick under a heartbeat. On macOS, prefer the LaunchAgent (it has
Aqua-session keychain access, which cron lacks):

```sh
autometta install-launchagent /path/to/target-repo --interval 120
```

On Linux, use cron per `docs/setup.md`. Then walk away and inspect in the
morning with `autometta status`, `state/state.yaml`, and the controller log.

### State lifecycle

Each stage in `state/state.yaml` carries a `status`, one of:
`pending`, `in_progress`, `completed`, `failed`, `stalled`, `verifier_failed`.

On worker exit, the tick reads the handoff envelope and branches:

- envelope says pass: dispatch the verifier.
- envelope says fail or partial: mark the stage failed.
- no envelope written: stall with marker `worker_envelope_missing_after_exit`.
- envelope fails schema validation: stall with marker
  `worker_envelope_invalid` (the bad file is moved aside for inspection).

On a verifier FAIL, the stage is set to `verifier_failed`, `current_stage` is
cleared, and the working tree is left intact for operator review.

### Budget and halts

The budget file (`state/budget.json`) is the only safety. When a cap is hit the
tick writes `halted: true` with one of these canonical `halt_reason` values:

- `token-cap` - tokens spent reached the total cap.
- `wall-clock-cap` - wall-clock elapsed reached the cap.
- `tick-cap` - work ticks used reached `clock_tick_cap`. Only ticks that
  dispatched, reaped or supervised an agent count; a tick that found nothing
  to do charges `idle_ticks_used`, which halts nothing unless the optional
  `idle_tick_cap` is set.
- `idle-tick-cap` - idle ticks used reached `idle_tick_cap`, where one is set.
- `failure-cap` - consecutive failures reached `consecutive_failure_cap`.
- `dirty-working-tree` - tree was not clean when the tick tried to advance
  state (note: a worker is allowed to leave the tree dirty while
  `current_stage` is non-null; the halt only fires otherwise).
- `yq-missing` - the `yq` binary was not on PATH.
- `invalid-stage-id` - a stage id failed the id-format validator.

Clear a halt once you have fixed the cause:

```sh
autometta tick --reset-halt                  # clears the flag and the tick / failure counters
autometta tick --reset-halt --reset-tokens   # ... and the spend counters too
```

`--reset-halt` clears `clock_ticks_used`, `idle_ticks_used` and
`consecutive_failures` alongside the flag, because clearing the flag alone
left the counter that caused the halt in place and the next tick simply
re-halted. It will not zero `tokens_spent` unless you ask: that is real spend
against a real cap, not a polling artefact. If a spend cap is still over after
the counters are cleared, the halt stays latched against that cap and the
command says so, rather than unlatching the only safety for one tick and
letting you find out afterwards.

There is no retry, no exponential backoff, and no circuit breaker by design.
See `docs/tick-loop.md` for the full FSM and token accounting.

---

## 5. Auth routes (subscription vs API key vs free)

Every dispatched worker or verifier uses an OAuth subscription (Claude Pro /
ChatGPT plan), an API key, or the free local Ollama route for the codex family.
Resolver fallback with no manifest is `subscription` for both families. The
shipped template recommends `codex: api` + `claude: subscription`. Flip per
repo or per dispatch.

Every launch goes through `op-fetch`, which exec's the child via `env -i` plus
an allowlist plus only the named refs. Subscription mode still goes through
`op-fetch`, so a stray `OPENAI_API_KEY` or `ANTHROPIC_API_KEY` in your parent
shell is stripped rather than silently flipping you to API billing.

### Three files

```
op-refs.sh                                  # committed - placeholder op:// refs
templates/op-refs.local.sh.tpl                    # committed - template
~/.config/autometta/op-refs.local.sh        # gitignored - your real op:// refs
```

Plant your real values at the XDG location (mode 0600). The brew-installed CLI
runs from a Cellar snapshot and cannot see files inside your dev checkout; XDG
is the one place both can read, and it shares one credential set across every
subscribed repo:

```sh
mkdir -p ~/.config/autometta
cp templates/op-refs.local.sh.tpl ~/.config/autometta/op-refs.local.sh
chmod 600 ~/.config/autometta/op-refs.local.sh
# then edit it with the real op:// refs
```

Resolution order: `$AUTOMETTA_LOCAL_REFS`, then
`~/.config/autometta/op-refs.local.sh`, then `<repo>/op-refs.local.sh` (dev
only). `autometta auth status` always prints the file actually loaded.

### Per-repo mode toggle

`.autometta.local.yaml` in the subscribed repo (gitignored under `*.local`)
carries only the mode, never keys:

```yaml
auth:
  codex:
    mode: api          # subscription | api | local
  claude:
    mode: subscription # subscription | api
```

Dispatch-time override beats the manifest:

```sh
AUTOMETTA_CODEX_MODE=api  autometta tick
AUTOMETTA_CLAUDE_MODE=api autometta tick
```

### Sibling CODEX_HOME (required for codex api mode)

Codex prefers `~/.codex/auth.json` over `OPENAI_API_KEY` from the env. Without
isolation the injected OpenAI key is silently overridden by your ChatGPT-mode
auth and the dispatch still bills the subscription. One-time setup:

```sh
mkdir -p ~/.codex-api-only && chmod 700 ~/.codex-api-only
op-fetch --print "$OP_REF_OPENAI_API_KEY" | \
  CODEX_HOME=~/.codex-api-only codex login --with-api-key
```

The spawn scripts export `CODEX_HOME=$AUTOMETTA_CODEX_HOME` and pass it through
op-fetch via `--pass CODEX_HOME` when codex is in api mode, and fail closed if
the sibling is missing or has the wrong `auth_mode`.

### Verify before any dispatch

```sh
autometta auth status         # mode + ref provenance + op-fetch presence
autometta auth check codex    # resolves the ref via op-fetch --print, no spend
autometta auth check claude
```

The spawn fails closed on a missing `op-fetch`, an unset `OP_REF_*`, or an
unresolved placeholder. Full surface: `docs/setup.md` section 7 and the
`auth-route-security` skill.

### Free verifier tier: flip, read and identify

The measured default is the codex-family local route (`gpt-oss:120b`) for
mechanical-acceptance stages, with a frontier verifier retained for
judgement-heavy criteria. See `docs/verifier-bake-off.md` for the evidence.

**Flip a repo onto the free verifier route.** Install, start and populate
Ollama as described in `docs/setup.md` section 7, then set the repo's
gitignored `.autometta.local.yaml`:

```yaml
auth:
  codex:
    mode: local
```

For one dispatch, use `AUTOMETTA_CODEX_MODE=local autometta tick` instead.
There is no Claude-family local mode, and the measured cloud-free candidates
are available only through `scripts/verifier-bake-off.sh`, not as manifest
modes.

**Read a local verifier in the cost log.** Route and tier are independent.
`auth_route` comes from the auth resolver; `tier` comes only from the stage's
identity string (`scripts/cost-log.sh:212-215`, `scripts/rates.sh:40-59`). An
identity containing `GPT-OSS` maps to T5, whose rate row is zero
(`scripts/rates.sh:64-72`). A local route using a Terra, Sol or other identity
keeps that identity's tier and estimate; local mode does not rewrite it to T5.
Inspect all three facts together, including the actual tokens captured from
the role log:

```sh
jq -r 'select(.role=="verifier" and .auth_route=="local")
  | "\(.stage_id): identity=\(.identity) tier=\(.tier) tokens=\([.input_tokens,.cached_input_tokens,.output_tokens]|add) estimate=$\(.cost_usd_est)"' \
  state/cost-log.jsonl
```

For a correctly named local GPT-OSS verifier this prints `tier=T5` and
`estimate=$0`; the token total remains real and non-zero. Codex total-only logs
put the total in `input_tokens`, while routes with a full usage breakdown fill
all three buckets, so summing them works for both shapes. The checked-in
fixture behaviour is exercised by `scripts/cost-log-smoke.sh`.

**Identify a running verifier's route.** `autometta auth status` shows the
current per-family resolution from env override, repo manifest, then default,
which is the same precedence used at launch (`scripts/auth-route.sh`). For a
running codex verifier, `ps -p <pid> -o command=` identifies the local route by
`--oss --local-provider=ollama`; API and subscription both use `--model`
(`scripts/spawn-verifier.sh:338-362`). For Claude, the
`verifier-transport: cli|sdk` log line reports the harness, not the billing
route. CLI accepts subscription or API, while SDK requires API
(`scripts/spawn-verifier.sh:307-320,365-380`). The running-agent registry does
not expose a separate billing-route field, so for a Claude CLI verifier use
the launch-time auth resolution; after reap, read `auth_route` in its cost-log
line.

---

## 6. Observability

The observability layer plugs into both manual and loop dispatches. Any
dispatcher registers an agent; the heartbeat and ticker read that registry
without further coupling.

- **Register** a dispatched agent so the watchdog can see it:
  ```sh
  scripts/register-agent.sh <repo_root> <pid> <role> <family> <identity> <card> <log> [budget_secs] [working_dir]
  ```
  role is `worker` or `verifier`; family is `codex` or `claude`. Idempotent on
  the same pid; writes `state/active-agents/<pid>.json`. Dispatchers record the
  launch working directory so the ticker can identify the matching harness
  transcript without reconstructing a worktree path.

- **Heartbeat** walks `state/active-agents/`, checks liveness and budget, and
  writes `state/heartbeat.json`. It moves dead entries to `state/recent-agents/`
  with `outcome: exited`. It is a watchdog, not a gate.

- **Watch** a manual dispatch until it terminates or stalls:
  ```sh
  scripts/watch-agent.sh <repo_root> <pid> [label]
  ```
  Exit 0 = clean, 2 = STUCK (silent past the grace window), 3 = bad input.
  Tunable via `AUTOMETTA_WATCH_POLL` (default 60s) and
  `AUTOMETTA_WATCH_STALL_GRACE` (default 120s).

- **Viewer**: `autometta attach <repo>` opens the tmux session with a status
  ticker, a work pane, and the agent ticker (`scripts/agent-ticker.sh`). The
  ticker's ALERTS panel is the load-bearing FAIL signal; it reads `state.yaml`
  and the verifier artefacts. SPEND shows the current window against its token
  cap, today's and seven-day list-price estimates, today's mean cache-hit rate,
  and the last-hour token burn. ACTIVE reads bounded transcript increments for
  both families: summed Claude message usage and the latest cumulative Codex
  total. Missing transcripts say `waiting` or `unavailable`, never zero. The
  renderer measures the pane, keeps alerts and active work first, reports
  hidden counts, and repaints each completed frame in one write. Run
  `autometta detach --all` to tear down all viewers.

- **Fleet viewer**: `autometta attach /path/to/autometta` opens
  `autometta-autometta` landing on the repo-scoped fleet page for autometta
  itself (TOTALS and ESCALATIONS, no REPOS table). The fleet-wide page --
  every enabled subscriber, its operational state and why, queue depth,
  today's spend and spend against the cap that binds, plus one ESCALATIONS
  row per halted, paused, attempt-capped, stale-vendor or over-budget
  condition -- is a `tmux next-window` away, sourced from the same read-only
  dashboard `data.json`. Completed roles are excluded from provider-limit
  scans so source text and commit subjects cannot cry wolf. The itemised
  failures list and per-role spend breakdown are reachable with
  `autometta failures --fleet` rather than rendered live. A separate job
  reuses the existing aggregator every 120 seconds, while the ticker only
  reads the snapshot. The pane states the exact generation time and still
  labels genuinely stale data. Fleet, status and agent headers name the
  running `autometta <sha>`; a
  mismatch between the installed command and checkout HEAD is shown as build
  drift and rechecked at most once a minute.
  Override the refresh interval with `AUTOMETTA_FLEET_REFRESH_INTERVAL`.
  The control-plane repo's original three-pane view remains in the `repo`
  window.

A family asymmetry to remember: `claude -p` does not stream its log; the file
stays at 0 bytes until the run completes. So log-mtime staleness is not a stuck
signal for the claude family, only over-budget is. The heartbeat encodes this.
See `docs/observability.md`.

---

## 7. Publish workflow

Private development lives on `dev`; the clean public mirror lives on `publish`,
populated via clean topic-branch merges. A fail-closed git gate guards the
public push.

- Install the publish-guard hooks: `scripts/install-guards.sh`. The pre-commit
  hook blocks committing real `op://` refs and other configured patterns
  (`.publish-guard.local`).
- The public force-push goes through the gate with `PUBLISH_GUARD_OK=1` and
  `--force-with-lease`; never `--no-verify`.

Full model and the `git publish` flow: `docs/PUBLISH-WORKFLOW.md`. The
`repo-publish-workflow` and `repo-publish-guard-*` skills automate setup in
other repos.

---

## 8. Troubleshooting (the headless gotchas)

These are the failure modes that will bite you. Full write-up in
`docs/lessons.md`; the load-bearing ones are also in `CLAUDE.md`.

1. **Stdin hang.** `codex exec` reads stdin after the prompt arg. Always
   redirect `</dev/null` from any wrapping harness.
2. **Card-sync race across worktrees.** Verifier and worker must see the same
   card content; serialise writes.
3. **Opaque log paths.** Use predictable paths (`/tmp/codex-<stage>.log`), not
   harness-generated task ids.
4. **Sandbox shadows.** A worker that appears to pass acceptance inside its
   sandbox may be lying about side effects it could not perform. This is why
   the verifier always runs outside the worker sandbox.
5. **Prior-gate regression.** Re-running acceptance after a later change can
   surface a regression in an earlier stage.
6. **Claude logs do not stream.** `claude -p` writes its log in a single burst
   at completion. Log-mtime staleness is not a stuck signal for claude; only
   over-budget is.
7. **Claude autonomy flags.** `claude -p` needs `--dangerously-skip-permissions`
   to act autonomously. Combining `-p` with `--permission-mode bypassPermissions`
   exits silently with an empty log.
8. **Codex auth precedence.** Codex prefers `$CODEX_HOME/auth.json` over
   `OPENAI_API_KEY`. If `~/.codex/auth.json` is in chatgpt mode, an api-mode
   dispatch still bills the subscription unless you use the sibling
   `CODEX_HOME` (see section 5).

### Resolved

- **LaunchAgent silent worker exit (fixed, verified 2026-05-29).** Claude
  workers spawned via the tick under launchd used to exit silently (0-byte log)
  when the tick job returned: the background subshell received SIGHUP and
  launchd reaped the worker's process group. Two complementary fixes close it -
  `disown "$pid"` in the spawn scripts (shell job-control SIGHUP) and
  `AbandonProcessGroup` in the LaunchAgent plist (launchd group reaping). A real
  LaunchAgent smoke test confirmed a claude worker now survives the tick exit
  and runs to completion. See `docs/lessons.md` gotcha 9.

For the dated session log and the current backlog, see `HANDOFF.md` and
`stage-cards/PLAN.md`.

---

## Cross-reference index

| Topic | Document |
|---|---|
| Design philosophy, scope, non-goals | `docs/philosophy.md` |
| Dispatch contract (the seven steps) | `docs/dispatch-contract.md` |
| Verification / gate model | `docs/verification.md` |
| Autonomous loop design (FSM, accounting) | `docs/tick-loop.md` |
| Operator setup, cron, auth section 7 | `docs/setup.md` |
| Observability model | `docs/observability.md` |
| SDK verifier route + prompt caching | `docs/sdk-verifier.md` |
| Worker handoff envelope | `docs/handoff-envelope.md` |
| Dashboard | `docs/dashboard.md` |
| Deployment, manifests, submodule escape hatch | `docs/deployment.md` |
| Private/public branch model and gate | `docs/PUBLISH-WORKFLOW.md` |
| Hard-won failure modes | `docs/lessons.md` |
| Prior art - adopted vs ignored | `docs/prior-art.md` |
| Dated session log / handover | `HANDOFF.md` |
