# Stage card 37-idle-ticks-consume-the-day: the fleet spends its whole tick budget doing nothing, and the dashboard reports a queue that does not exist

## Metadata

- **Authored:** 2026-08-23
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Claude Opus 5 <claude-opus-5@local>
- **Verifier:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Pairing rationale:** cross-family, same reasoning as card 31. The two
  defects here are both cases of a control-plane number meaning something
  other than what its name says, and a same-family verifier is the one most
  likely to re-inherit the assumption that let them through.

## Objective

Every enabled subscriber is halted on `tick-cap` with a queue that has been
empty for days, and the operator's ticker shows sixteen stages "pending" that
the controller's own state file records as finished.

Make the tick budget bound *work*, and make the SCHEDULED panel read the queue
the controller actually dispatches from.

## Reported by

Found on 2026-08-23 during a review of why the overnight windows keep coming up
empty. As with card 31, no alarm surfaced this; the ticker was on screen the
whole time and was reporting a full queue.

### Defect A: an idle tick costs the same as a dispatched one

Every enabled subscriber, read at 2026-08-23T10:50Z:

| Repo | `clock_ticks_used` / cap | `tokens_spent` | `wall_clock_elapsed_seconds` | halted at |
|---|---|---|---|---|
| aegis-guardrails | 400/400 | 0 | 0 | 04:13:32Z |
| agentic-rag-kimble | 400/400 | 0 | 0 | 04:13:32Z |
| autometta | 400/400 | 0 | 0 | 04:13:32Z |
| fractals-from-the-90s | 400/400 | 0 | 0 | 04:13:33Z |
| emergence-lab-surface | 180/180 | 0 | 0 | 07:32:47Z |
| emergence-lab | 400/400 | 5,921,327 | 0 | 03:28:18Z |

Five of the six consumed an entire day's tick allowance and spent **zero
tokens and zero wall-clock seconds** doing it. `aegis-guardrails` holds exactly
one stage and that stage is `completed`; there has been nothing for it to
dispatch for days, and it burned 400 ticks establishing that.

`budget_increment_tick` is called on the unconditional fall-through at the end
of the per-repo tick (`scripts/tick.sh:1263`) as well as on the early-return
paths above it, so the counter advances whether or not an agent was dispatched.
`clock_tick_cap` is documented and used as a safety cap — card 31 treats it as
the cleanest of the three caps because "it is one integer against another" —
but what it actually caps is *elapsed polling*, not work. A repo with an empty
queue reaches its cap on a fixed schedule no matter what.

The consequence is the one that matters operationally: the window resets at
midnight, the fleet burns the allowance through the small hours, and every
subscriber is halted well before the 22:00 evening window opens. The overnight
window has nothing to do with whether the overnight window opens.

### Defect B: two fleet-wide tick jobs, which is the failure the fleet job was created to prevent

`com.autometta.tick.fleet.plist` carries this comment:

> ONE job for the whole fleet. `autometta tick` takes no repo argument: it
> iterates every enabled subscriber [...] so every repo was ticked three times
> per interval and burned its clock_tick_cap in 3-6 hours. That is what left
> the fleet halted through the 2026-08-15 window. **Do not add a second tick
> job per repo.**

`com.autometta.tick.emergence-lab-surface-v2.plist` was added on 2026-08-19 and
is a second such job. It is named for one repo but its `ProgramArguments` are
`autometta tick` with no repo argument, so it iterates the whole fleet too.
Both are loaded, both at `StartInterval` 300.

Measured, from today's controller log, ticks logged per hour for one repo:

```
24 2026-08-23T04
24 2026-08-23T05
24 2026-08-23T06
```

24 per hour is one every 150 seconds: two jobs at 300s, offset. The intended
rate is 12. Every subscriber is being double-ticked, and the tick cap therefore
arrives in half the intended time.

### Defect C: the SCHEDULED panel and the controller read different queues

`agent-ticker.sh` renders SCHEDULED from `list-cards.sh`, which classifies a
card as `done` only if it appears as a done row in
`examples/self-host/PLAN.md`, or in `state/recent-agents/` with
`outcome=completed`. It never reads `state/state.yaml` — the file the
controller dispatches from.

`emergence-lab` has no `examples/self-host/PLAN.md`; that path is autometta's
own. So every card in `docs/stages/` is reported `pending` forever. The ticker
shows `01-iteration-counter-side-panel` through `05-math-formula-rendering` as
pending; `state.yaml` records 31 stages `completed`, 3 `verifier_failed`, 2
`stalled`, and **not one `pending`**.

