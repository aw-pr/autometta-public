# phat-controller: pass-2 design

This is the design doc for the autonomous-loop layer that sits on top of the pass-1 dispatch contract. It is a brief for stage-5 implementation, not the implementation itself. Stage 5 produces the scripts; this doc fixes the contract those scripts must satisfy.

The pass-2 layer is named `phat-controller` per [`decision-loop-name-phat-controller`](../memory/decision-loop-name-phat-controller.md). The name carries no significance beyond serving as a stable identifier for the cron-supervised tick loop.

## Anchoring

Every decision in this document is traceable to one of:

- A memory entry under `memory/decision-*.md` or `memory/feedback-*.md`.
- `docs/philosophy.md` (the load-bearing beliefs).
- `docs/dispatch-contract.md` (the pass-1 protocol the loop must preserve).

Decisions that did not exist before this stage are listed at the bottom under "New decisions banked by this stage" and have a matching memory entry in the same commit.

## (a) What a tick is, and what one tick does

A tick is a single non-interactive invocation of the `scripts/tick.sh` script (stage 5 will implement it). The tick:

1. Reads the current `state/state.yaml` of the repo it is operating on.
2. Reads the current `state/budget.json` of the same repo.
3. Checks the budget. If any of `token_cap_total`, `wall_clock_cap_seconds`, `clock_tick_cap`, or `consecutive_failure_cap` is exhausted, the tick writes a stall marker into `state.yaml` and exits without dispatching.
4. Selects exactly one transition to make. The transition rule is the simplest possible: if a stage is `in_progress`, advance it by running its verifier (if the worker has reported done) or by checking it for stall; if no stage is `in_progress`, claim the next `pending` stage and dispatch its worker; if no `pending` stage exists, the queue is drained and the tick exits cleanly.
5. Updates `state.yaml` and `budget.json` atomically. "Atomically" means: write to a temp file in the same directory, then `mv` into place. The `mv` is the atomicity primitive on POSIX filesystems given same-directory restraint.
6. Commits the state update on a `phat-controller/state` branch (not `dev`, to avoid interleaving with human commits) using the per-agent author attribution from the global dev rules.
7. Exits. The next tick is the next cron fire.

A tick is one transition, not a loop within the tick. This is the "cron + tick > daemon" belief from `docs/philosophy.md`. The cron schedule defines the loop; the script is a one-shot.

## (b) The state file `state.yaml`

**Location.** Per repo: `state/state.yaml` at the repo root. State lives in the repo it describes; one repo's state is never visible to another repo's tick except through the subscriber index (see section (f)).

**Schema.** `schemas/state.yaml.json` (JSON Schema draft 2020-12). The schema is committed in this stage; the tick script (stage 5) will validate `state.yaml` against it on every read.

**Lifecycle.** The file is created when a repo first subscribes to a `phat-controller` instance (see section (f)). It is mutated only by `tick.sh`; humans may read but should not edit, because human edits without a tick will silently desync `tick_count` from `last_tick_at`. If a human must edit, they must run a `tick.sh --repair` mode (stage-5 implementation; out of scope for this design doc beyond noting the entry point exists).

**Who writes it.** Only `tick.sh`. Worker subagents do not touch `state.yaml` directly; they write into `state/verifiers/<stage-id>.json` (see section (d)) and let the tick promote that into `state.yaml`.

**Atomicity.** Write-to-temp-then-rename within the same directory. This is enough on every POSIX filesystem Autometta is likely to run on (APFS, ext4, btrfs, ZFS). No fsync; we accept that a crash mid-tick can leave `state.yaml` at the pre-tick state and the verifier file already written. The next tick re-reads and recovers; idempotency falls out of the transition rule above.

## (c) The budget file `budget.json`

**Schema.** `schemas/budget.json` (JSON Schema draft 2020-12).

**Failure budget model.** Per [`decision-failure-budget-clock-tick`](../memory/decision-failure-budget-clock-tick.md), the budget is enforced via a clock-tick count, in addition to the pre-existing token and wall-clock caps. Concretely:

- `token_cap_total` / `tokens_spent`: total token spend across all workers and verifiers dispatched by this controller for this repo. Hard stop when `tokens_spent >= token_cap_total`.
- `wall_clock_cap_seconds` / `wall_clock_elapsed_seconds`: cumulative wall-clock time spent inside dispatched processes. Hard stop when elapsed exceeds cap.
- `clock_tick_cap` / `clock_ticks_used`: number of cron-tick fires the controller is allowed to consume for this repo. Hard stop when `clock_ticks_used >= clock_tick_cap`. This is the primary safety; it bounds wall-clock independent of how expensive individual workers were.
- `consecutive_failure_cap` / `consecutive_failures`: number of back-to-back verifier-FAIL signals tolerated before the loop halts for the repo. Resets on a verifier PASS.

