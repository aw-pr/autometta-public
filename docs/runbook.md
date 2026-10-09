# Operator runbook

This is the shortest safe route from a fresh clone to an overnight queue, then
the daily loop for an installed fleet. It assumes macOS or Linux, both CLI
families installed, and one human operator. Use the linked documents for
choices and exceptions rather than extending this runbook.

## Cold start

1. Install the local CLI from the Autometta checkout, then confirm the host has
   the required commands. See [setup](setup.md#1-prerequisites) for platform
   requirements.

   ```sh
   scripts/install-homebrew-local.sh
   autometta check-deps
   ```

2. Create the controller home once on this machine. It is safe to repeat; see
   [machine setup](setup.md#2-one-time-machine-setup).

   ```sh
   autometta init-host
   ```

3. Choose the subscription, API, or local Codex route, then verify both
   families before any dispatch. Put real references only in the gitignored
   local file described in [auth routes](setup.md#7-auth-routes-subscription-api-key-and-free).

   ```sh
   autometta auth status
   autometta auth check codex
   autometta auth check claude
   ```

4. Subscribe the target repository and inspect the generated setup before
   committing its tracked state files. `init` also creates the viewer where
   tmux is available; [per-repo subscription](setup.md#3-per-repo-subscription)
   owns the details.

   ```sh
   autometta init <repo-path>
   git -C <repo-path> status --short
   git -C <repo-path> add .gitignore state/state.yaml state/budget.json
   git -C <repo-path> commit -m "Initialise Autometta"
   ```

5. Write a small, independently verifiable stage card using the
   [stage-card template](../templates/stage-card.md), then queue it. Give
   adjacent cards disjoint path claims only when they may safely pipeline; the
   queue rules are in [setup](setup.md#queueing-path-claims).

   ```sh
   autometta add-stage <repo-path> <stage-card-path>
   ```

   When a card builds on earlier stages' landed code, declare them with
   `Depends on` and queue parents first; existing `Gate` cards keep their
   status-only meaning and are not migrated. The
   [dependency graph guide](dependency-graph.md#operator-guide) covers the
   syntax, the migration choice and serial execution. Check readiness with:

   ```sh
   autometta graph --repo <repo-path>
   ```

6. Arm the heartbeat by installing the macOS LaunchAgent for this repository.
   On Linux, install the cron entry in [scheduling](setup.md#4-scheduling);
   each tick invokes the heartbeat and maintains the viewer.

   ```sh
   autometta install-launchagent <repo-path>
   ```

7. Before walking away, confirm the auth route, installed build, budget and
   controller drain state. Inspect `state/budget.json` in the subscribed repo
   and set a bounded cap before running an unattended queue; use
   [observability](observability.md) to interpret the results.

   ```sh
   autometta auth status
   autometta check-build
   autometta drain status
   git -C <repo-path> status --short
   ```

8. Check that the queue is cleanly ready, then let the scheduler drive it.
   Run one tick manually only when you intend to make an immediate state
   transition; otherwise leave the installed scheduler in charge.

   ```sh
   autometta status
   autometta tick
   ```

`autometta graph` and any other command added to the checkout reach an
installed Homebrew CLI only after a separate refresh
(`scripts/install-homebrew-local.sh`, then `autometta --version`). Pulling or
editing the checkout does not update it; until you refresh deliberately, run
`AUTOMETTA_ROOT=<autometta-checkout> <autometta-checkout>/bin/autometta graph`.

## Daily drive

1. Start with the fleet summary after an overnight run. It shows subscribed
   repositories, the active stage, halts and queue depth; see
   [observability](observability.md#commands).

   ```sh
   autometta status
   ```

2. Open the terminal UI for the repo you are reviewing. Use its run, history
   and messages pages to inspect a card, an escalation or a controller reply.

   ```sh
   autometta tui <repo-path>
   ```

3. Use the dashboard for a browser view of fleet spend and trends, and the
   attached viewer when you want a passive repo-scoped screen. The controller
   log is the evidence behind a transition, as described in
   [observability](observability.md#authoritative-surfaces).

   ```sh
   autometta dashboard --open
   autometta attach <repo-path>
   ```

4. If a dependent card is still pending, ask why before touching state. The
   graph names each blocking parent and its reason; a failed parent and a
   budget or quota halt are different stops, and neither clears itself. See
   [inspecting a stopped run](dependency-graph.md#inspecting-a-stopped-run).

   ```sh
   autometta graph --repo <repo-path>
   ```

5. Read a halt before clearing it: inspect its reason in status and the repo's
   `state/state.yaml` and `state/budget.json`, fix the stated cause, then use
   the reset only when it is safe to resume. See the [tick loop](tick-loop.md)
   for halt semantics.

   ```sh
   autometta status
   autometta tick --reset-halt
   ```

6. After a verifier FAIL, preserve the failed worktree for inspection, revise
   the card if needed, then re-queue through the canonical
   `autometta-requeue` path. That path owns cleanup of the run worktree,
   branch and envelope artefacts.

   ```sh
   scripts/requeue-stage.sh <repo-path> <stage-id>
   ```

7. Land a stage awaiting integration only after checking its pinned worktree
   and the current base branch. Ask phat-controller to perform the ordered
   integration; [the controller role](phat-controller.md) explains its remit.

   ```sh
   autometta phat-controller merge-awaiting <repo-path> <stage-id>
   ```

8. Feed the next bounded batch before the end of the day: write cards, queue
   them, then review the scheduled work and budget before leaving the
   scheduler running overnight. Keep card detail in the templates and setup
   guide rather than this runbook.

   ```sh
   autometta add-stage <repo-path> <stage-card-path>
   autometta status
   autometta drain status
   ```

9. Leave the daytime session protected by default. With no answer in the
   controller mandate (installed by `autometta init-host`) the loop holds
   20% of every window: no new card past
   80% used, per family, for the loop and for a manual
   `scripts/spawn-worker.sh` alike (the manual spawn exits 4 and names
   `AUTOMETTA_IGNORE_RESERVE=1` as the override). Set
   `window_reserve.percent: 0` to switch it off. If the controller
   mandate's `window_reserve.overnight` is declared, its percentage applies
   inside that window and the top-level percentage applies outside it.
   Set `window_reserve.overnight.stop_outside: true` to stop new workers
   outside the window regardless of quota; this curfew defaults off.
   An overnight percentage of zero allows spending freely inside it. A stage
   already in flight is never killed for this; it finishes and lands -- see
   [the tick loop](tick-loop.md) for the full resolution rule. **Accepted
   risk:** this depends on the host clock and the `timezone: local` reading
   being correct; a wrong clock silently changes when the loop runs, and the
   only signal is the tick log's resolved-window and curfew line. To spend
   the daytime session down on purpose instead, open a bounded, self-expiring drain
   rather than editing the mandate; when `stop_outside: true` arms a curfew,
   a `--hours` that would outlive the overnight window is refused up front,
   naming the window. Without a curfew it may outlive the percentage window,
   within the existing maximum drain duration.

   ```sh
   scripts/drain.sh start --cap <n> --hours <h> --ignore-reserve
   scripts/drain.sh status
   ```
