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

A tick is a single non-interactive invocation of `autometta tick`, which delegates to `scripts/tick.sh`. The tick:

1. Reads the current `state/state.yaml` of the repo it is operating on.
2. Reads the current `state/budget.json` of the same repo.
3. Checks the budget. If any of `token_cap_total`, `wall_clock_cap_seconds`, `clock_tick_cap`, or `consecutive_failure_cap` is exhausted, the tick writes a stall marker into `state.yaml` and exits without dispatching.
4. Selects exactly one transition to make. The transition rule is the simplest possible: if a stage is `in_progress`, advance it by running its verifier (if the worker has reported done) or by checking it for stall; if no stage is `in_progress`, claim the next `pending` stage and dispatch its worker; if no `pending` stage exists, the queue is drained and the tick exits cleanly.
5. Updates `state.yaml` and `budget.json` atomically. "Atomically" means: write to a temp file in the same directory, then `mv` into place. The `mv` is the atomicity primitive on POSIX filesystems given same-directory restraint.
6. Snapshots the state update onto the `phat-controller/state` ref, using the per-agent author attribution from the global dev rules. It does this with git plumbing and never checks the branch out: see (j).
7. Exits. The next tick is the next cron fire.

A tick is one transition, not a loop within the tick. This is the "cron + tick > daemon" belief from `docs/philosophy.md`. The cron schedule defines the loop; the script is a one-shot.

## (b) The state file `state.yaml`

**Location.** Per repo: `state/state.yaml` at the repo root. State lives in the repo it describes; one repo's state is never visible to another repo's tick except through the subscriber index (see section (f)).

**Schema.** `schemas/state.yaml.json` (JSON Schema draft 2020-12). The schema is committed in this stage; the tick script (stage 5) will validate `state.yaml` against it on every read.

**Lifecycle.** The file is created when a repo first subscribes to a `phat-controller` instance (see section (f)). It is mutated only by `autometta tick`; humans may read but should not edit, because human edits without a tick will silently desync `tick_count` from `last_tick_at`. If a human must edit, they must run `autometta tick --repair`.

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

**Dispatch configuration fault.** A worker or verifier that exits within two seconds, writes no completion artefact, leaves only a tiny log (at most 512 bytes), and reports a recognised CLI usage, missing-executable, or auth-route error has not attempted its role. The tick marks the stage `stalled`, records `dispatch_configuration_fault:<role>` on the stage, and halts the repo with `dispatch-configuration-fault` so an operator fixes the command or credentials. For a verifier, the attempt reserved before spawn is returned. The halt prevents an uncounted fault from looping forever. A crash or genuine verification failure that does not satisfy the full conjunction retains its attempt and follows the existing retry cap of three.

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

## (i) Observability surface

The controller is observable through files it already owns:

- `state/state.yaml` for current stage, statuses, identities, PIDs, halt state, and tick counters.
- `state/budget.json` for budget caps, failure counters, and halt reason.
- `state/logs/<stage-id>-worker.log` and `state/logs/<stage-id>-verifier.log` for process output.
- `state/verifiers/<stage-id>.json` for structured verifier reports.
- `${PHAT_CONTROLLER_HOME:-$HOME/.phat-controller}/log/tick-YYYY-MM-DD.log` for controller-level tick output.
- `phat-controller/state` for committed state snapshots (see (j) for what is in one).

`autometta status` is the read-only operator view over those files. `autometta init <repo>` creates a detached tmux viewer named `autometta-<project-name>` when `tmux` is available. `autometta attach <repo>` opens or creates that same viewer, tails the latest controller log, and opens a status pane. It is deliberately downstream of the filesystem state; it does not dispatch, supervise, or retry work.

This gives the operator an attachable cockpit without creating a resident controller daemon.

## (j) The state snapshot, and keeping out of the shared tree

`repo_root` is the operator's checkout. The loop dispatches into an ephemeral sibling worktree precisely so no worker or verifier touches it, and two paths in the tick have to hold the same line: the state snapshot, and the fast-forward of the base branch on PASS.

**The snapshot never checks anything out.** `commit_state_branch` used to run `git checkout -B phat-controller/state` in `repo_root`, commit, and restore the operator's branch from an `EXIT` trap. The window is a fraction of a second, and the fleet job opens it roughly 288 times a day per subscriber in a tree a person is expected to be working in. On 2026-08-23 an orchestrator commit authored against `dev` landed on `phat-controller/state` inside that window (`2d4dc08`). `git push origin dev` answered "Everything up-to-date", which is how it was noticed; the next tick's `checkout -B` would have reset the ref past it and made it unreachable. It was recovered as a cherry-pick, `1efd82a`, within minutes.

