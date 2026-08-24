# Observability

The tick loop needs an operator surface that answers four questions quickly:

1. Which repos are subscribed?
2. Which stage is active?
3. Is a worker or verifier still running?
4. Where is the log?

The observability layer is read-only. It observes files that already exist; it
does not supervise workers, retry stages, or create another controller loop.

## Authoritative surfaces

- `state/state.yaml`: current stage, stage statuses, worker/verifier identities,
  PIDs, verifier artefact path, tick metadata, halt fields.
- `state/budget.json`: spend caps, tick usage, failure counters, halt reason.
- `state/logs/<stage-id>-worker.log`: worker process log.
- `state/logs/<stage-id>-verifier.log`: verifier process log.
- `state/verifiers/<stage-id>.json`: structured verifier result.
- `state/active-agents/<pid>.json`: per-agent liveness registry, one file
  per dispatched worker or verifier currently in flight.
- `state/recent-agents/<pid>-<stage-id>.json`: completed agent runs,
  moved here by the heartbeat watchdog when the process exits.
- `state/heartbeat.json`: latest watchdog report (per-agent flags for
  `silent` log mtime, `over-budget`, etc.).
- `${AUTOMETTA_HOME:-$HOME/.autometta}/log/tick-YYYY-MM-DD.log`:
  controller-level tick log.
- `${AUTOMETTA_HOME:-$HOME/.autometta}/subscribers/*.yaml`:
  subscribed repos.
- `autometta/state`: git branch containing committed state snapshots.

`state.yaml` remains the source of truth. Logs are evidence, not state.

## Commands

Print the current controller status:

```sh
autometta status
```

`autometta init <repo>` creates the tmux viewer automatically when `tmux` is
available. Each `autometta tick` also re-ensures the viewer per repo it
processes, so a killed session reappears on the next tick and a freshly
subscribed repo gets one as soon as the loop touches it. The check is a
no-op when `tmux` is not on `PATH`, and a no-op when the session already
exists. The session is named from the repository basename:

```text
autometta-<project-name>
```

For example, a repo called `fractals-from-the-90s` gets
`autometta-fractals-from-the-90s`.

Open or create the viewer manually:

```sh
autometta attach <repo-path>
```

The per-repo tmux viewer has three panes: the left pane prints a status snapshot, the
top-right pane tails the latest controller log, and the bottom-right pane
runs the **agent ticker** (`scripts/agent-ticker.sh`). The ticker refreshes
every five seconds (override with `AUTOMETTA_TICKER_INTERVAL`) and
shows these sections:

- `ALERTS`: shown only when something needs attention. Budget halts,
  consecutive failures, stages in a terminal-failure state, and an **empty
  queue on an enabled subscriber** (zero pending and nothing in flight).
- `SPEND`: current-window tokens against the cap, today's and seven-day USD
  estimates at list prices, today's mean cache-hit rate, and tokens burned in
  the last hour. It reads at most the final
  `AUTOMETTA_COST_LOG_TAIL_ROWS` rows (default 5,000), so refresh cost is
  bounded as the append-only ledger grows. Token figures remain the primary
  signal on subscription routes.
- `ACTIVE`: each agent currently in flight, with flags from the heartbeat
  watchdog (`fresh` / `silent` / `over-budget`) and an in-flight token total
  from that agent's harness transcript. Claude message usage is summed
  incrementally from a persisted byte offset; Codex uses the latest cumulative
  `total_token_usage`. A transcript that has not appeared says `waiting`, and
  a genuine miss says `unavailable`; an empty Claude log never becomes a
  misleading zero.
- `LIVE`: only while a stage is genuinely `in_progress` — the last eight
  lines of `state/logs/<stage>-worker.log`, so the running worker's output
  is in the pane rather than behind a path the operator has to go and find.
  A `claude -p` worker writes nothing until it exits and then emits the
  whole log at once (`docs/lessons.md` gotcha 6), so the panel says the log
  is empty rather than leaving a blank that reads as a stalled worker.
- `RECENT`: the last five completed agents with their outcomes, dropping
  anything older than `AUTOMETTA_RECENT_MAX_AGE_DAYS` (default 7)
  first. `ACTIVE` and `SCHEDULED` were already time-scoped; `RECENT` was
  the outlier, and a repo idle for months showed two-month-old runs as
  though they were current.
- `SCHEDULED`: queue depth as a number, pending and in flight, followed by
  the stages themselves, from `scripts/list-cards.sh`.

The ticker measures its terminal on every frame. At 39 columns by 15 rows it
keeps alerts and active agents first, folds lower-priority panels, and names
every hidden count. It builds the complete frame before one cursor-home write,
so refresh does not expose a cleared or half-drawn pane. The status ticker uses
the same repaint rule and switches `status.sh` to a compact two-line repo row
below 80 columns; direct full-width `autometta status` output is unchanged.

