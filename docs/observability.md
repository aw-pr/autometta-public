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
  `silent` log mtime, `over-budget` and `token-outlier`, plus the recent
  per-role token baselines).
- `state/quota-window.json`: the tick's latest sanitised provider-window
  reading. It carries only source, fetch time and window labels, utilisation
  and reset times. It never carries a publisher payload or credential.
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

### What an operator now has

- **`autometta status`** is the quickest fleet snapshot when one command and no persistent screen is enough.
- **The tickers** open through `autometta attach <repo>` and suit a passive watch of one repo, its controller log, or the fleet page.
- **`autometta tui <repo>`** is the detailed live view for the current run, card history and a conversation with phat-controller.
- **`autometta failures <repo>`** (or `--fleet`) is the reach-for surface when the question is what failed, how often and what it cost.
- **The HTML dashboard** from `autometta dashboard --open` is the broad fleet and trend view when a browser is more useful than a terminal.
- **The controller inbox** is the asynchronous instruction path when phat-controller should consider something on its next pass without an attached session; the TUI messages page is its operator-facing writer.

The HTML dashboard renders both times in its header in the browser's local
timezone, so its generation time and freshness clock can be compared directly.
The aggregator still writes `generated_at` to `data.json` as a UTC ISO stamp;
hover over the generation time in the header to see that full UTC value.

The TUI has run, history and messages pages. On the run page the number row
focuses a panel, matching the `[0]`-`[4]` labels the boxes carry; on the other
two, where no numbered panels are drawn, it switches page as the footer's tab
strip says, and escape returns to the run page from anywhere. Focus `0` is the
card detail pane, which carries the stage card under the metadata and scrolls
with `j`/`k`; `o` pages that card read-only in a tmux window, and `O` opens it in
the desktop's default viewer, which can usually write to it. Enter on an
escalation opens the controller composer already carrying the stage and the
reason it stopped.

The `[3] Agents` panel shows live agents followed by the queued next stages.
Queued rows come from the aggregate payload's `queue` field and are display-only;
the cursor remains confined to live agents.

It polls the same
`aggregate-dashboard.sh --repo` seam as the repo ticker every five seconds,
but does so on a background thread so input remains responsive during a read.
The footer clock and adjacent pulse advance once per second between those
polls. They prove that the TUI renderer is alive, not that the tick loop is
running or that its data is fresh. A still pulse means the TUI process itself
is wedged; tick health remains visible through the dashboard's state and
freshness readings.
Card 74 replaced per-row process forks and repeated file scans in that seam,
taking the measured per-repo read from 37 seconds to under one second; a
five-second poll now represents a fresh snapshot rather than a queue of stale
ones. Its messages page is the narrow exception to the read-only display
model: it writes only an operator message to the controller inbox, then reads
the journal and outbox back from the filesystem.

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

