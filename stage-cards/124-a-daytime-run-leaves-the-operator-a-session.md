# Stage card 124: a daytime run leaves the operator a session

## Metadata

- **Authored:** 2026-09-06
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Verifier:** Codex GPT-5.6 Sol <codex-gpt-5-6-sol@local>
- **Base branch:** dev
- **Run branch:** autometta/124-a-daytime-run-leaves-the-operator-a-session
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/quota-window.sh, scripts/tick.sh, scripts/drain.sh, scripts/session-window-smoke.sh, templates/phat-controller-mandate.yaml.tpl, docs/tick-loop.md, docs/runbook.md, stage-cards/124-a-daytime-run-leaves-the-operator-a-session.md
- **Pairing rationale:** cross-model, single family. Seats deviate from the
  batch's effort rule, which puts Opus on the worker seat for a high-effort
  card, and the deviation is deliberate: the failure this card must not ship
  is a guard that silently fails open, which is caught by verification
  rather than by construction. `window_reserve` has been sitting at
  `action: observe` doing exactly that, and a second guard with the same
  defect would be worse than none. Opus verifies.
- **Type:** Spend guard. Touches `scripts/tick.sh`, so serial.

## Surfacing concern

The reserve mechanism already exists and currently protects nothing.
`quota_reserve_settings` (`scripts/quota-window.sh:33-50`) reads
`window_reserve.percent` and `window_reserve.action` from the controller
mandate; `quota_gate_reading` (`:52-`) holds a dispatch only when a known
window is inside a non-zero reserve under `action: hold`, and fails open on
unknown, on zero and on `observe`. The live mandate reads `percent: 10,
action: observe`, so every daytime dispatch has been logging a reading and
proceeding regardless.

Two things follow, and the operator hit both on 2026-09-06:

- **A run can eat the session the operator needs for their own work.**
  Claude session windows are being consumed faster than they were, and the
  loop has no notion that some of a window belongs to the human.
- **The reserve is a single number with no sense of time.** The right
  reserve at 14:00, when the operator wants to work, and at 23:00, when the
  intent is to spend the window down deliberately, are not the same number.
  Today one value has to serve both.

There is no overnight stop in this repo at all. The 01:00 stop used on
emergence-lab on 2026-09-03 was a hand-installed LaunchAgent that did not
remove itself (its own `bootout` killed the script before the `rm`) and had
to be cleared by hand the next morning. That is the prior art and it is not
good enough to ship to subscribers.

The drain is the nearest existing idea and it is deliberately the opposite
one: `scripts/drain.sh` raises a *token* cap for a bounded period. It says
nothing about provider session windows and nothing about the clock.

## Objective

A run knows what time it is. In the daytime it stops while the operator
still has a usable Claude session; in a declared overnight window it may
spend the session to the end; and it stops at the end of that window so the
morning session starts empty. Burning the daytime session is possible but
never the default.

## Inputs (read these in your own context)

- `scripts/quota-window.sh:33-50` (`quota_reserve_settings`) and `:52-` 
  (`quota_gate_reading`), the reserve read and the gate
- `scripts/tick.sh:45-80`, the gate call site and its `budget_pause_until`
- `scripts/drain.sh` in full; it is short, and its header states the intent
  this card must not duplicate
- `templates/phat-controller-mandate.yaml.tpl:31-36`, where the setting is
  declared, and the comment above it about zero versus null
- `scripts/quota-window-smoke.sh`, the existing offline fixtures
- `docs/incidents/2026-08-16-budget-cap-did-not-stop-dispatch.md`, for what
  a guard that does not bind actually costs

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. `window_reserve` in the mandate gains an optional schedule. The existing
   `percent` / `action` keys keep their meaning and become the default when
   no schedule is declared, so an unconfigured host behaves exactly as it
   does today. The added shape:

   ```yaml
   window_reserve:
     percent: 20
     action: hold
     overnight:
       start: "22:00"
       end: "01:00"
       percent: 0
     timezone: local
   ```

   `overnight.percent: 0` means the reserve does not bind inside the window.
   Document `timezone` explicitly: the window is operator wall-clock, not
   UTC, because it describes when a person is asleep. State which clock is
   read and what happens across a DST change.

2. `quota_reserve_settings` resolves the reserve **for the current moment**
   rather than returning one static pair, and returns the window it resolved
   under so the caller can log which rule applied. A window whose `end` is
   less than its `start` crosses midnight and must be handled as one
   interval, not two comparisons.

3. **The stop at the end of the overnight window.** When a schedule is
   declared, the tick refuses to dispatch outside a permitted window and
   says so in the log. Implement it in the tick, not as an installed
   LaunchAgent that has to remove itself: a tick that reads the clock and
   declines is resumable, killable and leaves nothing behind, which an
   installed stop job did not. An in-flight stage is **not** killed by the
   stop; it is allowed to finish and land, and only new dispatch stops.

4. **Burning the daytime session is opt-in and self-expiring.** Add
   `--ignore-reserve` to `drain.sh start`, which suspends the daytime
   reserve for the life of that drain and no longer. Reuse the drain rather
   than adding a second switch: it is already the operator's declared,
   bounded "spend the window down on purpose" verb, it already self-expires,
   and it already refuses to outlive its night. A drain must not extend past
   the end of the overnight window when a schedule is declared; refuse such
   a `--hours` at `start` with a message naming the window.