The replacement builds the commit with plumbing: `git add` into a throwaway `GIT_INDEX_FILE`, `git write-tree`, `git commit-tree`, one `git update-ref` with the previous tip as its compare-and-swap guard. No checkout, no HEAD move, no write to `repo_root`'s index or working tree, and nothing for a concurrent operator commit to race with. A dedicated worktree for the ref would also have kept HEAD still, but it is a fixture to create, maintain and reap, and the state files live in `repo_root/state`, so it would have to copy them across on every tick.

**What a snapshot holds.** `state/state.yaml` and `state/budget.json`, plus whatever of `state/verifiers` and `state/handoffs` the repo does not ignore. Not `state/logs`, `state/cost-log.jsonl`, `state/active-agents`, `state/recent-agents` or `state/heartbeat.json`. The commit body names exactly what was captured, so the ref never claims more than it holds, and an unchanged state adds no commit.

`state.yaml` and `budget.json` are gitignored in every subscriber, so the snapshot stages them with `git add -f`. That is deliberate. Before this, the plain `git add state/state.yaml` was a silent no-op (`docs/lessons.md` gotcha 10) and the ref held only the repo tree it had been reset to: the branch documented here as "committed state snapshots" had never contained one line of state. Forcing them onto this ref does not make them tracked on any working branch, `.gitignore` still governs every operator commit, and whether `state.yaml` should be tracked remains an open question this did not answer. The snapshot is local: the loop never pushes the ref, and nothing else should.

`state/state.yaml.bak`, the rolling copy `state_apply_json` writes, stays. It recovers the previous good state within the same tick; the snapshot ref recovers a history of them.

**The fast-forward never checks base out either.** On PASS, `finalize_run_worktree` advances `base_branch` to the run branch when base has not moved since dispatch. It used to `git checkout "$base_branch"` in `repo_root` to do it, which moves an operator working on some other branch onto base mid-session. A fast-forward is a ref move, so the tick does the ref move where it can: base checked out in `repo_root` is merged in place (HEAD stays on the branch it was already on, and the tree has to be updated anyway), base checked out in another worktree is merged there, and base checked out nowhere is moved with `git update-ref` behind an ancestry check.

**When base has moved.** That is the common case, not an edge case: any orchestrator commit to base between dispatch and PASS produces it. The run branch is pushed to `origin` and left standing, and the stage's `integration` record in `state.yaml` says so:

```yaml
integration:
  state: awaiting        # or merged
  base_branch: dev
  run_branch: autometta/39-loop-moves-head-in-the-shared-tree
  head: 0d1e2f3...
  pushed: true
  recorded_at: 2026-08-23T14:02:11Z
```

`autometta status` prints an `awaiting integration` line per outstanding stage under the repo's row. Before the record existed the stage read as plain `completed` everywhere an operator looks, and the only trace of the outstanding merge was one appended line in `HANDOFF.md`.

