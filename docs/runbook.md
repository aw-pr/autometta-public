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

2. Create the host home once on this machine. It is safe to repeat; see
   [machine setup](setup.md#2-one-time-machine-setup).

   ```sh
   autometta init-host
   ```

3. Initialise the target repository, choose its subscription, API, or local
   Codex route in the generated manifest, then verify both families from that
   repository before any dispatch. Put real references only in the gitignored
   local file described in [auth routes](setup.md#7-auth-routes-subscription-api-key-and-free).

   ```sh
   autometta init <repo-path>
   cd <repo-path>
   autometta auth status
   autometta auth check codex
   autometta auth check claude
   ```

4. Inspect the generated setup and commit files intended to be tracked by the
   target repository. `init` also creates the viewer where tmux is available
   and installs the macOS LaunchAgent. Honour existing state ignore rules;
   do not force-add runtime files or the local manifest.
   [Per-repo subscription](setup.md#3-per-repo-subscription) owns the details.

   ```sh
   git -C <repo-path> status --short
   git -C <repo-path> diff -- .gitignore
   ```

5. Write a small, independently verifiable stage card using the
   [stage-card template](../templates/stage-card.md). Settle open decisions,
   run each acceptance command on the base, and freeze any executable oracle
   with its digest before queueing. The
   [card-review](../skills/autometta-card-review/SKILL.md) and
   [oracle](../skills/autometta-oracle/SKILL.md) skills own that preparation.
   Run `scripts/card-lint.sh --strict <stage-card-path>` from the Autometta
   checkout; `add-stage` does not run it for you. Give
   adjacent cards disjoint path claims only when they may safely pipeline; the
   queue rules are in [setup](setup.md#queueing-path-claims).

   When a card builds on earlier stages' landed code, declare them with
   `Depends on` and plan to queue parents first; existing `Gate` cards keep their
   status-only meaning and are not migrated. The
   [dependency graph guide](dependency-graph.md#operator-guide) covers the
   syntax, the migration choice and serial execution.

6. Confirm the scheduler. On macOS, `init` has already installed the
   LaunchAgent; use the command below only if it needs installation or
   reconfiguration, before work starts. On Linux, install the cron entry in
   [scheduling](setup.md#4-scheduling);
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

8. Queue the reviewed card only after the preceding checks, then let the
   scheduler drive it. Queue prerequisite cards first.
   Run one tick manually only when you intend to make an immediate state
   transition; otherwise leave the installed scheduler in charge.

   ```sh
   autometta add-stage <repo-path> <stage-card-path>
   autometta graph --repo <repo-path>
   autometta status
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

2. Open the terminal UI for the repo you are reviewing. Use its run and
   history pages to inspect a card or an escalation.

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
   graph names each blocking parent and its reason. A failed parent, a
   budget halt and a quota admission hold are different stops. A quota hold
   can lift when a fresh reading permits dispatch; a latched budget halt needs
   its cause resolved. See
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
   and the current base branch. Perform the ordered
   integration with the verb below; see [the retired controller](phat-controller.md).

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

9. Review the provider-window policy before leaving a queue unattended.
   The mandate installed by `autometta init-host` carries a 20% reserve.
   Claude admission respects the configured session/model windows. Codex
   subscription admission defaults to fresh usage below 100%, including a
   weekly-only reading where the plan provides no session window. The same
   checks cover both roles of a new card and manual `spawn-worker.sh`
   dispatches; a held manual spawn exits 4. Optional weekly pacing can hold
   new cards earlier and impose a per-run Codex allowance. See the
   [tick-loop policy](tick-loop.md#k-the-controller-is-retired) for freshness,
   overrides and limits. `window_reserve.percent: 0` disables the reserve,
   not Codex's separate default admission cutoff. If the host
   mandate's `window_reserve.overnight` is declared, its percentage applies
   inside that window and the top-level percentage applies outside it.
   Set `window_reserve.claude_window: 5-hour` when this reserve is specifically
   for Claude's session rather than its weekly allowance. A new card is checked
   when either its worker or verifier uses the Claude subscription.
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