5. `scripts/session-window-smoke.sh`, new, offline, with an injectable
   clock. Frozen block around the assertions per the contract-test gate.

6. `docs/tick-loop.md` and `docs/runbook.md` state the schedule, the stop and
   the opt-in, and name the risk this card accepts: a wrong clock or a
   wrong timezone silently changes when the loop runs, and the only signal
   is the log line deliverable 2 requires.

## Constraints

- The default with no schedule declared is today's behaviour exactly. A
  subscriber that never configures this must see no change.
- Do not kill an in-flight agent to enforce the stop.
- Do not add a daemon, a second scheduler, or an installed stop job.
- `drain.sh` must not learn about token caps it does not already own, and
  this card must not change the token cap logic.
- The mandate is host-level, so one setting covers every subscriber. Do not
  add a per-repo copy of the schedule.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. With no `window_reserve.overnight` declared, `quota_reserve_settings`
   returns what it returns today for the same mandate, byte for byte.
2. With the schedule above and an injected clock at 14:00, the resolved
   reserve is 20 with action `hold`; at 23:00 and at 00:30 it is 0; at 01:30
   it is 20 again. The midnight crossing is one interval.
3. With an injected clock at 01:30 and a schedule declared, a tick performs
   no new dispatch and logs the reason. With a stage already in flight at
   01:00, that stage still reaps and lands.
4. A Claude window read at 85% utilisation against a 20% daytime reserve
   holds the dispatch and pauses to the window reset; the same reading at
   23:00 dispatches. A reading of `unknown` fails open at both times, as it
   does today.
5. `drain.sh start --ignore-reserve` suspends the daytime hold for its
   duration and not after it; a `--hours` that would run past the overnight
   window's end is refused at `start`.
6. `scripts/session-window-smoke.sh` passes, and its new cases fail against
   the pre-change scripts. `scripts/quota-window-smoke.sh` and
   `scripts/budget-cap-smoke.sh` are no more red than on clean `dev`.
7. `docs/tick-loop.md` names the accepted risk in the words of deliverable 6.

## Contract test

- **Test file:** scripts/session-window-smoke.sh
- **Assertions digest:** `sha256:1df36051a73a1c85117cd97d133dcc1e0aef649f38425711aac86072aafe2462`

## Out of scope

- Reading the provider's quota over the network. The reader owns no
  credential and makes no request; that is deliberate and unchanged.
- Per-family schedules. One schedule covers the host.
- Changing token caps, the drain's cap semantics, or the daily budget window.

## Budget

- **Worker wall-clock:** 90 minutes
- **Verifier wall-clock:** 60 minutes

## Escalation

If honouring the stop cleanly requires killing an in-flight agent, stop and
report rather than adding a kill path. Allowing the last stage to finish is
the whole point of stopping at the tick.

## Verifier handoff

Drive the clock, do not wait for it. Every criterion above is reachable with
an injected time, and a verifier that tests only the hour it happens to run
in has verified almost nothing. Check the midnight crossing specifically:
the obvious implementation of `start <= now < end` is wrong for a window
that wraps, and it fails silently by never binding. Then check the
fail-open cases: an unknown reading must still dispatch, because a guard
that holds on a reading it could not take would stop the fleet on a stale
snapshot. That is the failure this card is most likely to ship.

## Family-specific notes

None

## PROPOSED-AMENDMENT (attempt 2, 2026-09-06): acceptance 4 and the stop

Recorded, not applied: no acceptance criterion above has been edited.

Attempt 1 was failed on criterion 3 because it shipped no stop -- the tick
read no clock, and the only refusal was the pre-existing reserve. Attempt 2
implements the stop as a clock-driven gate above the reserve, which is what
criterion 3 asks for and what the card's title is about.

That change makes criterion 4 unreachable as literally worded. Criterion 4
says an unknown reading "fails open at both times, as it does today", where
the two times are 14:00 and 23:00. It still does -- of the *reserve*, which
is untouched. But a daytime worker dispatch now stops on the clock before
the reserve is consulted, so read at the level of a whole dispatch decision,
14:00 no longer fails open. The two criteria cannot both hold at the
dispatch level: a stop that lets an unknown reading through in the daytime
is not a stop, and it is the precise hole that failed attempt 1.

The smoke therefore exercises criterion 4 against `quota_gate_family_
dispatch` (the reserve gate) rather than `quota_gate_role_dispatch` (the
whole decision), which proves what criterion 4 is about and stops it
re-proving the stop.

**Proposed wording, for the operator to accept or reject:** criterion 4
gains "at the reserve gate" after "fails open at both times", and criterion
3 gains "whatever the quota reading says" after "no new dispatch". If the
operator instead wants daytime dispatch to remain possible on a healthy
reading, that is a different card: the stop would need to be scoped to runs
that began overnight, which is state the tick does not currently keep.

## Verifier seat, attempt 2 (2026-09-06)

Attempt 1 was worked by Claude Sonnet 5 and verified by Claude Opus 5, which
failed it correctly. Attempt 2 was worked by Claude Opus 5 directly from the
orchestrator session, so the authored Opus verifying seat would have put the
same model on both sides of the gate, which this batch's seat rule forbids.
The seat moves to Codex, restoring the cross-family default now that the
Codex window has reopened. It is not moved because attempt 1's verifier was
wrong: it was right, and its criterion-3 finding is what attempt 2 fixes.