All three viewer headers include `autometta <sha>`. Installed-build drift is
checked at start-up and no more than once a minute. Until the installed-build
authority helper ships, the viewer labels its fallback comparison of
`autometta --version` with the checkout HEAD.

`list-cards.sh` treats `state/state.yaml` as authoritative for every card it
records, because that is the file the controller dispatches from. `PLAN.md`
and `state/recent-agents/` are consulted only for cards `state.yaml` has never
seen. A card on disk that has never been queued is labelled `unqueued`, which
is deliberately not the same word as `pending`: it is a real and useful
category, but it is not queue depth.

The distinction is what the panel got wrong. It used to classify a card as
done only from `examples/self-host/PLAN.md`, which is autometta's own file and
exists in no other subscriber, so every card in a subscriber's `docs/stages/`
read `pending` forever. On 2026-08-23 the ticker showed `emergence-lab` with
sixteen pending stages against a `state.yaml` recording 31 completed, 3
verifier-failed, 2 stalled and not one pending: an empty queue displayed as a
full one, while the overnight windows came up dead. Queue depth is therefore
printed as a number whether or not it is zero, and zero raises an alert.

Both panes on the left and top-right are scoped to the attached repo:
`scripts/status.sh --repo <path>` narrows the status table to one
subscriber, and the log pane filters the shared tick log to lines naming
that repo's path.

`autometta-autometta` is the fleet viewer. Its default `fleet` window renders
only `${AUTOMETTA_HOME}/dashboard/data.json`, which is produced by the
existing dashboard aggregator. It shows every enabled subscriber, halt reason,
queue depth, today's tokens and estimated cost, shortened window spend, last
dispatch and fleet totals. The alert union is a stable table with repo,
stage/card, kind and detail columns; repo-level conditions say `repo` in the
stage/card column. Completed worker handoffs and verifier artefacts prevent
source text or commit subjects about rate limits from becoming provider-limit
alerts.

A separate tmux background job runs the existing dashboard aggregator every
`AUTOMETTA_FLEET_REFRESH_INTERVAL` seconds (default 120). The ticker
continues to read only `data.json`, so there is still one fleet walker. It
prints the snapshot's exact generation time and age. A missing snapshot or one
older than `AUTOMETTA_FLEET_STALE_SECONDS` (default 600) is labelled
missing or stale rather than healthy. The `repo` window preserves autometta's
own per-repo view. Interactive `autometta attach` refreshes its viewer so
long-running ticker loops pick up script changes; `autometta detach --all`
removes all `autometta-*` viewers and nothing else. Attach also reports viewers
whose subscriber is disabled or absent.

It is an operator cockpit only. It must not dispatch `autometta tick`, send
commands to workers, or keep state that cannot be reconstructed from the
filesystem.

## Per-agent liveness registry

Every worker or verifier dispatched through `spawn-worker.sh` or
`spawn-verifier.sh` registers itself into `state/active-agents/<pid>.json`
at dispatch time. The registry entry records pid, role, family, identity,
card path, log path, start time, and parsed budget. Manual orchestrator
dispatches (`codex exec` / `claude -p` launched directly by an orchestrator
session) can join the registry by calling `scripts/register-agent.sh`
explicitly.

`scripts/heartbeat.sh` is invoked once per repo per tick. It walks the
active-agents registry and writes `state/heartbeat.json` with one entry per
agent, flagged for log-mtime staleness (default threshold 300 seconds;
override with `AUTOMETTA_HEARTBEAT_STALL`) and budget overrun. The
`silent` flag is only applied to agents whose family streams its log; for
the `claude` family, `claude -p` emits its entire log at completion and is
legitimately silent for the whole run, so only `over-budget` is a stuck
signal in that direction. This makes the registry symmetric across the
worker / verifier pairing: codex-worker / claude-verifier and the reverse
both get accurate stuck-detection without false positives. Dead
processes are moved to `state/recent-agents/` with `outcome: exited`. The
watchdog never kills; it surfaces.

The heartbeat surface answers the "is this stuck?" question that
`state.yaml` does not — `state.yaml` reflects the FSM, the heartbeat
reflects the process.

## Polling primitive: `watch-agent.sh`

The heartbeat writes findings to a file; somebody has to read it. For
orchestrator-led manual dispatches (a `codex exec` or `claude -p`
launched directly from an interactive session, outside the tick loop
loop), `scripts/watch-agent.sh` blocks until the dispatched agent terminates
or stalls past a grace window. Use it after registering the agent:

