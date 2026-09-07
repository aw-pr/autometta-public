# The tick loop: pass-2 design

This is the design doc for the autonomous-loop layer that sits on top of the pass-1 dispatch contract. It is a brief for stage-5 implementation, not the implementation itself. Stage 5 produces the scripts; this doc fixes the contract those scripts must satisfy.

The pass-2 layer is the tick loop: a cron-supervised tick that reads state,
makes one transition, writes state and exits. The name **phat-controller** is
reserved for the queue-minding role described in section (k).

## Anchoring

Every decision in this document is traceable to one of:

- A memory entry under `memory/decision-*.md` or `memory/feedback-*.md`.
- `docs/philosophy.md` (the load-bearing beliefs).
- `docs/dispatch-contract.md` (the pass-1 protocol the loop must preserve).

Decisions that did not exist before this stage are listed at the bottom under "New decisions banked by this stage" and have a matching memory entry in the same commit.

## (a) What a tick is, and what one tick does

A tick is a single non-interactive invocation of `autometta tick`, which delegates to `scripts/tick.sh`. The tick:

1. Reads the current `state/state.yaml` of the repo it is operating on.
2. Reads the current `state/budget.json` of the same repo.
3. Checks the budget. If any of `token_cap_total`, `wall_clock_cap_seconds`, `clock_tick_cap`, or `consecutive_failure_cap` is exhausted, the tick writes a stall marker into `state.yaml` and exits without dispatching.
4. Selects one queue transition per stage to make. Normally this is serial:
   advance the `current_stage`, or claim the next `pending` stage when none is
   in flight. When a verifier lands stage N, that stage is terminal and the
   same fire may claim eligible stage N+1: nothing about N can be re-read by a
   later fire. The one bounded exception is a declared pipeline pair: while
   verifier N is live, the tick may dispatch worker N+1 and record both
   flights by stage id. It never starts a third stage.
5. Updates `state.yaml` and `budget.json` atomically. "Atomically" means: write to a temp file in the same directory, then `mv` into place. The `mv` is the atomicity primitive on POSIX filesystems given same-directory restraint.
6. Snapshots the state update onto the `autometta/state` ref, using the per-agent author attribution from the global dev rules. It does this with git plumbing and never checks the branch out: see (j).
7. Exits. The next tick is the next cron fire.

A tick makes one transition per stage, not two transitions on the same stage
within a fire. This is the "cron + tick > daemon" belief from
`docs/philosophy.md`: the cron schedule defines the loop and the script is a
one-shot, while a terminal landing may release the next stage without a fire
that can learn anything new about the landed one.

### Tick cost model

The floor for an idle fleet tick is controller-wide work plus the per-repo
work. On 2026-09-01, three six-subscriber runs measured 90.20s, 90.22s and
91.54s wall time, with 63-64s user and 30-31s system time. The high system
share pointed to process creation rather than YAML parsing, quota reads,
state hashing or an explicit sleep.

The profile isolated the cost to the installed-build comparison inside
`heartbeat.sh`. It walked and SHA-256 hashed the installed and checkout trees
once for every subscriber, even though both trees are controller-wide facts.
Measured directly on the same host, that one comparison took 14.65s / 10.33s
user / 4.76s system, then 14.35s / 10.24s / 4.70s, then 14.25s / 10.25s /
4.57s. Six copies explain the observed floor.

`tick.sh` now obtains one sanitised build-check JSON result per fleet fire and
passes it to each heartbeat. Every repo still writes its own heartbeat report
and receives the same build-drift verdict; only the repeated tree walk is
removed. The resulting model is `fixed tick work + one build comparison`,
rather than `fixed tick work + subscribers × build comparison`. The offline
six-repo cost smoke uses a one-second stand-in for that comparison: the
pre-change path took 9.51s with six calls; the cached path took 3.81s with one,
below its 6.0s fixture budget. The fixture leaves every repo idle, with one
`idle_ticks_used` increment and no `clock_ticks_used` increment.

The cost smoke is deliberately a regression guard, not a substitute for a
live fleet measurement. Re-measure three clean live runs after installing the
changed build before changing the LaunchAgent cadence. Record wall, user and
system time together, because a later regression may move cost between those
categories without changing wall time.

### Pipeline pairs

Every new card must declare non-empty `path_claims` or opt out with
`- **Dispatch:** serial`; `add-stage.sh` refuses an omitted choice. Existing
queued records without claims remain serial and are not rewritten. Two adjacent
claimed stages become a pipeline pair only when the claimed paths are disjoint,
their worker **dispatch targets** differ, and remaining token headroom covers
twice the repo's p95 historical dispatch cost from `state/cost-log.jsonl`.

The dispatch target is the vendor family by default, so the rule reads exactly
as it always did: two Codex workers do not pair, a Codex and a Claude worker
may. A repo can widen it with `pipeline.pair_on: target` in
`.autometta.local.yaml` (env override `AUTOMETTA_PIPELINE_PAIR_ON`), which
appends the weights for an identity that names local Ollama models, giving
`codex/llama3.3:70b` against `codex/gpt-oss:20b`. That exists because the
family alone cannot express independence on the local route: every local
dispatch goes through `codex exec --oss`, so every local worker is family
`codex` and a wholly free run could never pair at all. Two different local
models are genuinely independent, being separate weights in separate loaded
copies with no shared rate-limit window, which is the contention the gate is
protecting. Cloud identities keep family alone under either setting, since two
Codex API workers contend for one provider window whichever model they name.

`pipeline.pair_on: off` disables the alternation comparison entirely: any two
claimed, disjoint stages inside headroom may pair, whatever their workers.
This trades quota isolation for wall clock, so both dispatches of a pair can
land on one provider window and contend there; the claims, gate and headroom
checks still apply. An operator choice for a repo that would rather spend a
window faster than wait out serial order.
An unreadable or invalid value falls back to `family`: pairing is the widening
option, so a misconfiguration must never be what turns it on.
Missing claims produce no pairing decision or pairing log. Overlap, a repeated
worker family, or thin headroom is logged as an explicit refusal. The ordinary
provider-window and `budget_gate_dispatch` checks still guard the second worker
spawn individually.