**Reaping.** `scripts/reap-worktrees.sh` runs after every tick as part of `sweep_repo_retention`, and by hand with `--dry-run`. It removes a run worktree whose stage is finished with it, through `requeue-stage.sh --worktree-only` so that removal has one implementation. It refuses to remove a worktree whose stage is `in_progress`, one holding uncommitted work that is not the known `state/` symlink artefact (a verifier FAIL leaves the worker's diff uncommitted by design, and that diff is what the operator inspects), one whose run branch holds commits that are not on base, and one whose stage it cannot find in `state.yaml`. Those it reports instead, on every tick until someone deals with them. When a person merges an `awaiting` branch by hand, the next sweep notices the containment, closes the record out to `merged`, and collects the worktree.

## (k) The warden role

The tick loop dispatches and verifies; it does not decide that a verifier
FAIL is a card defect rather than a work defect, merge an integration a
person would otherwise merge by hand, clear a stale pause, or keep the
queue fed. On 2026-08-24 an interactive orchestrator session did all of
that on a 15-minute check cadence while the operator left the queue running
unattended. The cadence and the checklist worked; the warden is that
checklist, packaged as a second scheduled pass rather than a person.

**Cron plus tick, same as the loop itself.** `scripts/warden.sh`, dispatched
as `autometta warden` on its own LaunchAgent interval
(`templates/launchagent-warden.plist.tpl`,
`scripts/install-launchagent-warden.sh`, singleton label
`com.autometta.warden.fleet`, same `AbandonProcessGroup` care as the tick's
own). One pass reads state across every enabled subscriber, performs
**at most one** remediation, writes state, exits. It is not a daemon and it
does not watch anything continuously.

**The whole list, closed by construction:**

1. **Requeue a `verifier_failed` stage after triage.** The only remediation
   that dispatches an agent. The agent reads the verifier artefact and the
   preserved WIP (`wip_commit`, card 53), judges work defect vs card defect
   vs inconclusive, and writes a structured decision envelope --
   `scripts/warden.sh` performs the actual mutation (append the re-brief,
   commit it narrowly to `repo_root` attributed to `Autometta Warden
   <autometta-warden@local>`, run `requeue-stage.sh`), never the agent
   itself. A card-defect verdict appends and commits a `PROPOSED-AMENDMENT`
   block and requeues nothing: only the operator or an interactive
   orchestrator turns a proposal into a criterion change. The commit stages
   only the one card path, never a broad `git add`, so an operator's own
   unrelated dirty file in `repo_root` is never swept in; a commit that
   fails (an unexpected checked-out branch, a dirty index) leaves the
   append on disk and logs loudly rather than losing it. It does not requeue
   unless that card-only commit succeeds.
2. **Merge a conflict-free `awaiting` integration.** Checked with
   `git merge-tree --write-tree` before any ref moves; a conflict is
   surfaced, never resolved by the warden. A clean fast-forward reuses
   `finalize_run_worktree`; the ordinary `awaiting` case, where base and the
   run branch diverged cleanly, produces a two-parent merge commit attributed
   to the warden. It then tears down through the existing helper, runs every
   offline `scripts/*-smoke.sh` in the repo (the live, metered
   `sdk-cache-smoke.sh` is excluded), and pushes the exact base refspec per
   `git-push-check` when it is on `PATH` -- never without it.
3. **Clear a pause or halt that is provably stale.** Reuses
   `budget_pause_active` and `budget_ensure_window` verbatim rather than
   re-deriving staleness: those are the same audited functions a regular
   tick already calls, and a second implementation of "is this stale" could
   only drift from the first. This remediation exists because nothing
   guarantees a tick has run recently enough to have already done it for a
   given repo.
4. **Queue the next `PLAN.md` card** when a repo's queue is empty and the
   plan names an unqueued card whose stated gate (`blocked by`, `gated on`,
   `after`, followed by stage numbers) is satisfied -- checked against
   `PLAN.md`'s own `done` column first (authoritative for cards never
   dispatched through `state.yaml`) and `state.yaml`'s `completed` status
   second. A gate the warden cannot parse is left unmet, never guessed.

Nothing else. The action list lives in `scripts/warden.sh` and nowhere
else -- not in the rendered triage prompt (`templates/warden-prompt.md`),
not in the mandate manifest below. Adding a fifth action is a card.

**One remediation per pass, in a fixed priority order:** clear-stale (3),
merge-awaiting (2), requeue-verifier-failed (1), queue-next-card (4).
Unblocking dispatch matters more than anything that dispatch would enable;
landing already-verified work is the cheapest win; triage is the only
remediation that spends tokens, so it comes after the free ones; queueing
fresh work only matters once a queue is confirmed empty. The order is
hard-coded in `warden_pass`, not a mandate knob.

**No silent action.** Every applied remediation appends one attributed JSON
line to `<repo>/state/warden-actions.jsonl`. Card amendments and divergent
merges also carry the warden as git author; the runtime audit covers actions
such as stale-pause clears, fast-forwards and queue additions that are state
writes rather than new commits.

**Escalation, not a third attempt.** The two things the objective names as
needing a human: repeated failure and metered spend.

- *Repeated failure* is tracked per stage in `<repo>/state/warden-state.json`
  (gitignored): a counter per `(stage_id, remediation)`, dropped once the
  stage reaches a resolved state (`completed`/`superseded` for remediation
  1, integration leaving `awaiting` for remediation 2). At the mandate's
  `same_remediation_without_progress_cap` (default 2), the next application
  escalates instead. A `verifier_failed` stage at or above the mandate's
  `attempt_cap` escalates immediately rather than triaging again.
