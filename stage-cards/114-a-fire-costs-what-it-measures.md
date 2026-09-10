# Stage card 114: a fire costs what it measures

## Metadata

- **Authored:** 2026-09-06
- **Orchestrator:** Claude Fable 5.1 <claude-fable-5-1@local>
- **Worker:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Verifier:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Base branch:** dev
- **Run branch:** autometta/114-a-fire-costs-what-it-measures
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/tick.sh, scripts/heartbeat.sh, scripts/tick-profile-smoke.sh, scripts/tick-profile.sh, docs/tick-loop.md, stage-cards/114-a-fire-costs-what-it-measures.md
- **Pairing rationale:** cross-family, and the Codex Terra seat verifies because it authored card
  100 and measured the tick at 18 seconds on the bench; it is the seat best
  placed to say why the live loop reads 46.
- **Type:** Loop latency. Touches `scripts/tick.sh`, so serial.

## Surfacing concern

Card 100 cut the fleet fire from 90 seconds to 18 on an idle six-repo
bench (`state/verifiers/100-the-tick-stops-costing-ninety-seconds.json:17`)
and the plist interval was set to 30 seconds. Live fires on 2026-09-02 and
2026-09-06 take a median of 46 seconds with four subscribers and one stage
in flight. launchd does not overlap fires, so the effective period is
`max(interval, duration)`: 46 seconds, not 30 and not 18. A stage needs
three to five fires, so the loop's own latency is two to four minutes per
landed stage. Reading the fleet log, the autometta-testing reap line lands
at about 14 seconds and emergence-lab's at 15; the remaining 30 seconds
are spent after emergence-lab's `process_repo` begins, in heartbeat writes,
`commit_state_branch` and reaping, and nobody has profiled that tail since
100 landed.

## Objective

The tick reports where each fire's seconds go, per repo and per phase,
and the cheapest fix that brings a live four-subscriber fire under 15
seconds is landed.

## Inputs (read these in your own context)

- `scripts/tick.sh`, `main` and `process_repo`, plus `commit_state_branch`
  and the reap call
- `scripts/heartbeat.sh`
- `scripts/tick-cost-smoke.sh` (card 105 is correcting its baseline; adopt
  whatever is on `dev` when you start)
- `docs/tick-loop.md:40-56`, card 100's findings and its ruled-out list
- `~/.phat-controller/log/tick-2026-09-06.log`, for the live shape

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. `scripts/tick.sh` emits, when `AUTOMETTA_TICK_PROFILE=1`, one log line
   per repo per phase with elapsed milliseconds (`profile repo=<r>
   phase=<p> ms=<n>`), and a fire summary line. Off by default; zero cost
   when off beyond a `[[ ]]` test.
2. `scripts/tick-profile.sh`: runs one fire with the profile on and prints
   a table sorted by cost. This is the tool the next person uses.
3. The measured largest phase fixed, without changing what the tick
   decides. Attempt 1 already located it and its finding stands: `state.yaml`'s
   `tick_count` and `last_tick_at` are bumped on *every* tick including idle
   ones, so `commit_state_branch`'s tree-comparison short-circuit never
   fires and every single tick writes a real git commit to the state
   snapshot branch -- roughly nine git subprocesses plus an `agent-whoami`
   shell-out, for a tick where nothing happened. Skip the snapshot when only
   bookkeeping fields changed. If the profile shows a larger phase than this
   one, fix that instead and say so in the envelope; do not do both.
4. `scripts/tick-profile-smoke.sh`, new, offline. It gets its own file
   rather than a case in `scripts/tick-cost-smoke.sh` because the gate
   allows one frozen block per file and that file's block belongs to card
   105. Folding these assertions into 105's block and re-pointing its marker
   would make the block claim to be this card's spec while containing
   another card's assertions.
5. `docs/tick-loop.md`: the profile flag, the tool, the measured table, and
   the effective-period rule.

## Constraints

- No behaviour change to any transition; this card makes the tick faster
  at doing exactly what it does now.
- **Do not touch the operator's LaunchAgent.** Measure against the
  throwaway fleet the smoke builds under a fake `PHAT_CONTROLLER_HOME`,
  which contends with nothing. Unloading a running fleet to measure it is
  not a thing a stage may do on its own authority, and it is not needed:
  every acceptance criterion below is reachable offline.