The serial-only claim rule is asymmetric. A head claiming `scripts/lib` stays
serial, while a head claiming `scripts/tick.sh` may take a disjoint tail,
including a docs-only or smoke-only card. A tail claiming either
`scripts/tick.sh` or `scripts/lib` stays serial. This keeps shared library
changes out of a pair without blocking a tail that cannot touch the head's
implementation.

`current_stage` remains the ordered landing head. `pipeline_pair` records the
head, tail, common pre-head base tip, phase, and whether the tail needs rebasing;
each stage retains its own worker and verifier PIDs. Heartbeat and worktree
reaping continue to use those stage-specific registrations and statuses. The
tail worker may finish early, but its verifier artefact is not considered until
the head resolves.

Landing is strict queue order. If N fails, dev has not moved and N+1 follows the
ordinary fast-forward path. If N passes, the tick compares the actual changed
file names in N's landed commit with N+1's tracked and untracked work. A
file-disjoint tail is stashed, reset onto the new base, and restored before its
verifier runs. Any overlap or restore conflict halts with
`controller-escalation`; the tick does not resolve a conflict. A failure in
either member drops the current pair to serial but does not disable pairing for
the repo. Only a claim collision found from the actual diffs or a tail rebase
failure increments that stage's `pairing_failures`, and the attributed cause is
appended to `pairing_failure_causes`. A verifier FAIL on the merits, agent death
or provider refusal increments nothing. A stage with one attributed failure may
pair again; a count of two refuses that stage, and a landed re-brief clears its
count and causes. The remaining queue proceeds serially where safe.

Accepted risks: two dispatches may share a provider window when `pair_on` is
`off`; budget headroom is checked at dispatch and tokens are accounted at reap,
so a pair can overshoot the cap by up to two p95s.

## (b) The state file `state.yaml`

**Location.** Per repo: `state/state.yaml` at the repo root. State lives in the repo it describes; one repo's state is never visible to another repo's tick except through the subscriber index (see section (f)).

