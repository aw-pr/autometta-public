# Stage card 100: the tick stops costing ninety seconds

## Metadata

- **Authored:** 2026-09-01
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Base branch:** dev
- **Run branch:** autometta/100-the-tick-stops-costing-ninety-seconds
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/tick.sh, scripts/budget.sh, scripts/tick-cost-smoke.sh, docs/tick-loop.md
- **Pairing rationale:** cross-family. A Codex worker does the measurement and
  the surgery; a Claude verifier re-measures independently, because the whole
  deliverable is a number and a worker that reports its own benchmark is
  marking its own homework. The verifier must reproduce the timing itself.
- **Type:** Performance work on the hot path. Behaviour must not change.

## Surfacing concern

One full fleet tick costs **90 seconds**, measured three times on 2026-09-01:
90.20s, 90.22s, 91.54s wall, with 63-64s user and 30-31s system time. Six
subscribers, so roughly 15s per repo, and four of those six have drained
queues and dispatch nothing.

This sets a floor on how responsive the loop can be. The tick cadence was cut
from 300s to 30s the same day, and the effective cadence landed at ~120s
rather than 30s, because launchd will not start a job that is still running:
the observed period is `max(interval, duration)` plus interval granularity.
The 30s setting is already self-tuning, so **every second removed from the
tick is a second off the loop's response time, with no further configuration.**

Per-stage that matters: three role transitions each wait for a tick, so the
tick duration is paid three times per stage.

## What has already been ruled out

Do not re-run these; they are measured, and the point of listing them is that
the obvious answers are wrong.

| Suspect | Measured | Verdict |
|---|---|---|
| `yq` parse of `state/state.yaml` (894 lines) | 0.01s | not it |
| `jq` over the same as JSON | 0.00s | not it |
| `scripts/quota-window.sh` (codex quota) | 0.00s | not it |
| `scripts/aggregate-dashboard.sh` for one repo | 0.02s | not it |
| `git fetch --dry-run` on a subscriber | 1.18s | not it |
| `git hash-object -w` (state snapshot) | 0.00s | not it |
| `git status --porcelain` (reaper) | 0.01s | not it |
| Lock contention from a duplicate LaunchAgent | removed; timing unchanged | not it |
| A fixed `sleep` in the tick path | none found | not it |

`sample` on the running tick shows only bash frames and bash children -- no
single external command dominates. 30s of *system* time against 63s of user
time is the signature of process creation, not computation.

**The one lead, and its problem.** `bash -x` over a full tick recorded 2,349
commands, which cannot account for 90 seconds at any plausible fork cost. That
trace was almost certainly taken while the LaunchAgent held the per-repo locks,
so most repos were skipped and the trace is not representative. Re-take it with
the agent unloaded (`launchctl unload
~/Library/LaunchAgents/com.autometta.tick.fleet.plist`, and **load it again when
you are done** -- the loop is live) so the trace covers the real path.

## Objective

Find where the 90 seconds actually goes, and cut it. The measurement is the
first deliverable and the cut is the second; a profile that finds nothing
actionable is a legitimate outcome, reported as such, and is worth more than a
speculative rewrite.

**Target: under 30 seconds for a six-repo fleet tick, with no behaviour change.**
Report the number you reach whether or not it meets the target.

## Inputs (read these in your own context)

- `scripts/tick.sh`, particularly `process_repo` and everything it calls
- `scripts/budget.sh` -- `budget_increment_tick` and the gate helpers
- `docs/tick-loop.md` sections (a) and (b), the contract you must not break
- `scripts/tick-smoke.sh` and the other tick smokes, which define current
  behaviour

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. A profile that names where the time goes, with numbers, committed as a
   section in `docs/tick-loop.md`. Method is yours; a timestamped `PS4` trace
   needs bash 5 (`/opt/homebrew/bin/bash`), because the script runs under
   `set -u` and macOS `/bin/bash` 3.2 has no `EPOCHREALTIME`.
2. The reduction itself, in `scripts/tick.sh` and wherever else the profile
   points.
3. `scripts/tick-cost-smoke.sh`: asserts a fleet tick over a fixture of
   drained repos completes inside a stated budget. It must fail against the
   pre-change tick. Pick the threshold from your measurement and say why.
4. The `docs/tick-loop.md` note explaining the cost model, so the next person
   changing the cadence knows what sets the floor.

## Constraints

- **No behaviour change.** Same dispatches, same state writes, same log lines
  for the same inputs. This is the hot path of an unattended loop.
- An idle repo may take a fast path, but "idle" must be derived from state the
  tick already reads, not from a new cache that can go stale. A wrong fast
  path that skips a dispatchable repo is far worse than a slow tick.
- Keep the per-repo lock semantics exactly as they are.
- No new runtime dependency.

## Acceptance criteria

1. `bash scripts/tick-smoke.sh` and every other existing tick smoke pass
   unchanged.
2. A fleet tick over the real six subscribers is measurably faster, with
   before-and-after numbers from the same machine, three runs each, reported
   as wall/user/sys.
3. `scripts/tick-cost-smoke.sh` passes on the change and fails against the
   pre-change `tick.sh`. Record both runs.
4. Behaviour is unchanged on a repo with a pending stage: dispatch still
   happens on the first tick that sees it, and the log lines are the same.
5. `docs/tick-loop.md` carries the profile and the cost-model note.
6. `clock_ticks_used` still counts only work ticks and `idle_ticks_used` only
   idle ones, per card 37. A faster tick must not start charging idle polls
   against the work cap.

## Contract test

- **Test file:** scripts/tick-cost-smoke.sh
- **Assertions digest:** a fleet tick over drained fixture repos completes
  inside the stated budget; the pre-change tick exceeds it.

## Out of scope

- Changing the tick cadence or the LaunchAgent. That is already set to 30s and
  self-tunes to whatever this card achieves.
- The tick-cap or idle-cap accounting, beyond not breaking it.
- Pipeline pairing.
- Any change to what a tick decides. Only what it costs to decide it.

## Budget

- **Worker wall-clock:** 90 minutes
- **Verifier wall-clock:** 45 minutes

## Escalation

If the profile shows the cost is irreducible without changing behaviour -- for
instance if it is spread evenly across thousands of necessary subshells with no
hot spot -- record the profile, make no speculative change, and stop. A truthful
"this is what a bash tick costs, and here is the evidence" closes the question
for good and is the more valuable outcome. Do not rewrite the tick in another
language to hit the target; that is a much larger decision than this card
carries, and the profile is what would justify proposing it.

## Verifier handoff

The deliverable is a number, so measure it yourself; do not accept the worker's
benchmark. Run the before-and-after timings from your own shell, three runs
each, and check the machine was otherwise idle -- a tick timed while another
tick, worker or verifier is running is not a clean measurement, and that is
exactly how the 2,349-command trace above came to mislead.

Two things to disbelieve specifically. First, that behaviour is unchanged:
diff the log output of a pre-change and post-change tick over the same fixture
and confirm they match line for line, because "faster" is easy to achieve by
quietly doing less. Second, any claimed fast path for idle repos: construct a
repo that *looks* idle by whatever signal the fast path uses but has a
dispatchable pending stage, and confirm it still dispatches on the first tick.
