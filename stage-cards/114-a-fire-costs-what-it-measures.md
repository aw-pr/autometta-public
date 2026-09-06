# Stage card 114: a fire costs what it measures

## Metadata

- **Authored:** 2026-09-06
- **Orchestrator:** Claude Fable 5.1 <claude-fable-5-1@local>
- **Worker:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Verifier:** Claude Opus 5 <claude-opus-5@local>
- **Base branch:** dev
- **Run branch:** autometta/114-a-fire-costs-what-it-measures
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/tick.sh, scripts/heartbeat.sh, scripts/tick-cost-smoke.sh, scripts/tick-profile.sh, docs/tick-loop.md, stage-cards/114-a-fire-costs-what-it-measures.md
- **Pairing rationale:** cross-model, single family (re-seated 2026-09-06, see below), and the verifying seat verifies because it authored card
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
3. The measured largest phase fixed, if it is fixable without changing
   what the tick decides: caching a `git` query, skipping
   `commit_state_branch` when nothing changed, batching heartbeat writes,
   or whatever the profile says. Record the before and after figures in the
   envelope from three live fires each.
4. `scripts/tick-cost-smoke.sh` gains a case asserting the profile lines
   appear when the flag is set and not otherwise. Frozen block around the new
   assertions.
5. `docs/tick-loop.md`: the profile flag, the tool, the measured table, and
   the effective-period rule.

## Constraints

- No behaviour change to any transition; this card makes the tick faster
  at doing exactly what it does now.
- Profile with the LaunchAgent unloaded so your fires do not contend with
  the live loop, and **load it again afterwards**; put the `launchctl`
  lines you ran in the envelope. Card 100's trace was probably taken under
  contention and that is why its lead was weak.
- Do not change the plist interval in this card.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. `AUTOMETTA_TICK_PROFILE=1 autometta tick` prints per-phase lines whose
   sum is within 10% of the fire's wall clock.
2. Three live fires with the profile off, after the fix, have a median under
   15 seconds with the current four enabled subscribers, or the envelope
   explains exactly which phase remains and why it cannot move without a
   behaviour change.
3. `scripts/tick-cost-smoke.sh` passes and its new case fails against the
   pre-change `tick.sh`.
4. `launchctl list` shows the fleet job loaded at the end of the run.
5. Every other smoke under `scripts/` is no more red than on clean `dev`.

## Contract test

- **Test file:** scripts/tick-cost-smoke.sh
- **Assertions digest:** frame the assertions in a block between the begin
  marker and the end marker, the begin marker naming this card by its
  `card=stage-cards/114-a-fire-costs-what-it-measures.md` field, and replace this line's text with the real
  digest printed by `scripts/check-contract-test-gate.sh print scripts/tick-cost-smoke.sh`. Do not
  write a `sha256:` comment inside the block, and do not spell the marker
  tokens anywhere in this card's prose; the card is in your path claims for
  exactly this edit.

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

## Re-seat (2026-09-06, Codex subscription exhausted)

Both Codex seats were unavailable from 10:31Z with the subscription window
closed until 14:49Z, and every card in this batch carried one, so the queue
could not move. On the operator's instruction the batch was re-seated onto
Claude alone: high-effort cards run Opus as worker and Sonnet as verifier,
the rest run Sonnet as worker and Opus as verifier, so worker and verifier
are never the same model.

What this keeps: the sandbox boundary, which is what makes worker
self-verification structurally impossible, is a property of the dispatch and
not of the vendor, so it is untouched. What it costs: judgement diversity.
A Claude verifier shares training and failure modes with a Claude worker in
a way a Codex verifier did not, so a wrong assumption the worker makes is
likelier to survive verification. Two different Claude models recover part
of that and not all of it. Read this card's acceptance criteria as needing
more, not less, evidence than usual.
