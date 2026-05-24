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

Open an optional tmux viewer:

```sh
autometta attach
```

The tmux viewer has one pane for a status snapshot and one pane tailing the
latest controller log. It is an operator cockpit only. It must not dispatch
`autometta tick`, send commands to workers, or keep state that cannot be
reconstructed from the filesystem.

Preview the tmux commands without opening a session:

```sh
autometta attach --dry-run
```

## Design constraints

- No resident daemon.
- No database.
- No hidden IPC.
- No tmux dependency for the controller itself.
- No second source of truth beside `state.yaml` and `budget.json`.

If an append-only event log is added later, it should be treated as an operator
transcript. It must not become the state machine.
