# Stage card 65: the loop stamps its own heartbeat

## Metadata

- **Authored:** 2026-08-25
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Base branch:** dev
- **Run branch:** autometta/65-the-loop-stamps-its-own-heartbeat
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Gate:** none
- **Pairing rationale:** a two-field write in bash whose whole value is that
  it is observed from outside, verified by the other family reading a real
  tick's output rather than a fixture's.

## Objective

The repo ticker's FRESHNESS panel reads `last tick 2115h13m ago -- STALE
(threshold 20m00s)`. The tick had run four minutes earlier.

![the repo ticker reporting a tick 88 days old, minutes after a real tick](../../docs/incidents/images/2026-08-25-repo-ticker-freshness-stuck.png)

`state/state.yaml` carries `last_tick_at: "2026-05-29T09:21:18Z"` and
`tick_count: 0`. Neither has moved since 29 May. **Nothing writes either
field.** Grep the tree: every hit is a test fixture setting the value by hand,
plus one comment in `scripts/tick.sh:1495` that asserts the opposite of the
truth:

```
# durable "last actually active" signal independent of how often
# state.yaml itself gets touched (tick_count/last_tick_at update every
# tick regardless of whether a stage is running).
```

That comment describes behaviour that does not exist, and it has been wrong
long enough that a reader would trust it.

The renderer is correct. `scripts/lib/repo-ticker-render.py:368` reads
`last_tick_at` from the aggregated payload,
`scripts/aggregate-dashboard.sh:188` copies it from `state.yaml`, and both do
exactly what they should with the value they are given. The value has never
been written.

**The consequence is worse than a wrong number.** FRESHNESS is the one panel
whose job is to tell an operator the loop has stopped. It is stuck in the
"stopped" position permanently, so it says STALE while the loop runs happily
and it will say STALE when the loop genuinely dies. An alarm that is always on
is an alarm nobody reads, and this one has been on since May.

This card was written on 2026-08-25 after stage 63 landed a new repo ticker
that renders this field faithfully. 63 passed its freshness criterion because
its smoke sets `last_tick_at` in four of its own fixtures. The renderer was
proved; its input was never checked.

## Inputs (read these in your own context)

- `scripts/tick.sh`, the top of the tick and the comment at line 1495.
- `scripts/aggregate-dashboard.sh:175-188`, where the field is read.
- `scripts/lib/repo-ticker-render.py:344-370`, the freshness block.
- `scripts/subscribe-repo.sh:73`, which seeds `last_tick_at` at the epoch for
  a new subscriber, so a never-ticked repo is distinguishable from a stalled
  one.
- `state/budget.json`'s `dash_active_at`, which **is** stamped every tick and
  is the working example to follow.
- `docs/incidents/2026-08-24-run-lessons-log.md` entry 11, on criteria proved
  against fixtures rather than production.

## Deliverables

1. **The tick stamps `last_tick_at` on every tick**, work or idle, and
   `tick_count` increments with it. Both go through the existing state writer
   with its read/write guards; do not add a second path that writes
   `state.yaml`.
2. **The stamp survives the paths that do not dispatch.** A tick that halts on
   budget, steps over a gated stage, finds nothing pending, or exits early on
   the integrity guard has still ticked. The field means "the loop ran", not
   "the loop dispatched".
3. **A never-ticked repo is distinguishable from a stalled one.** Decide what
   the ticker shows for a subscriber whose `last_tick_at` is still the epoch
   seed, implement it, and say what you chose in your handoff envelope.
4. **Fix the comment at `scripts/tick.sh:1495`** so it describes what the code
   does. If your change makes it true, say so; do not leave a comment that a
   reader has to verify against the code.
5. **A smoke that asserts against a real tick, not a fixture.** Run the tick,
   then assert `last_tick_at` moved and `tick_count` incremented. A test that
   writes the field it is testing proves nothing, and that is exactly how this
   bug survived card 63.
6. **Backfill is out of scope, and the record says so.** Do not invent history
   for the 88 days the field stood still.

## Constraints

- Do not widen this into a general heartbeat redesign. `scripts/heartbeat.sh`
  and `state/heartbeat.json` are a different mechanism watching agents, not
  the loop, and they stay untouched.
- Do not change the freshness threshold or the renderer's formatting. The
  renderer is not at fault.
- One extra state write per tick is the whole cost. Do not add a file, a
  lock, or a schema version for it.

## Acceptance criteria

1. `last_tick_at` advances and `tick_count` increments after a real tick.
   Show both values before and after.
2. The same holds for a tick that dispatches nothing: halted on budget, gated,
   and empty-queue, each shown separately.
3. The repo ticker's FRESHNESS panel reads a true age minutes after a tick,
   and reads loud only when the loop has genuinely stopped. Show both.
4. A freshly subscribed repo that has never ticked renders as whatever
   deliverable 3 chose, not as 56 years stale.
5. The comment at `scripts/tick.sh:1495` matches the code.
6. The new smoke fails on the pre-fix tree and passes after, and it drives a
   real tick rather than writing `last_tick_at` itself.
7. `state.yaml` is intact after the change: stage count unchanged, `.bak`
   consistent, no degenerate write.

## Contract test

Run a tick on this repo while it is halted on `token-cap`, which is the state
it is in as this card is written. The tick dispatches nothing. `last_tick_at`
must still advance, because the loop ran.

## Out of scope

- `state/heartbeat.json` and the agent watchdog.
- The fleet ticker, which is card 66.
- Any change to how spend is metered.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes

## Verifier handoff

Return the before and after values for both fields, the three no-dispatch
paths each shown stamping, the FRESHNESS panel reading true and reading loud,
the never-ticked case, the corrected comment, and the smoke failing before and
passing after with evidence that it drives a real tick.

## Family-specific notes

None