```sh
codex exec -C "$repo" --sandbox workspace-write "$(cat prompt.txt)" \
  </dev/null >log.txt 2>&1 &
pid=$!
disown
scripts/register-agent.sh "$repo" "$pid" worker codex \
  "GPT-5.6 Sol <gpt-5-6-sol@local>" "$card" log.txt 3600
scripts/watch-agent.sh "$repo" "$pid" "stage-NN-worker"
```

Defaults: poll every 60s (`AUTOMETTA_WATCH_POLL`), escalate to STUCK
120s after the heartbeat first flags `silent` (`AUTOMETTA_WATCH_STALL_GRACE`).
Exit codes: `0` clean exit, `2` STUCK, `3` bad input. The watcher itself
never kills the agent — it returns a non-zero exit so the caller can
decide.

For the autonomous loop, the heartbeat is invoked once per tick and the
loop already polls process liveness via `kill -0`; the watcher is the
manual-dispatch equivalent of "the loop saw your agent finish".

Preview the tmux commands without opening a session:

```sh
autometta attach <repo-path> --dry-run
```

## Hygiene: idle dashes and retention

`tick.sh` does its own housekeeping. None of it is a gate: every sweep is
best-effort and silent, and a failure never stops a tick.

**Idle dash reaper.** `ensure_tmux_viewer` only fires when `current_stage`
is non-null, and stamps `dash_active_at` in `budget.json` when it does. It
runs *after* the tick's dispatch decision, so a stage that goes pending to
`in_progress` in this same tick gets its dash immediately rather than a
tick late. `reap_idle_dash_sessions` then kills any `autometta-<slug>`
session whose subscriber is disabled, whose slug matches no subscriber at
all, or whose `dash_active_at` is older than
`AUTOMETTA_DASH_IDLE_HOURS` (default 24). An operator who is actually
attached always wins: a session with `tmux list-clients` output is never
reaped. `last_tick_at` and `tick_count` advance on every tick regardless of
dispatch, which is why `state.yaml`'s mtime cannot serve as the idle signal
and `dash_active_at` exists.

`session_slug()` lives in `scripts/session-slug.sh` and is sourced by both
`attach.sh` (which builds the session name) and `tick.sh` (which has to
reverse-match a live session name back to a subscriber). One definition, or
the spawner and the reaper drift and the reaper starts killing sessions it
cannot account for.

**Retention.**

| What | Default | Override |
|---|---|---|
| `~/.autometta/log/tick-*.log` deleted | 14 days | `AUTOMETTA_LOG_RETENTION_DAYS` |
| `state/recent-agents/*.json` deleted | 30 days | `AUTOMETTA_RECENT_AGENT_RETENTION_DAYS` |
| `state/logs/*.log` gzipped, never deleted | 30 days | `AUTOMETTA_WORKER_LOG_GZIP_DAYS` |

Worker and verifier logs are the audit trail, so they are compressed rather
than removed. One consequence worth knowing: `budget_account_tokens_from_log`
and the limit-refusal detector read the plain `.log` path, so a stage
requeued more than 30 days after its last run finds its old log gzipped and
logs "worker missing" instead of charging tokens twice. That is the intended
direction of the error, but it is why the gzip threshold should stay well
above any plausible stage turnaround.

Stale run worktrees (`<repo>-run-<stage>`) are swept by
`scripts/reap-worktrees.sh`, which `sweep_repo_retention` calls after every
tick. Card 33 recorded that nothing collected a worktree left behind by a
stage that neither completed nor was re-queued; card 39 is that reaper.

It removes a worktree only when its stage is finished with it, and the
removal itself goes through `requeue-stage.sh --worktree-only` so there is
one implementation of it rather than four. It leaves standing, and reports:

| Condition | Why it stays |
|---|---|
| stage is `in_progress` | a live worker owns the tree |
| uncommitted work, other than the known `state/` symlink | on a verifier FAIL the worker's diff is uncommitted by design, and it is the whole of what the operator inspects |
| run branch holds commits not on the base branch | the stage passed but base had moved, so this is the only local copy of that commit; recorded as `integration.state: awaiting` |
| no such stage in `state.yaml` | something else made it |

A reported worktree is reported again on every tick until someone deals with
it. `autometta status` prints an `awaiting integration` line for each stage
in the third case, which is the one that needs a person rather than a
deletion. Run the reaper by hand with `--dry-run` to see what it would do.

## Design constraints

- No resident daemon.
- No database.
- No hidden IPC.
- No tmux dependency for the controller itself.
- No second source of truth beside `state.yaml` and `budget.json`.

If an append-only event log is added later, it should be treated as an operator
transcript. It must not become the state machine.