- *Metered spend* is checked before the one remediation that spends
  anything. The normal `budget_gate_dispatch` guards triage exactly as it
  guards a worker or verifier, and the returned token usage is charged back
  to `state/budget.json` before the triage verdict is applied. The mandate
  classifies metered auth routes, may forbid them even within budget, and
  carries the provider-payment signal pattern that escalates rather than
  acting on a returned envelope. `triage_dispatch_enabled` can turn triage
  off entirely.

Escalation is `budget_halt "$repo_root" "warden-escalation"` -- the loud log
line acceptance criteria ask for is the `ESCALATION:` line in
`warden-YYYY-MM-DD.log`, and the ticker-visible alert is `halted` itself,
the signal every renderer (dashboard, agent-ticker, alerts table) already
reads. No second alert channel exists to drift from the first. A halted
repo dispatches nothing further -- worker, verifier, or warden -- until an
operator clears it.

**The mandate manifest.** A committed template
(`templates/warden-mandate.yaml.tpl`) copied verbatim to
`$PHAT_CONTROLLER_HOME/warden-mandate.yaml` (gitignored, operator-owned) the
first time the warden runs with no operator copy present. It holds
escalation thresholds including what counts as metered spend, pass cadence
(read by the installer at provisioning time; re-run it to reschedule a live
LaunchAgent), which repos the warden minds (empty means every
enabled subscriber, the same convention a drain's `repos` list uses), the
triage dispatch identity, and the reporting voice for surfaced summaries.
Budget figures are never restated here: they live in each repo's
`state/budget.json` and the controller's host defaults (card 47). The
warden prompt is rendered from template plus mandate at dispatch time for
either Claude or Codex, through the same family auth routes and bounded by
the mandate's effort and timeout. Editing the mandate changes behaviour at
the next pass with no code edit --
the action list above is the one thing the mandate cannot touch.

**The interactive side.** The `autometta-warden` skill loads the same
mandate and the same closed action list into an interactive orchestrator
session, so a human-driven minding session (as run on 2026-08-24) and the
scheduled pass operate under one contract. The skill states plainly that an
interactive orchestrator may exceed the list only with the operator in the
conversation -- the warden itself never does.

## Operational entry points

The `autometta` CLI is the preferred operator surface:

- `autometta init-host`: initialise or refresh the controller home.
- `autometta init <repo>`: initialise host state if needed, subscribe one repo, and create its tmux viewer when `tmux` is available.
- `autometta add-stage <repo> <card>`: add a stage card to the repo queue.
- `autometta tick`: run one cron-safe controller tick.
- `autometta warden [--print-mandate]`: run one warden pass (see (k)); the flag prints the resolved mandate without acting.
- `autometta status`: print a read-only status table.
- `autometta attach <repo>`: open or create the repo-scoped tmux viewer.

The CLI delegates to these scripts:

- `scripts/tick.sh`: the cron entry point.
- `scripts/warden.sh`: the warden's cron entry point; sources `tick.sh` for its merge/teardown/state-write mechanics rather than duplicating them.
- `scripts/install-launchagent-warden.sh` / `scripts/uninstall-launchagent-warden.sh`: the warden's own LaunchAgent, on a separate schedule and label from the tick's.
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
- Web UI or full TUI for the controller. The current design is filesystem, `git log`, and a read-only shell status view; richer visualisation is downstream.
- Token estimation before dispatch. The current design enforces `token_cap_total` after the fact (per dispatched process). A pre-dispatch estimator is future scope. This is the residual gap card 31 could not close: `budget_gate_dispatch` guarantees the loop stops within one dispatch's spend of the cap, and nothing short of estimating a dispatch before spawning it can do better.
- Multi-language stage cards. Currently all cards and prompts are English; localisation is future scope.

## New decisions banked by this stage

Three genuinely new design decisions surfaced during this stage that were not previously in any memory entry. Each has a corresponding `memory/decision-*.md` entry committed in the same commit as this document:

1. `state/` directory per repo holds `state.yaml`, `budget.json`, and `verifiers/<stage-id>.json` (banked at `memory/decision-state-dir-per-repo.md`).
2. `phat-controller` runs as one process per cron fire, no resident daemon, with a singleton subscriber registry at `~/.phat-controller/` (banked at `memory/decision-phat-controller-no-daemon-subscriber-registry.md`).
3. Four implementation parameters fixed by this design and surfaced by the stage-4 verifier re-brief: working branch `phat-controller/state`, repair entry point `autometta tick --repair`, per-fire cap config at `~/.phat-controller/config.yaml`, default stall grace factor 1.5x (banked at `memory/decision-tick-implementation-parameters.md`).