Any cap exhaustion writes a stall marker and exits the tick cleanly; the loop does not silently retry. This is the "budget files, not retries" belief from `docs/philosophy.md`.

**Per-repo, filesystem state.** Budget is per-repo, kept in the repo's own `state/budget.json`. The controller does not aggregate budgets across repos; one runaway repo cannot exhaust another's.

## (d) The verifier handoff artefact `state/verifiers/<stage-id>.json`

Per [`decision-verifier-handoff-naming`](../memory/decision-verifier-handoff-naming.md), the verifier writes its structured report into `state/verifiers/<stage-id>.json`. The path name "verifiers" is the chosen convention; the pass-28 `result.worker.json` rename is abandoned.

**Fields** (formal schema deferred to stage 5 if a JSON Schema is warranted; this design doc fixes the shape):

```
{
  "stage_id": "04-phat-controller-design",
  "verifier_identity": "Codex GPT-5.3 <codex-gpt-5-3@local>",
  "verifier_invocation": "codex exec --sandbox read-only ...",
  "ran_at": "2026-05-21T20:00:00Z",
  "criteria": [
    { "id": 1, "name": "...", "verdict": "PASS|FAIL", "evidence": "..." }
  ],
  "additional_findings": "...",
  "overall": "PASS|FAIL"
}
```

The tick reads this file when promoting a stage from `in_progress` to `completed` or `failed`. The file is committed alongside the stage deliverables on the working branch; future ticks and humans can read the audit trail in `git log` plus `state/verifiers/`.

## (e) Identity resolution at tick time

Per [`decision-identity-via-orchestrator-skill`](../memory/decision-identity-via-orchestrator-skill.md), identity drift (a stage card authored when model X was current but dispatched after X retires) is handled via the `agent-orchestrator` skill's per-family equivalence table. The skill's REFERENCE.md maintains the tier-to-current-model map; the tick uses the *tier* the stage card names, not the model name directly. If the card names a model that has been retired, the tick resolves it to the current model at the matching tier of the same family.

Concretely:

- Stage card names `Worker: Claude Sonnet 4.6` (model identity).
- Tick reads the worker line, extracts family ("Claude") and tier ("T2/T3 workhorse" implied by Sonnet 4.6).
- Tick consults the skill's tier table at dispatch time to resolve the current Anthropic T2/T3 model. If Sonnet 4.6 is still current, no drift; if it has been retired, the table names the replacement.
- The dispatched worker carries the resolved identity; the per-agent-attribution rules pick up the resolved identity for the commit author.

The skill is the only source of truth for the table; this design doc does not duplicate the table content.

## (f) Single tick, multi-repo subscribe

Per [`decision-single-tick-multi-repo-subscribe`](../memory/decision-single-tick-multi-repo-subscribe.md), one cron tick serves N repos. Subscription is filesystem-based.

**Subscriber registry.** A singleton home directory at `${PHAT_CONTROLLER_HOME:-$HOME/.phat-controller}`. Inside that dir:

```
~/.phat-controller/
  subscribers/
    autometta.yaml        # one file per subscribed repo
    other-project.yaml
  log/
    tick-2026-05-21.log  # daily rotated tick logs
```

Each subscriber file names one absolute repo path, a poll order weight (integer; lower fires first when multiple repos have pending work), and an enabled flag. Subscribing is `cp subscribers/template.yaml subscribers/<repo-slug>.yaml` then editing. Unsubscribing is `rm` of the file.

**One tick per fire, round-robin within fire.** A single cron fire iterates subscribers in weight order. For each enabled subscriber, the tick:

1. cds to the repo path.
2. Runs the one-transition logic from section (a) on that repo's `state/state.yaml`.
3. Moves to the next subscriber.

Total work per cron fire is bounded by `min(N_subscribers, max_per_fire)` where `max_per_fire` is a top-level limit in the controller config (also at `~/.phat-controller/config.yaml`, schema deferred to stage 5).

**Why filesystem, not a service.** One process per cron fire, no resident daemon, no IPC. Matches the philosophy.md belief "cron + tick > daemon". A repo "publishes" itself by writing a file; the tick reads the directory each fire.

## (g) Failure modes and stall detection