**Schema.** `schemas/state.yaml.json` (JSON Schema draft 2020-12). The schema is committed in this stage; the tick script (stage 5) will validate `state.yaml` against it on every read. As of stage 102 the schema is enforceable: it declares every field `tick.sh` writes (including `tokens`, `worker_tokens`, `verifier_tokens`, `verifier_started_at`, and the orchestrator's hand-added `notes` / `integration.integrated_at` / `integration.note`), so both autometta's and a subscriber's live `state.yaml` validate with zero errors while `additionalProperties: false` still rejects a typo or a stray field. `scripts/state-schema-smoke.sh` is the regression guard. When the tick gains a field, add it to `schemas/state.yaml.json` in the same change that adds the write, note which code path writes it, and re-run the smoke script before landing.

**Lifecycle.** The file is created when a repo first subscribes to the tick loop (see section (f)). It is mutated only by `autometta tick`; humans may read but should not edit, because human edits without a tick will silently desync `tick_count` from `last_tick_at`. If a human must edit, they must run `autometta tick --repair`.

`autometta add-stage` assigns each new stage a `run_id`. It reuses the id
from the most recent pending or in-progress stage, or creates a UTC
`run-YYYYMMDD-HHMMSS` id when no run is active; historic records from before
the field existed are not backfilled.

**Who writes it.** Only `autometta tick`. Worker subagents do not touch `state.yaml` directly; they write into `state/verifiers/<stage-id>.json` (see section (d)) and let the tick promote that into `state.yaml`.

**Atomicity.** Write-to-temp-then-rename within the same directory. This is enough on every POSIX filesystem Autometta is likely to run on (APFS, ext4, btrfs, ZFS). No fsync; we accept that a crash mid-tick can leave `state.yaml` at the pre-tick state and the verifier file already written. The next tick re-reads and recovers; idempotency falls out of the transition rule above.

## (c) The budget file `budget.json`

**Schema.** `schemas/budget.json` (JSON Schema draft 2020-12).

**Failure budget model.** Per [`decision-failure-budget-clock-tick`](../memory/decision-failure-budget-clock-tick.md), the budget is enforced via a clock-tick count, in addition to the pre-existing token and wall-clock caps. Concretely:

- `token_cap_total` / `tokens_spent`: token spend for the current run window across all workers and verifiers dispatched by this controller for this repo. Hard stop when `tokens_spent >= token_cap_total`. Despite the field name this is a per-window figure, not a lifetime one: `budget_ensure_window` zeroes it at a UTC day boundary. `lifetime_tokens_spent` is the lifetime figure and nothing resets it.
- `wall_clock_cap_seconds` / `wall_clock_elapsed_seconds`: cumulative wall-clock time spent inside dispatched processes. Hard stop when elapsed exceeds cap.
- `clock_tick_cap` / `clock_ticks_used`: number of **work** ticks the controller is allowed to consume for this repo. Hard stop when `clock_ticks_used >= clock_tick_cap`. This is the primary safety; it bounds wall-clock independent of how expensive individual workers were. A work tick is one that supervised a stage in flight, reaped or killed an agent, transitioned a stage, or dispatched a queued one.
- `idle_tick_cap` / `idle_ticks_used`: ticks that found nothing to do. Absent by default, and an absent cap never binds. It is an odometer for "how much of this window went on polling an empty queue", not a safety.
- `consecutive_failure_cap` / `consecutive_failures`: number of back-to-back verifier-FAIL signals tolerated before the loop halts for the repo. Resets on a verifier PASS, and on a re-queue of a failed stage.

Any cap exhaustion writes a stall marker and exits the tick cleanly; the loop does not silently retry. This is the "budget files, not retries" belief from `docs/philosophy.md`.

**Work is not polling.** The tick counter used to advance on the unconditional fall-through at the end of the per-repo tick as well as on the early returns above it, so it advanced whether or not an agent was dispatched. A repo with an empty queue therefore reached its cap on a fixed schedule regardless of what it did. On 2026-08-23 five of six enabled subscribers were halted on `tick-cap` having spent zero tokens and zero wall-clock seconds; `aegis-guardrails` holds one stage, that stage is `completed`, and it burned 400 ticks establishing there was nothing to dispatch. The window then reset at midnight, the fleet spent the day's allowance through the small hours, and every subscriber was halted before the evening window opened. A cap whose only reachable effect is to halt an idle repo is worse than no cap: it converts "nothing to do" into "cannot work when there is". Idle polling is now counted separately in `idle_ticks_used` and bounded only if an operator sets `idle_tick_cap`.

**Clearing a halt.** `tick.sh --reset-halt` clears the halt flag *and* the counters that produce a halt: `clock_ticks_used`, `idle_ticks_used`, `consecutive_failures`. It leaves `tokens_spent` and `wall_clock_elapsed_seconds` alone unless `--reset-tokens` is passed as well, because a polling artefact can be zeroed freely but real spend against a real cap is a decision to make explicitly. While a spend cap is still over it clears the counters but keeps the halt latched, re-stamped to whichever cap is actually still breached, and says so: unlatching a live spend breach is manufacturing budget, not recovery, which is the same line `requeue-stage.sh` draws. It writes a `breaches[]` record before clearing, for the same reason the window reset does. Before 2026-08-23 it cleared only `halted`, `halt_reason` and `halted_at`, so a tick-capped repo re-halted on the very next tick: all seven subscribers were reported reset and all seven were back to `halted: true, halt_reason: tick-cap` within one tick interval, still reading 400/400. A recovery command that leaves the machine in the state it was rescued from is worse than none, because it reports success.

**Where the caps are enforced.** Two places, and the distinction is load-bearing. `budget_check_caps` runs once at the top of each tick and decides whether the tick does anything at all. `budget_gate_dispatch` runs immediately before *every* worker and verifier spawn and decides whether that spawn happens. Only the second one binds: a tick reaps finished agents and charges their tokens partway through its own run, so the top-of-tick read is stale by one dispatch by the time a spawn is reached. Enforcing only at the top of the tick is what let `emergence-lab-gpu` spend 149,752,682 tokens against a 1,000,000 cap on 2026-08-15 (gotcha 13 in [`lessons.md`](./lessons.md)). Any new dispatch path must call `budget_gate_dispatch` or it is outside the only safety in the design.

**What a cap can and cannot promise.** Token and wall-clock spend are measured after the fact, per dispatched process, so the guarantee is "stops within one dispatch's spend of the cap", never "stops at the cap". On the incident repo the mean dispatch cost 4,830,731 tokens and the largest 19,019,631, so a 1,000,000-token cap could only ever stop at roughly 5.7x itself. Set a cap you can afford to exceed by one worker or one verifier, whichever is dearer. The clock-tick cap has no such slack, which is why it is the primary safety.

**Breach retention.** `budget_ensure_window` deliberately resets a halted-or-at-cap budget at a UTC day boundary so a new day can resume a repo that halted for a real reason. Because that reset zeroes exactly the counters that evidence a breach, `budget_record_breach` writes an append-only `breaches[]` entry (counters, caps and reasons as they stood) before the reset touches anything, and again whenever a cap halts the loop. `halt_reasons` records every cap that was over, not just the first one tested. Without these a 149x overrun reads as a healthy repo the next morning.

**Per-repo, filesystem state.** Budget is per-repo, kept in the repo's own `state/budget.json`. The controller does not aggregate budgets across repos; one runaway repo cannot exhaust another's.

## (d) The verifier handoff artefact `state/verifiers/<stage-id>.json`

Per [`decision-verifier-handoff-naming`](../memory/decision-verifier-handoff-naming.md), the verifier writes its structured report into `state/verifiers/<stage-id>.json`. The path name "verifiers" is the chosen convention; the pass-28 `result.worker.json` rename is abandoned.

**Fields** (formal schema deferred to stage 5 if a JSON Schema is warranted; this design doc fixes the shape):

```
{
  "stage_id": "04-phat-controller-design",
  "verifier_identity": "GPT-5.6 Sol <gpt-5-6-sol@local>",
  "verifier_invocation": "codex exec --sandbox read-only ...",
  "ran_at": "2026-05-21T20:00:00Z",
  "criteria": [
    { "id": 1, "name": "...", "verdict": "PASS|FAIL", "evidence": "..." }
  ],
  "additional_findings": "...",
  "overall": "PASS|FAIL"
}
```

The tick reads this file when promoting a stage from `in_progress` to
`completed` or `failed`, but only after the verifier PID recorded for that same
stage is no longer live. The artefact is output, not a process-completion
signal: an early writer cannot trigger accounting, landing, or worktree reaping
while it is still running. This check is identical for serial and paired
flights. The file is committed alongside the stage deliverables on the working
branch; future ticks and humans can read the audit trail in `git log` plus
`state/verifiers/`.

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

**Subscriber registry.** A singleton home directory at `${AUTOMETTA_HOME:-$HOME/.autometta}`. Inside that dir:

```
~/.autometta/
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

Total work per cron fire is bounded by `min(N_subscribers, max_per_fire)` where `max_per_fire` is a top-level limit in the controller config (also at `~/.autometta/config.yaml`, schema deferred to stage 5).

**Why filesystem, not a service.** One process per cron fire, no resident daemon, no IPC. Matches the philosophy.md belief "cron + tick > daemon". A repo "publishes" itself by writing a file; the tick reads the directory each fire.

## (g) Failure modes and stall detection

The tick is the source of stall detection; workers do not self-report stalls.

**Worker stall.** A stage in `in_progress` whose `last_tick_at` (or worker process start time, whichever is more recent) is older than the per-stage worker wall-clock budget plus a grace factor (default 1.5x) is considered stalled. A Claude worker is also stalled when its newest worktree transcript contains at least five `system` rows with `subtype: api_error` in the last ten minutes and no assistant `tool_use` row in that window. Set `AUTOMETTA_API_ERROR_WINDOW_MIN` to change the window. A missing transcript is neutral, and Codex workers skip this check.

The tick terminates the recorded worker wrapper and every descendant with TERM, waits for a short grace period, then sends KILL to any process still alive. Claude worker wrappers are started in their own process group as an additional lifecycle boundary. The tick then:

1. Marks the stage as `stalled` in `state.yaml`.
2. Writes a stall marker into `state/verifiers/<stage-id>.json` with `overall: STALLED`.
3. Increments `consecutive_failures`.
4. Exits.

The next tick respects `consecutive_failure_cap` and halts the loop if exceeded; otherwise the operator (human, on next session) decides whether to retry, re-brief, or abandon.

**Verifier stall.** The same wall-clock rule and process-tree termination apply. A verifier process that has not written its output file within its declared budget plus grace is terminated before the stage is marked stalled. The transcript API-error rule applies only to Claude workers.

**Dispatch configuration fault.** A worker or verifier that exits within two seconds, writes no completion artefact, leaves only a tiny log (at most 512 bytes), and reports a recognised CLI usage, missing-executable, or auth-route error has not attempted its role. The tick marks the stage `stalled`, records `dispatch_configuration_fault:<role>` on the stage, and halts the repo with `dispatch-configuration-fault` so an operator fixes the command or credentials. For a verifier, the attempt reserved before spawn is returned. The halt prevents an uncounted fault from looping forever. A crash or genuine verification failure that does not satisfy the full conjunction retains its attempt and follows the existing retry cap of three.

**Stale log markers.** Every dispatched process logs to a predictable path under `state/logs/<stage-id>-<worker|verifier>.log` per [gotcha 3 (opaque log paths)](./lessons.md#headless-gotcha-3-opaque-log-paths). The tick checks size and mtime on these files when deciding stall status; a log file with non-zero size and recent mtime is evidence the process is making progress, even past nominal budget. Treat as progress and extend grace once per stage.

**Repo subscriber stall.** If a repo's tick consistently stalls, the controller-level `log/tick-YYYY-MM-DD.log` will show repeated stall markers. The operator is responsible for disabling the subscriber file. The controller does not auto-unsubscribe; that decision belongs to the human.

## (h) Interaction with the pass-1 dispatch contract

The tick loop does not replace the dispatch contract; it *instantiates* the dispatch contract once per dispatched worker. Every tick that spawns a worker:

1. Authors the stage card on disk (step 1 of the dispatch contract). For an autonomously-driven stage, the card may already exist (human-authored in `examples/` or similar) and the tick simply reads it.
2. Assembles the worker prompt (step 2) by filling in `templates/worker-prompt.md`.
3. Dispatches the worker (step 3) with the sandbox role boundary the stage card specifies.
4. On worker return, schedules the next tick to do the verifier handoff (step 4 and step 5).
5. After verifier PASS, the tick performs orchestrator integration (step 6) by reading the diff and committing (step 7) on the working branch.

The dispatch contract's seven steps are the per-stage protocol; the tick loop is the across-stage queue scheduler. The seven-step contract continues to apply, unchanged, for every spawned stage.

## (i) Observability surface

The controller is observable through files it already owns:

- `state/state.yaml` for the ordered current stage, optional `pipeline_pair`,
  per-stage statuses, identities and PIDs, halt state, and tick counters.
- `state/budget.json` for budget caps, failure counters, and halt reason.
- `state/logs/<stage-id>-worker.log` and `state/logs/<stage-id>-verifier.log` for process output.
- `state/verifiers/<stage-id>.json` for structured verifier reports.
- `${AUTOMETTA_HOME:-$HOME/.autometta}/log/tick-YYYY-MM-DD.log` for tick-loop output.
- `autometta/state` for committed state snapshots (see (j) for what is in one).

`autometta status` is the read-only operator view over those files. `autometta
init <repo>` creates a detached tmux viewer named
`autometta-<project-name>` when `tmux` is available. `autometta attach <repo>`
opens or refreshes that viewer with two windows: `repo`, a full-window ticker
for the subscriber, and `log`, the latest controller log filtered to that
repo. It is deliberately downstream of the filesystem state; it does not
dispatch, supervise, or retry work.

This gives the operator an attachable cockpit without creating a resident controller daemon.

## (j) The state snapshot, and keeping out of the shared tree

`repo_root` is the operator's checkout. The loop dispatches into an ephemeral sibling worktree precisely so no worker or verifier touches it, and two paths in the tick have to hold the same line: the state snapshot, and the fast-forward of the base branch on PASS.

**The snapshot never checks anything out.** `commit_state_branch` used to run `git checkout -B phat-controller/state` in `repo_root`, commit, and restore the operator's branch from an `EXIT` trap. The window is a fraction of a second, and the fleet job opens it roughly 288 times a day per subscriber in a tree a person is expected to be working in. On 2026-08-23 an orchestrator commit authored against `dev` landed on `phat-controller/state` inside that window (`2d4dc08`). `git push origin dev` answered "Everything up-to-date", which is how it was noticed; the next tick's `checkout -B` would have reset the ref past it and made it unreachable. It was recovered as a cherry-pick, `1efd82a`, within minutes.

The replacement builds the commit with plumbing: `git add` into a throwaway `GIT_INDEX_FILE`, `git write-tree`, `git commit-tree`, one `git update-ref` with the previous tip as its compare-and-swap guard. No checkout, no HEAD move, no write to `repo_root`'s index or working tree, and nothing for a concurrent operator commit to race with. A dedicated worktree for the ref would also have kept HEAD still, but it is a fixture to create, maintain and reap, and the state files live in `repo_root/state`, so it would have to copy them across on every tick.

**What a snapshot holds.** `state/state.yaml` and `state/budget.json`, plus whatever of `state/verifiers`, `state/envelopes` and `state/handoffs` (the legacy path a stale subscriber still writes, see `docs/dispatch-contract.md` envelope migration) the repo does not ignore. Not `state/logs`, `state/cost-log.jsonl`, `state/active-agents`, `state/recent-agents` or `state/heartbeat.json`. The commit body names exactly what was captured, so the ref never claims more than it holds, and an unchanged state adds no commit.

`state.yaml` and `budget.json` are gitignored in every subscriber, so the snapshot stages them with `git add -f`. That is deliberate. Before this, the plain `git add state/state.yaml` was a silent no-op (`docs/lessons.md` gotcha 10) and the ref held only the repo tree it had been reset to: the branch documented here as "committed state snapshots" had never contained one line of state. Forcing them onto this ref does not make them tracked on any working branch, `.gitignore` still governs every operator commit, and whether `state.yaml` should be tracked remains an open question this did not answer. The snapshot is local: the loop never pushes the ref, and nothing else should.

`state/state.yaml.bak`, the rolling copy `state_apply_json` writes, stays. It recovers the previous good state within the same tick; the snapshot ref recovers a history of them.

**Landing has three outcomes.** On PASS, `finalize_run_worktree` first attempts the ordinary fast-forward when base has not moved since dispatch. It never checks base out in `repo_root`: a fast-forward is a ref move, so the tick updates the branch where it is checked out, or with `git update-ref` when it is not.

When base has moved, the tick compares the files changed by `dispatch_base_tip..base` with those changed by `dispatch_base_tip..run_tip`. File-disjoint changes are mechanically rebased in the run worktree, then fast-forwarded and torn down. The verified pre-rebase tip remains in `integration.head`; `integration.rebased_tip` records the new tip and `integration.rebased: true` records the route. The verifier's verdict is not re-run after this rebase: the disjoint-file test is the premise for carrying its verdict forward.

Any file overlap, unavailable dispatch tip, or rebase conflict takes the third route: the tick aborts the rebase, leaves the run branch and worktree standing, and records `awaiting`. It never resolves a conflict headlessly or writes a note into the base checkout. The state record and tick log are the integration ledger:

```yaml
integration:
  state: awaiting        # or merged
  base_branch: dev
  run_branch: autometta/39-loop-moves-head-in-the-shared-tree
  head: 0d1e2f3...
  pushed: true
  recorded_at: 2026-08-23T14:02:11Z
```

`autometta status` prints an `awaiting integration` line per outstanding stage under the repo's row. `phat-controller merge-awaiting` remains the route for a parked branch that can later be merged cleanly.

**Reaping.** `scripts/reap-worktrees.sh` runs after every tick as part of `sweep_repo_retention`, and by hand with `--dry-run`. It removes a run worktree whose stage is finished with it, through `requeue-stage.sh --worktree-only` so that removal has one implementation. It refuses to remove a worktree whose stage is `in_progress`, one holding uncommitted work that is not the known `state/` symlink artefact (a verifier FAIL leaves the worker's diff uncommitted by design, and that diff is what the operator inspects), one whose run branch holds commits that are not on base, and one whose stage it cannot find in `state.yaml`. Those it reports instead, on every tick until someone deals with them. When a person merges an `awaiting` branch by hand, the next sweep notices the containment, closes the record out to `merged`, and collects the worktree.

## (k) The phat-controller role

The tick loop dispatches and verifies; it does not decide that a verifier
FAIL is a card defect rather than a work defect, preserve work stranded by an
agent that died mid-write, merge an integration a person would otherwise
merge by hand, clear a stale pause, or keep the queue fed. On 2026-08-24 an
interactive orchestrator session did all of that on a fifteen-minute cadence
while the operator left the queue running unattended. **phat-controller** is
that session, packaged.

**An agent that calls scripts, not a script that calls an agent.** Card 54
shipped this the other way round: four remediations enumerated in bash, two
stage statuses scanned, one narrow judgement dispatched. Two things fell out
of that shape the evening it landed. The mandate manifest was not a mandate
(it said so in its own header: thresholds and cadence only), and the blocker
that actually happened was not on the list. Stage 54's own first attempt went
`stalled` with `worker_envelope_missing_after_exit`, and the only occurrence
of the string "stalled" in the script was inside the word "installed"; the
queue would have sat there until morning. The list was short because an
enumerated list is what a script can hold, and the remit wanted is the
initiative an orchestrator session actually exercises. Initiative does not
enumerate. Card 58 inverted it: the role is an agent, seeded at configure
time, and `scripts/phat-controller.sh` is the set of verbs it calls. The
design is `docs/proposals/orchestrator-role-review.md`.

**The context seed.** Rendered by `scripts/render-controller-seed.sh` when a
job is configured, to `$AUTOMETTA_HOME/phat-controller-seed.md`
(gitignored, operator-owned, editable afterwards). It carries, in this order:
the persona and mandate, the negative list below, the spend authority and
provider-window reserve answered for at setup, and the repo facts an
orchestrator would otherwise rediscover (paths, families and their auth modes,
branch policy, where state lives, the repo's own gotchas lifted from its agent
brief at render time). It
is prose an agent reads, not a config file anything parses; thresholds that a
script must act on stay in the mandate manifest.

**The spend authority is answered for at configure time, and there is no
default.** The right level varies by run, by hour and by day, so a committed
default would be wrong most of the time it was used, and wrong expensively.
`render-controller-seed.sh` with no `--spend-authority` prints what it needs
and exits 2 having written nothing;
`install-launchagent-phat-controller.sh` refuses to install a schedule with
no seed rather than rendering one. The controller then spends to that
authority without asking, because there is nobody to ask, and halts when it
is exhausted rather than escalating into a wait nothing will service. The
prose answer lives in the seed; its machine-readable half
(`--token-ceiling`, `--expires`) is mirrored into the mandate's
`spend_authority` block so a pass can stop without parsing prose.

**The provider-window reserve is the second configure-time answer.** The
operator supplies a percentage, where zero explicitly means off, and chooses
`hold` or `observe`. No answer is committed as a default. The renderer records
the answer in the seed and mirrors `window_reserve.percent` and
`window_reserve.action` into the mandate. Before each worker or verifier spawn,
the tick compares that role's family with the once-per-tick quota reading. A
known window inside a `hold` reserve pauses until its own reset; an unknown
reading and `observe` both proceed unchanged.

**The reserve can carry a schedule, so a run knows what time it is (card
124).** `percent`/`action` alone serve two different hours equally badly: the
right reserve at 14:00, when the operator wants a usable Claude session, and
at 23:00, when the intent is to spend the window down on purpose, are not the
same number. `window_reserve.overnight` (`start`, `end`, `percent`,
`timezone: local`) is the optional second answer. `quota_reserve_settings`
resolves the reserve **for the current moment** rather than returning one
static pair: inside the declared window it uses `overnight.percent`
(typically `0`, meaning the reserve does not bind); outside it, the top-level
`percent`/`action` apply exactly as they always have. A host that never
declares `overnight` sees no change at all -- `quota_reserve_settings`
returns byte-for-byte what it returned before this card.

The clock read is **operator wall-clock, always local, never UTC** --
`overnight` describes when a person is asleep, and sleep does not move with
UTC. **Accepted risk:** a wrong system clock or a wrong timezone silently
changes when the loop runs, with no alarm of its own; the only signal is the
tick's own log line naming which rule resolved (`daytime`/`overnight`/
`default`/`drain-ignore-reserve`) and the reserve percentage it carried. There
is no independent check that the host clock is correct. A window whose `end`
is earlier than its `start` (`22:00` to `01:00`) crosses midnight and is
resolved as one interval (`now >= start OR now < end`), not two separate
comparisons -- the obvious `start <= now < end` test is silently wrong for a
wrapping window, since it can never match at all.

**The stop at the end of the overnight window only refuses new dispatch.**
Nothing installs a stop job (the emergence-lab 2026-09-03 hand-installed
LaunchAgent that failed to remove itself is exactly the failure mode this
avoids): the tick reads the clock on every fire and, outside the declared
window, refuses to start a *new* worker at all.

The stop is a separate gate sitting above the reserve, and it deliberately
reads no quota. The reserve is reading-driven: it binds only when a known
window is near exhaustion, and an unknown reading fails open by design. That
is right for a guard against spending the last of a window and useless as a
stop, because the case a stop exists for -- an overnight run that must not
still be dispatching at nine the next morning -- is exactly the case where
the reading is healthy (the window reset in the night) or unknown (no
snapshot). A stop built on the reading fails open precisely when it is
needed, and leaves the operator no session and no alarm saying why. So the
clock alone decides, and the refusal is logged as `schedule stop worker
<stage> (<family>): clock HH:MM is outside the <start>-<end> dispatch
window`. The consequence worth stating plainly: **once a schedule is
declared, the loop starts no new work outside the window**, and burning the
day is the opt-in `drain.sh start --ignore-reserve` below. A
stage already in flight when the window closes is never killed to enforce
this, and its verifier is not held by the resumed daytime reserve either: the
stage's `reserve_exempt` flag, stamped at worker-dispatch time whenever the
resolved window was `overnight` or a `--ignore-reserve` drain was active,
lets that one stage's verifier land regardless of the clock by the time it
is reaped. A stage whose worker started under the ordinary daytime reserve
carries no such exemption.

**Burning the daytime session is opt-in and self-expiring, via the existing
drain rather than a second switch.** `drain.sh start --ignore-reserve`
suspends the reserve (daytime or scheduled) for the life of that one drain
and no longer -- it is already the operator's declared, bounded "spend the
window down on purpose" verb, already self-expiring, already scoped. When a
schedule is declared, a `--hours` that would still be running past the next
occurrence of the overnight window's end is refused at `start`, naming the
window: a drain must not outlive the permission it is spending against.

**What bounds it is a short negative list, not an action enumeration.** The
recoverable actions do not need enumerating and the unrecoverable ones are
few. The governing distinction: the controller may change **what is recorded
and where**, never **what was asked for or whether it was met**. Anything in
the first class is auditable and revertible in git; anything in the second is
the record of intent, and a queue minder that can edit intent can make any
stage pass.

Forbidden, without exception: editing a card's acceptance criteria, objective
or specification (it proposes instead, in the `PROPOSED-AMENDMENT` form card
54 defined); verifying its own dispatches; rewriting history, pushing
non-fast-forward, or moving a publish branch outward; lifting its own spend
caps; resolving a merge conflict. The list is written once, in the proposal,
and copied verbatim into the seed template; `render-controller-seed.sh`
diffs the two at render time and refuses to render a seed whose prohibitions
have drifted from the document that owns them.

Two of the five are enforced mechanically rather than trusted to prose.
`pc_card_append` measures the card before writing and re-checks afterwards
that every previous byte is still an exact prefix, restoring the file and
refusing otherwise, so nothing that goes through `rebrief` or
`propose-amendment` can soften a criterion. `push` has no policy of its own
and does exactly what `git-push-check` says.

**The verbs.** `scripts/phat-controller.sh <verb>`: `picture` (the
mechanical triage picture as JSON, reporting observations under `signals` and
never naming an action), `preserve`, `rebrief`, `propose-amendment`,
`requeue`, `stale-halt`, `merge-awaiting`, `smokes`, `push`, `queue-card`,
`escalate`, `journal`, `inbox`, `inbox-reply`, `inbox-refuse`,
`transcript-for-decision`, `prune-transcripts`, and `pass` (render the seed
and dispatch one controller agent). Exit codes are `0` acted or nothing
needed doing, `1` failed, `2` bad usage, `3` refused or held. A `3` is a
deliberate answer, not an error.

`preserve` covers the case card 54 missed. A stage that went `stalled`
because its worker exited without a dispatch envelope has no verifier artefact
to read a reason out of, and calling the preserved commit a verifier FAIL
would be untrue, so `preserve_failed_work` in `tick.sh` takes an optional
reason and label and the commit reads `wip(<stage>): attempt N, stalled:
worker_envelope_missing_after_exit`. The index-safe git surgery, the `state/`
exclusion and the append-only wip ref are the tick's, unchanged and not
duplicated.

**The decision journal.** Every mutating verb writes a `phase: "decision"`
line to `<repo>/state/phat-controller-journal.jsonl` **before** attempting
the action, then a `phase: "outcome"` line after, sharing a `decision_id`.
The ordering is the contract: a decision whose action is then refused by a
guard still leaves its decision line, because the journal records intent
rather than effects. Schema at `schemas/decision-journal.json`.

Long runs, measured in days rather than an evening, invite a second
controller reviewing the first, on the theory that a role marking its own
homework drifts. That is not built and building it now would be speculative.
What the journal does is not foreclose it: it costs little while the
controller is alone and it is the whole input a reviewing controller would
need. Retrofitting one afterwards would mean reconstructing intent from
effects, which is not possible.

**The journal is the record; the transcript is one pass's slice of it.** On
the default claude route the dispatched agent's turn history cannot be
scraped off the CLI conversation log -- `claude --output-format json` is
reduced by `claude-token-log.sh` to the final result text before it reaches
disk, and turn history never survives that. So the transcript is not mined
from a log. It is written the same way every other record in this file is:
through the verbs. Every verb call the dispatched agent makes during a
pass -- `inbox-read`, `inbox-reply`, `inbox-refuse`, `preserve`, whatever it
decides -- already journals a decision (rationale, evidence, expected
effect) and its outcome, tagged with that pass's `pass_id`
(`pc_current_pass_id_get`, resolved from a marker file inside the repo
rather than an inherited env var, because `op-fetch`'s `env -i` dispatch
wrapper would otherwise strip it before it reached a verb call the
dispatched agent makes as its own tool call). Once the dispatched process
exits, `pc_transcript_materialize` filters the journal for that `pass_id`
and writes the matching lines to a predictable, indexed path:
`state/phat-controller-transcripts/<pass_id>.log`, with
`state/phat-controller-transcripts/index.jsonl` naming where each pass_id
landed, so `phat-controller.sh transcript-for-decision <repo> <decision-id>`
joins a journal line back to the pass that made it. The raw CLI dispatch log
(`state/logs/phat-controller-pass.log`) still exists, but only for spend
accounting; it is never presented as the record. Transcripts are
private-tier like the rest of `state/` (gitignored, never on the publish
branch, and `*.log` is additionally refused by the pre-commit never-commit
guard on a forced add) and pruned every pass per the mandate's
`retention.transcript_days` (`pc_prune_transcripts`).

**The inbox, and the reply.** A running controller has no attach and no
port to reach it through; `state/phat-controller-inbox/pending/<msg-id>.*`
is the filesystem doing the job instead. `pc_inbox_scan` reads every
pending message at the start of a pass, before anything is decided,
journals that it was read, and carries it into the pass prompt.
`pc_inbox_reply` (or `pc_inbox_refuse`, the same function with a reason) is
the disposition: it writes the answer to
`state/phat-controller-outbox/<msg-id>.md`, readable by whoever sent the
message without attaching to anything, archives the message to
`inbox/processed/`, and journals the decision. A message is an instruction
to consider, never a command to obey — it cannot widen the mandate or lift
a prohibition, the same anti-gaming rule as the negative list arriving
through a new door — and this is enforced structurally rather than by
prose alone: neither inbox verb has any code path that touches a card, so a
message cannot soften a criterion through this route even if an agent tried
to honour one that asked; `pc_card_append`'s append-only guard is what
`rebrief` and `propose-amendment` still answer to.

**The tick lock.** `preserve`, `pc_card_append` (so `rebrief` and
`propose-amendment`), `requeue`, `queue-card`, and the acting half of `push`
take `state/.tick.lock` — the same advisory lock `tick.sh` takes before it
touches a repo — before their git mutation and release it after. This
closes the concurrency hole an ad-hoc minder fell into on 2026-08-25: it
watched for stranded work and, seeing no live agent, preserved it to a wip
branch while the tick was mid-landing the same stage. "No live agent" is not
the same fact as "the tick is not mid-transaction", and the minder's commit
fast-forwarded onto `dev` carrying a `wip(...)` message with no author and
no `Autometta-*` trailers in place of the tick's own proper one — the work
was intact and the record of it was wrong. Every mutating verb now takes the
same lock the tick does: if it is held, the verb skips and says so in the
log and the journal (`held`, or `failed` where a decision line was already
open), never proceeds without it, and never breaks a lock it did not take —
a live holder is left alone; only `acquire_repo_lock`'s own stale-lock
reclaim (dead pid) touches an abandoned one.

**Escalating without blocking.** Two flavours, and choosing between them is
the whole judgement. A *blocking* escalation is `budget_halt` with reason
`controller-escalation`: `halted` is the signal every renderer (dashboard,
agent-ticker, alerts table) already reads, and a halted repo dispatches
nothing further until an operator clears it. It is correct only when carrying
on makes things worse: the same failure repeated past the mandate's
`same_remediation_without_progress_cap`, a spend authority exhausted, a
provider asking for payment. A *non-blocking* escalation is a loud log line
plus a journal entry, and the queue carries on. No second alert channel
exists to drift from the first.

`git-push-check` returning `ASK` is the case that forces the split, and its
three verdicts read directly as a human-presence protocol: `PUSH` act, `ASK`
escalate and carry on with other work, `HOLD` stop and report. Blocking on
`ASK` would be the queue sitting still until morning waiting for an answer
nobody is awake to give, which is the failure this role exists to prevent.

**One skill, two callers.** `skills/phat-controller/SKILL.md` is loaded both
into the rendered prompt of a scheduled pass and into an interactive session
that has been asked to mind the queue, so a conversation and a cron dispatch
read one source of truth rather than two descriptions that drift. It opens
with a table naming which file owns each fact: the seed owns the persona, the
prohibitions, the spend authority and the repo facts; the mandate owns
thresholds and cadence; `phat-controller.sh` owns what the verbs do; the
skill owns how to decide and the formats a decision has to produce. The
difference between the two callers is not the contract, it is who is in the
room: an operator can authorise something the negative list forbids the
controller doing alone, and a headless pass never can.

**The mandate manifest.** A committed template
(`templates/phat-controller-mandate.yaml.tpl`) copied to
`$AUTOMETTA_HOME/phat-controller-mandate.yaml` (gitignored, operator-owned)
on first use. Thresholds and cadence only: the attempt cap, the
repeat-without-progress cap, what counts as metered spend, the pass interval
(read by the installer at provisioning time; re-run it to reschedule a live
LaunchAgent), which repos the controller minds (empty means every enabled
subscriber), the dispatch identity and effort, and the reporting voice.
Budget figures are never restated here: they live in each repo's
`state/budget.json` and the controller's host defaults (card 47). The
`AUTOMETTA_WARDEN_MANDATE` env var and a `warden-mandate.yaml` already in the
controller home are honoured for one release.

**Scheduling.** `autometta phat-controller pass` on its own LaunchAgent
interval (`templates/launchagent-phat-controller.plist.tpl`,
`scripts/install-launchagent-phat-controller.sh`, singleton label
`com.autometta.phat-controller.fleet`, same `AbandonProcessGroup` care as the
tick's own). One pass reads the picture across every enabled subscriber,
decides, acts, and exits. It is not a daemon and it does not watch anything
continuously.

**Offline proof.** `scripts/phat-controller-smoke.sh` runs every fixture with
no auth, network or provider dispatch: the seed rendered for a fresh job, the
refusal when no spend authority is supplied, the drift check on the negative
list, each verb, the journal's decision-before-action ordering demonstrated
by a refused action that still leaves its decision line, the card-58
contract test replaying the evening of 2026-08-24, the transcript-to-journal
index round trip, an inbox message answered and one refused with the card
proven untouched, both directions of tick-lock contention, the 2026-08-25
race replayed against the now-locked `preserve`, the credential grep across
transcripts/inbox/outbox, and transcript retention and the private-tier
publish guard.

## Operational entry points

The `autometta` CLI is the preferred operator surface:

- `autometta init-host`: initialise or refresh the controller home.
- `autometta init <repo>`: initialise host state if needed, subscribe one repo, and create its tmux viewer when `tmux` is available.
- `autometta add-stage <repo> <card>`: add a stage card to the repo queue.
- `autometta tick`: run one cron-safe controller tick.
- `autometta phat-controller <verb>`: the queue minder's verbs (see (k)). `pass` renders the seed and dispatches one controller agent; `picture` prints the mechanical triage picture; `--print-mandate` and `--print-seed` print the resolved mandate and seed without acting.
- `autometta controller-seed --spend-authority TEXT [--token-ceiling N] [--expires ISO8601]`: render the context seed when a job is configured. Refuses, writing nothing, if no spend authority is supplied.
- `autometta status`: print a read-only status table.
- `autometta attach <repo>`: open or create the repo-scoped tmux viewer.
- `autometta tui [repo]`: open the full-screen run, history and controller-message view.

The CLI delegates to these scripts:

- `scripts/tick.sh`: the cron entry point.
- `scripts/phat-controller.sh`: the queue minder's verbs; sources `tick.sh` for its merge, teardown, preservation and state-write mechanics rather than duplicating them.
- `scripts/render-controller-seed.sh`: renders the context seed at configure time and mirrors the machine-readable spend and provider-window bounds into the mandate.
- `scripts/install-launchagent-phat-controller.sh` / `scripts/uninstall-launchagent-phat-controller.sh`: the controller's own LaunchAgent, on a separate schedule and label from the tick's. The installer is where a job is configured, so it fails closed with no seed.
- `scripts/spawn-worker.sh`: helper invoked by `tick.sh` to dispatch one worker per the stage card.
- `scripts/spawn-verifier.sh`: helper invoked by `tick.sh` to dispatch the cross-family verifier.
- `scripts/budget.sh`: helper for reading and updating `state/budget.json` atomically.
- `scripts/init-host.sh`: one-time host controller setup.
- `scripts/subscribe-repo.sh`: per-repo subscription.
- `scripts/add-stage.sh`: idempotent queue insertion.
- `scripts/status.sh`: read-only operator status view.
- `scripts/attach.sh`: optional tmux viewer for status and controller logs.
- `scripts/reap-worktrees.sh`: per-repo sweep of run worktrees nobody came back for. Called after every tick; safe to run by hand with `--dry-run`.
- `scripts/state-branch-smoke.sh`: offline proof that a tick leaves `repo_root`'s HEAD alone and still snapshots its state.

The contract surface remains the state file, budget file, verifier handoff format, subscriber registry, and identity resolution. The CLI is convenience, not a separate state owner.

## Future scope

Items deferred beyond pass 2:

- Multi-machine federation. The current design is single-machine; if a second machine wants to subscribe to the same backlog, that is out of scope.
- Web control UI. The full-screen terminal UI is shipped as `autometta tui [repo]`; a browser-based control surface remains downstream.
- Token estimation before dispatch. The current design enforces `token_cap_total` after the fact (per dispatched process). A pre-dispatch estimator is future scope. This is the residual gap card 31 could not close: `budget_gate_dispatch` guarantees the loop stops within one dispatch's spend of the cap, and nothing short of estimating a dispatch before spawning it can do better.
- Multi-language stage cards. Currently all cards and prompts are English; localisation is future scope.

## New decisions banked by this stage

Three genuinely new design decisions surfaced during this stage that were not previously in any memory entry. Each has a corresponding `memory/decision-*.md` entry committed in the same commit as this document:

1. `state/` directory per repo holds `state.yaml`, `budget.json`, and `verifiers/<stage-id>.json` (banked at `memory/decision-state-dir-per-repo.md`).
2. The tick loop runs as one process per cron fire, with no resident daemon and a singleton subscriber registry at `~/.autometta/`.
3. Four implementation parameters fixed by this design and surfaced by the stage-4 verifier re-brief: working branch `autometta/state`, repair entry point `autometta tick --repair`, per-fire cap config at `~/.autometta/config.yaml`, default stall grace factor 1.5x.