- Do not change the plist interval in this card.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. Against the smoke's four-repo fixture fleet, `AUTOMETTA_TICK_PROFILE=1`
   prints per-phase lines whose sum is within 10% of the fire's wall clock,
   plus a fire summary line. With the flag unset, no profile line appears.
2. A second consecutive idle fire writes no new commit to the state
   snapshot branch, and idle fires still increment `tick_count`. The fix
   removes the cost without changing what the tick decides.
3. `scripts/tick-profile.sh` runs against the fixture fleet, exits zero, and
   prints a cost table.
4. `scripts/tick-profile-smoke.sh` passes, and fails against the pre-change
   `scripts/tick.sh`.
5. Every other smoke under `scripts/` is no more red than on clean `dev`,
   `scripts/tick-cost-smoke.sh` included.
6. The envelope reports the before and after figures from the fixture
   fleet, and names the phase that is largest after the fix.

## Contract test

- **Test file:** scripts/tick-profile-smoke.sh
- **Assertions digest:** `sha256:e1826e5037895625b620edc8804929966f05aa8af97379f7f6fe174ba28edb11`

The file and its frozen block are **already written**, by the orchestrator,
before any implementation exists. Do not author, extend or edit the block:
satisfy it by changing the implementation. It currently fails at the first
assertion, which is correct -- the instrumentation does not exist yet.
Fixtures, helpers and scaffolding you need may be added outside the markers.
If you become convinced an assertion is wrong, stop and surface it as a
blocker rather than editing it; the verifier recomputes this digest and
fails the stage if the assertions moved.

## Out of scope

- Triggering a tick on agent exit instead of on an interval. Record where
  the hook would go; it is a separate card.
- The 90-second figure; that is closed.

## Budget

- **Worker wall-clock:** 90 minutes
- **Verifier wall-clock:** 45 minutes

## Escalation

If the profile shows the cost is inside a single `git` or `yq` call that
cannot be avoided, report the figure and stop at deliverables 1, 2 and 5;
a fire that is measured is worth landing without the fix.

## Verifier handoff

Re-measure yourself: unload the agent, run three fires with the profile
on, reload the agent. Your table should agree with the worker's within
noise. The wrong pass is a fix that skips `commit_state_branch` when
something *did* change; run `scripts/state-branch-smoke.sh` and diff the
state branch after a real transition.

## Family-specific notes

None

## Seat history (2026-09-06)

The Codex subscription closed at 10:31Z and this batch was re-seated onto
Claude alone; when Claude session windows then drained faster than the batch
was sized for, the verifying seat moved to the free local route
(`gpt-oss:120b` via `codex exec --oss`). The Codex window reopened the same
afternoon and the card is back on the seats it was authored with. Nothing
about the work changed across either move.

## Re-brief (2026-09-06)

Attempt 1 stalled rather than failing: the worker stopped to ask whether it
could `launchctl unload` the operator's live fleet job, and asked in prose
instead of writing an escalation envelope, so the tick recorded
`worker_envelope_missing_after_exit`. The instinct was right and the card
was wrong to require it. Three things change.

1. **The live fires are gone.** The card asked for three fires against the
   real four-subscriber fleet with the LaunchAgent unloaded. That pauses the
   loop running every other stage, and it is unnecessary: the smoke builds
   its own fleet under a fake `PHAT_CONTROLLER_HOME` and contends with
   nothing. Acceptance is entirely offline now.

2. **The fix is named.** Attempt 1 spent 1.5M tokens and found it before it
   stopped: the idle-tick bookkeeping bump defeats `commit_state_branch`'s
   short-circuit, so every tick commits. Deliverable 3 records that finding
   rather than making the next worker re-derive it.

3. **The contract test moves to its own file and is authored here.** The
   card previously told the worker to write its own frozen block in
   `scripts/tick-cost-smoke.sh`, which both contradicts
   `docs/dispatch-contract.md:131` and collides with card 105's block in
   that file. See card 131 for the template defect behind the first half.

If a live measurement is genuinely wanted later, it is a separate card that
runs when the queue is empty, and it belongs to the operator to schedule.
