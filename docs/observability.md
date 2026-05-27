# Observability

`phat-controller` needs an operator surface that answers four questions quickly:

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
- `${PHAT_CONTROLLER_HOME:-$HOME/.phat-controller}/log/tick-YYYY-MM-DD.log`:
  controller-level tick log.
- `${PHAT_CONTROLLER_HOME:-$HOME/.phat-controller}/subscribers/*.yaml`:
  subscribed repos.
- `phat-controller/state`: git branch containing committed state snapshots.

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

The tmux viewer has three panes: the left pane prints a status snapshot, the
top-right pane tails the latest controller log, and the bottom-right pane
runs the **agent ticker** (`scripts/agent-ticker.sh`). The ticker refreshes
every five seconds (override with `PHAT_CONTROLLER_TICKER_INTERVAL`) and
shows three sections:

- `ACTIVE`: each agent currently in flight, with flags from the heartbeat
  watchdog (`fresh` / `silent` / `over-budget`).
- `RECENT`: the last five completed agents with their outcomes.
- `SCHEDULED`: stage cards classified as `in_flight | pending`, derived
  from `manifest_patterns` and the PLAN.md status table.

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
override with `PHAT_CONTROLLER_HEARTBEAT_STALL`) and budget overrun. Dead
processes are moved to `state/recent-agents/` with `outcome: exited`. The
watchdog never kills; it surfaces.

The heartbeat surface answers the "is this stuck?" question that
`state.yaml` does not — `state.yaml` reflects the FSM, the heartbeat
reflects the process.

Preview the tmux commands without opening a session:

```sh
autometta attach <repo-path> --dry-run
```

## Design constraints

- No resident daemon.
- No database.
- No hidden IPC.
- No tmux dependency for the controller itself.
- No second source of truth beside `state.yaml` and `budget.json`.

If an append-only event log is added later, it should be treated as an operator
transcript. It must not become the state machine.
