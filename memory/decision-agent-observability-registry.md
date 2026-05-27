---
name: decision-agent-observability-registry
description: Per-agent liveness registry at state/active-agents/, a heartbeat watchdog, and a tmux agent ticker — observability for the dispatch contract that does not depend on the autonomous loop driving the dispatch.
metadata:
  type: project
---

Card 13 added three things on top of the dispatch contract:

1. A per-agent liveness registry at `state/active-agents/<pid>.json` written
   by every dispatched worker or verifier. The registry entry records pid,
   role, family, identity, card path, log path, start time, and parsed budget.
2. A heartbeat watchdog at `scripts/heartbeat.sh` invoked once per repo per
   tick. It checks process liveness, log-mtime staleness (default 300s), and
   budget overrun. Findings are written to `state/heartbeat.json`. Dead
   entries are moved to `state/recent-agents/` with `outcome: exited`.
3. A tmux agent ticker (`scripts/agent-ticker.sh`) tailed in a third pane of
   the `autometta-<repo>` session, showing ACTIVE / RECENT / SCHEDULED.

**Why:**

- The card 12 verifier dispatch died silently — `--permission-mode` flag
  conflict with `-p` produced an empty log and an exited process. The
  orchestrator only noticed when the operator asked. The watchdog and the
  ticker exist so the next silent death surfaces within one tick.
- Registration is per-agent and at-dispatch-time rather than centrally
  pulled. Agents may be dispatched by `spawn-worker.sh`, by an
  orchestrator-internal `codex exec` / `claude -p` (as on card 12), or by a
  future MCP path. Pulling would force every dispatcher to announce itself
  to a central process; pushing means each dispatcher writes one file. The
  central watchdog reads files. This keeps the filesystem-as-message-bus
  invariant from `docs/philosophy.md` intact.
- The heartbeat surfaces; it does not kill. The operator decides. Killing
  on stall would conflict with the "budget file, not retries" invariant —
  a stall is a budget signal, not a control signal.

**How to apply:**

- New dispatchers must call `scripts/register-agent.sh` after backgrounding
  the agent. `spawn-worker.sh` and `spawn-verifier.sh` already do.
- Manual orchestrator dispatches that bypass the spawn scripts should also
  call `register-agent.sh` directly, with `family=codex|claude`, the right
  identity string (matching the canonical agent table), the card path and
  log path. The ticker will then pick them up.
- The default stall threshold is 300 seconds. Override per-host with the
  `PHAT_CONTROLLER_HEARTBEAT_STALL` environment variable.
- The ticker refresh interval defaults to 5 seconds. Override with
  `PHAT_CONTROLLER_TICKER_INTERVAL`.

Cross-reference: [[decision-phat-controller-no-daemon-subscriber-registry]],
[[decision-loop-name-phat-controller]],
[[decision-state-dir-per-repo]],
[[decision-orchestrator-commits-on-verifier-pass]].