The per-repo tmux viewer has two windows. The `repo` window is one pane, one
process, one repo: **the repo ticker** (`scripts/repo-ticker.sh`, card 63),
which owns the whole window rather than sharing it with a status pane and a
log pane the way it used to. That older three-pane layout squeezed the ticker
into whatever fraction of the terminal the right-hand column happened to get
— a 119-column pane routinely truncated a stage id to roughly 40 columns —
and it mixed a status table, a log tail and an agent ticker that could not
see each other's space. The `log` window (`tmux next-window`, or `autometta
attach <repo>` then switch windows) still tails the latest controller log
filtered to lines naming the attached repo's path; it is one keystroke away
rather than a quarter of the screen next to the ticker.

The repo ticker reads exactly one source: `scripts/aggregate-dashboard.sh
--repo <path>`, re-run on every refresh (every five seconds, override with
`AUTOMETTA_TICKER_INTERVAL`) so the figures are as fresh as the render and
scoped to that one subscriber — no other repo's data can appear in the frame.
It answers one question, "do I need to intervene?", in five sections:

- `NOW`: the live stage, in full — stage id, phase (`worker running` /
  `verifying` / `landing` while a passed stage awaits integration), the
  acting family and identity, elapsed against the card's declared
  wall-clock budget, tokens spent on the stage so far, and, while verifying,
  the attempt count against the cap. Elapsed against budget is real time
  spent, not work done, and never clamps at 99% or 100% — a stage past its
  budget reads `OVER BUDGET` with the true percentage. When nothing is
  live, it reads `idle`.
- `NEXT`: a counts line (stages done, outstanding, and how many of those are
  escalated), then the next few queued stages with the family that will
  work each.
- `ESCALATIONS`: only what is waiting on a human right now: a halt or pause
  with its reason, and any stage sitting in `stalled` or `verifier_failed`
  (not `failed`; see `scripts/alert-statuses.sh`, the one definition every
  renderer in the tree shares) with its preserved `wip_branch` pin. A
  re-queued stage is back to `pending` and so is correctly absent. A live
  `token-outlier` heartbeat flag also appears here with the current token
  figure and its multiple of that role's median. The whole section, header
  included, renders nothing when there is nothing outstanding.
- `SPEND AND LOSS`: tokens and estimated cost spent today, lost today
  (non-pass dispatch spend), lost over the last seven days, and the
  resolved cap (drain, this repo's own, or the host default) with percent
  used. Carries a caveat when a codex/GPT dispatch in the last seven days
  recorded `output_tokens: 0` against non-zero input — the currency figure
  for those rows undercounts until card 59 lands.
- `FRESHNESS`: how long since the last tick, plainly, and loud
  (`AUTOMETTA_TICK_FRESHNESS_THRESHOLD`, default 1200s) past the threshold.

Column widths are allocated the way lazygit does: each declares a minimum and
a share of the remainder, and columns marked droppable drop lowest-priority
first when the width will not hold them all — never truncation by the
terminal, never a fixed 40-column guess. The itemised failures list moved out
of the live pane entirely: `scripts/failures-history.sh <repo-path>`
(`autometta failures <repo-path>`) prints every terminal-status stage and
every non-pass dispatch on demand, reading the same one aggregated JSON so it
never disagrees with the ticker's SPEND AND LOSS totals.

`scripts/agent-ticker.sh` and `scripts/status-ticker.sh` (the ALERTS / SPEND /
ACTIVE / LIVE / RECENT / SCHEDULED ticker and the status-plus-COMPLETED pane
they replace) still exist and are still exercised by their own smoke tests,
but neither is wired into `autometta attach` any longer. Their `SPEND` panel
is the one place that still shows each family's most-used provider window and
reset time, or an explicit unknown reason.

Both windows are scoped to the attached repo: `aggregate-dashboard.sh --repo`
walks only that one subscriber, and the log window filters the shared tick
log to lines naming that repo's path.

`list-cards.sh` treats `state/state.yaml` as authoritative for every card it
records, because that is the file the controller dispatches from. `PLAN.md`
and `state/recent-agents/` are consulted only for cards `state.yaml` has never
seen. A card on disk that has never been queued is labelled `unqueued`, which
is deliberately not the same word as `pending`: it is a real and useful
category, but it is not queue depth.

`autometta-autometta` is the fleet viewer, and card 66 applied card 63's
"fits its pane" discipline to it. It has four windows: `repo` (the landing
window, `attach.sh --fleet-ticker <path>` scoped to the autometta repo
itself), `status` (the ordinary per-repo ticker every subscriber gets), `fleet`
(the fleet-wide page, every enabled subscriber) and `log`. Landing on the
fleet-wide page by default was the wrong default for a session that is
already scoped to one repo — "I rarely if ever will want a fleet view"
(operator feedback, 2026-08-25) — so window 0 is the repo-scoped page and the
fleet-wide page is one `tmux next-window` away, never the first thing an
operator sees.

The fleet page (`scripts/lib/fleet-ticker-render.py`, the sibling of the repo
ticker's renderer) reads only `${AUTOMETTA_HOME}/dashboard/data.json`, the
existing dashboard aggregator's output, or a single repo object from
`aggregate-dashboard.sh --repo` when scoped. Fleet-wide it shows TOTALS
(enabled repos, today's tokens and cost, window spend against cap), REPOS
(one row per subscriber: name, operational state with its reason, queue
depth, today's spend, and spend against the cap that binds), and ESCALATIONS:
every halted, paused, attempt-capped or stale-vendor repo, every stage in an
alert status, every over-budget live agent, and every provider-limit alert
younger than 24 hours — one row each, repo/result/stage/role/identity
rendering whole and a trailing detail column carrying the ellipsis budget. A
repo with nothing outstanding earns no ESCALATIONS row. Scoped to one repo,
REPOS is dropped entirely (that repo's row would be the whole page's
subject; the other rows are the fleet view's business) and TOTALS narrows to
that repo's own figures. The itemised failures list and the per-role spend
breakdown moved to `scripts/failures-history.sh --fleet`
(`autometta failures --fleet`), the fleet-wide sibling of the per-repo command
card 63 shipped.

A separate tmux background job runs the existing dashboard aggregator every
`AUTOMETTA_FLEET_REFRESH_INTERVAL` seconds (default 120), feeding the
fleet-wide window; the repo-scoped landing window re-runs
`aggregate-dashboard.sh --repo` on every frame instead, the same as any other
subscriber's `status` window. The page prints the snapshot's exact generation
time and age. A missing snapshot or one older than
`AUTOMETTA_FLEET_STALE_SECONDS` (default 600) is labelled missing or stale
rather than healthy. Interactive `autometta attach` refreshes its viewer so
long-running ticker loops pick up script changes; `autometta detach --all`
removes all `autometta-*` viewers and nothing else. Attach also reports viewers
whose subscriber is disabled or absent.

It is an operator cockpit only. It must not dispatch `autometta tick`, send
commands to workers, or keep state that cannot be reconstructed from the
filesystem.

## Provider-window readings

`scripts/quota-window.py` is the single reader. At the start of a tick fire it
reads both families once and `tick.sh` passes the sanitised JSON to every
subscriber as `state/quota-window.json`. The tmux pane and web dashboard read
that file; they do not start their own pollers.

The published snapshot contract is one file per family at
`${AI_QUOTA_DIR:-$HOME/.local/state/ai-quota}/<family>.json`:

```json
{
  "fetched_at": "2026-08-25T09:30:00Z",
  "source": "publisher-name",
  "windows": [
    {"key": "five_hour", "label": "5-hour", "utilization": 72.5,
     "resets_at": "2026-08-25T12:10:00Z"}
  ]
}
```

For Claude, the reader consumes `claude.json`. Autometta makes no network
request and reads no credential or Keychain entry. The publisher controls its
own cadence; the current panel polls the upstream source about every five
minutes. Autometta's default staleness bound is ten minutes
(`AI_QUOTA_STALE_SECONDS`). Only the contract fields above are propagated;
unknown or extra fields are discarded.

For Codex, the same reader may inspect local rollout JSONL because that source
is not rate limited. It uses the newest local `rate_limits` event and exposes
the same window shape. An absent, malformed or stale Claude snapshot, or
missing Codex rollout evidence, is `unknown` with a reason. Unknown is not zero
utilisation: it is logged, displayed legibly and always fails open, so it costs
the tick no dispatch and does not pause the queue.

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
override with `AUTOMETTA_HEARTBEAT_STALL`), budget overrun and unusual live
token spend. The
`silent` flag is only applied to agents whose family streams its log; for
the `claude` family, `claude -p` emits its entire log at completion and is
legitimately silent for the whole run, so only `over-budget` is a stuck
signal in that direction. This makes the registry symmetric across the
worker / verifier pairing: codex-worker / claude-verifier and the reverse
both get accurate stuck-detection without false positives. Dead
processes are moved to `state/recent-agents/` with `outcome: exited`. The
watchdog never kills; it surfaces.

For token spend, the heartbeat reads the running family transcript once at
the heartbeat cadence. It compares the live total with the median of the last
ten comparable cost-log rows for the same role. At least five rows are needed
and the default warning point is ten times the median. `usage_status: unknown`
and null totals do not enter the baseline. The report carries the baseline,
sample size, live figure and multiple, while the warning is written to the
controller tick log and shown in the repo ticker's `ESCALATIONS` section. It
does not change state-machine status, budget state or process liveness.

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