The tick is the source of stall detection; workers do not self-report stalls.

**Worker stall.** A stage in `in_progress` whose `last_tick_at` (or worker process start time, whichever is more recent) is older than the per-stage worker wall-clock budget plus a grace factor (default 1.5x) is considered stalled. The tick:

1. Marks the stage as `stalled` in `state.yaml`.
2. Writes a stall marker into `state/verifiers/<stage-id>.json` with `overall: STALLED`.
3. Increments `consecutive_failures`.
4. Exits.

The next tick respects `consecutive_failure_cap` and halts the loop if exceeded; otherwise the operator (human, on next session) decides whether to retry, re-brief, or abandon.

**Verifier stall.** Same logic. A verifier process that has not written its output file within its declared budget plus grace is killed by the tick (the kill mechanism is `kill -TERM` on the PID recorded when the verifier was spawned; recorded in `state.yaml`).

**Stale log markers.** Every dispatched process logs to a predictable path under `state/logs/<stage-id>-<worker|verifier>.log` per [gotcha 3 (opaque log paths)](./lessons.md#headless-gotcha-3-opaque-log-paths). The tick checks size and mtime on these files when deciding stall status; a log file with non-zero size and recent mtime is evidence the process is making progress, even past nominal budget. Treat as progress and extend grace once per stage.

**Repo subscriber stall.** If a repo's tick consistently stalls, the controller-level `log/tick-YYYY-MM-DD.log` will show repeated stall markers. The operator is responsible for disabling the subscriber file. The controller does not auto-unsubscribe; that decision belongs to the human.

## (h) Interaction with the pass-1 dispatch contract

`phat-controller` does not replace the dispatch contract; it *instantiates* the dispatch contract once per dispatched worker. Every tick that spawns a worker:

1. Authors the stage card on disk (step 1 of the dispatch contract). For an autonomously-driven stage, the card may already exist (human-authored in `examples/` or similar) and the tick simply reads it.
2. Assembles the worker prompt (step 2) by filling in `templates/worker-prompt.md`.
3. Dispatches the worker (step 3) with the sandbox role boundary the stage card specifies.
4. On worker return, schedules the next tick to do the verifier handoff (step 4 and step 5).
5. After verifier PASS, the tick performs orchestrator integration (step 6) by reading the diff and committing (step 7) on the working branch.

The dispatch contract's seven steps are the per-stage protocol; phat-controller is the across-stage queue scheduler. The seven-step contract continues to apply, unchanged, for every spawned stage.

## Operational entry points (for stage 5)

This section is informational, not normative. Stage 5 will produce:

- `scripts/tick.sh`: the cron entry point.
- `scripts/spawn-worker.sh`: helper invoked by `tick.sh` to dispatch one worker per the stage card.
- `scripts/spawn-verifier.sh`: helper invoked by `tick.sh` to dispatch the cross-family verifier.
- `scripts/budget.sh`: helper for reading and updating `state/budget.json` atomically.

The shape of these scripts is stage-5's responsibility; this design doc fixes only the contract surface (state file, budget file, verifier handoff format, subscriber registry, identity resolution).

## Future scope

Items deferred beyond pass 2:

- Multi-machine federation. The current design is single-machine; if a second machine wants to subscribe to the same backlog, that is out of scope.
- Web UI or TUI for the controller. The current design is filesystem and `git log`; any visualisation is downstream.
- Token estimation before dispatch. The current design enforces `token_cap_total` after the fact (per dispatched process). A pre-dispatch estimator is future scope.
- Multi-language stage cards. Currently all cards and prompts are English; localisation is future scope.

## New decisions banked by this stage

Three genuinely new design decisions surfaced during this stage that were not previously in any memory entry. Each has a corresponding `memory/decision-*.md` entry committed in the same commit as this document:

1. `state/` directory per repo holds `state.yaml`, `budget.json`, and `verifiers/<stage-id>.json` (banked at `memory/decision-state-dir-per-repo.md`).
2. `phat-controller` runs as one process per cron fire, no resident daemon, with a singleton subscriber registry at `~/.phat-controller/` (banked at `memory/decision-phat-controller-no-daemon-subscriber-registry.md`).
3. Four implementation parameters fixed by this design and surfaced by the stage-4 verifier re-brief: working branch `phat-controller/state`, repair entry point `tick.sh --repair`, per-fire cap config at `~/.phat-controller/config.yaml`, default stall grace factor 1.5x (banked at `memory/decision-tick-implementation-parameters.md`).