Across all seven subscribers the tally is the same: zero pending stages
anywhere. The queue has been empty since the windows started coming up dead.
The panel reporting otherwise is why that went unnoticed — this is the same
class of miss as the 2026-08-13 incident logged in
`token-maxing/WEEKEND-RUNS.md`, where ~9.4M tokens went on ticking against an
empty queue, except here the operator had a display that actively said the
queue was full.

## What the evidence already rules out

- **Not the budget accounting.** Card 32's attribution defects are real but
  irrelevant here: five repos spent literally zero tokens, so no accounting
  error can explain their halts. Do not re-verify the parser.
- **Not a dispatch fault.** There is nothing to dispatch. Confirm this by
  re-running the status tally rather than by reading dispatch code.
- **Not a stale keg.** The fleet job runs the working checkout via
  `AUTOMETTA_ROOT`, so `tick.sh:1263` as read above is the code that ran.

## Deliverables

1. **Separate the two meanings of a tick.** Decide whether `clock_tick_cap`
   bounds dispatches or polls, and make the code match the name. The
   recommended split: increment a work counter only on paths that dispatched
   or reaped an agent, and if idle polling still needs a bound, give it its
   own separately-named counter and cap. A cap whose only reachable effect is
   to halt an idle repo is worse than no cap, because it converts "nothing to
   do" into "cannot work when there is".
2. **Kill the duplicate LaunchAgent.** `launchctl bootout` and remove
   `com.autometta.tick.emergence-lab-surface-v2.plist`. Confirm the observed
   rate returns to 12/hour. Then add a check to `scripts/health-check.sh` that
   fails when more than one loaded launchd job runs `autometta tick`, so the
   comment in the fleet plist is enforced rather than merely written down.
3. **Point SCHEDULED at `state.yaml`.** `list-cards.sh` should treat the
   controller's state file as authoritative for any card it records, falling
   back to PLAN.md / `recent-agents` only for cards state.yaml has never seen.
   A card on disk that has never been queued is a real and useful category,
   but it must not be spelled the same way as a queued-and-waiting stage.
   Give it a distinct label (`unqueued`), so an empty queue is visible as an
   empty queue.
4. **Surface an empty queue as an alert.** The ALERTS panel in
   `agent-ticker.sh` already covers halts and failures. Add: zero pending
   stages while the repo is enabled. This is the gap
   `WEEKEND-RUNS.md` flagged on 2026-08-14 against
   `ai-schedules/bin/preflight_autometta.sh` and it belongs in both places —
   preflight catches it before a window, the ticker catches it during one.
5. **Recover the fleet.** Clear the current `tick-cap` halts
   (`autometta tick --reset-halt`) once 1 and 2 are in, and confirm a tick
   with an empty queue no longer advances toward a halt.

## Acceptance criteria

1. A repo with an empty queue, ticked for a simulated full day, does not reach
   `halted: true` with `halt_reason: tick-cap`.
2. A repo with queued stages still halts at its cap when the work itself
   exceeds it; the cap must not become decorative. Demonstrate both directions.
3. Exactly one loaded launchd job runs `autometta tick`;
   `scripts/health-check.sh` fails if a second is introduced.
4. For `emergence-lab`, the SCHEDULED panel reports zero pending stages and
   labels the unqueued `docs/stages/*.md` cards distinctly from queued ones.
5. The ALERTS panel shows an empty-queue alert for every currently-enabled
   subscriber, all seven of which qualify today.
6. All existing smoke tests still pass against the installed keg:
   `state-writable-smoke.sh`, `effort-flags-smoke.sh`, `usage-error-smoke.sh`,
   `budget-cap-smoke.sh`.

## Notes for the worker

- Card 31 is the direct ancestor: it is the same failure mode from the other
  side. There the cap did not stop work that should have stopped; here it
  stops work that should never have been counted. Read it first, and expect to
  touch `scripts/budget.sh` in the same region, which is also where card 33's
  stranded branch collides. Do not land card 33's `b2859b8` alongside this.
- Fleet hygiene, noted but explicitly **out of scope** for this card: three
  emergence-lab subscribers are enabled (`emergence-lab`,
  `emergence-lab-surface`, `emergence-lab-surface-v2`) and the ticker's stale
  tmux sessions date to 18 and 19 August. Card 38 covers both.
