# Stage card 132: the dashboard shows its own pulse

## Metadata

- **Authored:** 2026-09-07
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Verifier:** Claude Fable 5.1 <claude-fable-5-1@local>
- **Base branch:** dev
- **Run branch:** autometta/132-the-dashboard-shows-its-own-pulse
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/lib/tui/render.py, scripts/lib/tui/app.py, scripts/tui-heartbeat-smoke.sh, docs/observability.md, stage-cards/132-the-dashboard-shows-its-own-pulse.md
- **Pairing rationale:** premium pairing for display work. A cheap tier games
  a display smoke by satisfying the assertion rather than the appearance --
  a character that changes off-screen passes "the frames differ" and shows
  the operator nothing. Sol builds it and Fable reads the rendered frame as
  a person would.
- **Type:** Display. Touches no dispatch path, so it pairs.

## Surfacing concern

The operator cannot tell a live dashboard from a frozen one. Both look
identical, and the difference matters most exactly when something has gone
wrong -- a hung seam, a dead tick, a machine that went to sleep.

The machinery is already there and does nothing visible.
`TuiState.observe_time` (`scripts/lib/tui/render.py:294-297`) compares
integer seconds and returns True once per second, and the interactive loop
(`scripts/lib/tui/app.py`) already marks the frame dirty and redraws on it,
with a 100ms `stdscr.timeout`. So the TUI redraws every second today and
the screen does not change, because everything on it is derived from
`state.now`, which is set only when a payload arrives
(`render.py:242,250`) -- once per `--interval`, default five seconds.

Two consequences the operator lives with:

- **Nothing on screen says "still running".** During this batch's overnight
  run the machine slept twice and the fleet stalled silently; the only way
  to know was to read a log.
- **Elapsed times lurch.** Every clock derived from `state.now` sits still
  for five seconds and then jumps five, which reads as stutter rather than
  as time passing.

## Objective

A glance at the dashboard answers "is this thing alive?" without touching
it. Something visible changes every second, and what changes is a clock the
operator can read, not only an animation.

## Inputs (read these in your own context)

- `scripts/lib/tui/render.py:240-300` (`TuiState.update`, `.now`,
  `.observe_time`) and `:1321-1356` (`footer`)
- `scripts/lib/tui/render.py:1357-` (`render`), the entry point every
  assertion drives
- `scripts/lib/tui/app.py:296-340`, the interactive loop and its dirty flag
- `scripts/tui-heartbeat-smoke.sh`, the frozen assertions for this card

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. A **live clock** in the frame, updating once per second: wall-clock
   `HH:MM:SS`. Derive it from the monotonic drift since the last payload
   (`observe_time` already carries it) added to the payload's `_now`, so it
   advances between polls and re-anchors to the truth on every poll rather
   than free-running.

2. A **visible pulse** beside it that changes state each second, so the
   operator sees movement even on a frame where the digits happen to be
   unreadable at a glance. It keeps pulsing while a poll is in flight and
   while a poll has **failed** -- a dashboard that freezes exactly when its
   seam breaks tells the operator the opposite of the truth.

3. **Elapsed figures stop lurching.** Any clock derived from `state.now`
   advances a second at a time rather than five at a time, by using the
   same drifted value. Do not change what the figures mean.

4. `docs/observability.md` records the pulse: what it is, that it proves the
   *renderer* is alive and not the tick, and that a still pulse means the
   TUI process itself is wedged.

## Constraints

- **The pulse must not invent data.** Token counts, spend, stage rows and
  agent rows change only when a payload arrives. Card 103's rule -- the
  dashboard does not invent a number it was not given -- is not suspended
  by making the display live. Only the clock and the pulse move between
  polls.
- Do not raise the poll rate. This card makes the *display* tick at 1Hz;
  the seam keeps its `--interval`, and cards 73 and 74 own its behaviour.
- Do not add a thread, a timer, or a second event loop. The existing
  100ms `stdscr.timeout` and the dirty flag are sufficient.
- Do not widen the frame or push an existing column off it. Cards 44, 63,
  66 and 80 all exist because something stopped fitting its pane.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. Two frames rendered one second apart, with no new payload, differ.
2. A readable `HH:MM:SS` appears in the frame and advances by exactly one
   second between those two frames.
3. The token figure is byte-identical across those two frames: no reading
   changed without a payload.
4. The pulse continues after `poll_failed`.
5. `scripts/tui-heartbeat-smoke.sh` passes, and fails against the
   pre-change `render.py`.
6. `scripts/tui-smoke.sh`, `scripts/tui-history-smoke.sh` and
   `scripts/superseded-status-smoke.sh` are no more red than on clean `dev`,
   including their width assertions at 80, 119 and 160 columns.
7. `docs/observability.md` says what a still pulse means.

## Contract test

- **Test file:** scripts/tui-heartbeat-smoke.sh
- **Assertions digest:** `sha256:eec2885d45ba0b2254b838995ec8a542135f304b4d366d23f875a22c0836bc6f`

The file and its frozen block are **already written**, by the orchestrator,
before any implementation exists. Do not author, extend or edit the block:
satisfy it by changing the implementation. It currently fails at the first
assertion, which is correct -- two frames a second apart are byte-identical
today. Fixtures and scaffolding may be added outside the markers. If you
become convinced an assertion is wrong, stop and surface it as a blocker;
the verifier recomputes this digest and fails the stage if the assertions
moved.

## Out of scope

- The poll interval, the seam, and anything cards 73 or 74 own.
- Spend or token accounting. This card displays what it is given.
- Colour. A pulse that only reads in colour is not a pulse on a mono
  terminal.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes

## Escalation

If a once-per-second redraw of the whole frame proves too expensive on a
wide terminal, stop and report rather than adding a partial-redraw path.
Partial redraw is a different card and a much larger one.

## Verifier handoff

Read a rendered frame as a person would, not only as a string the
assertions pass over. The failure this card is most likely to ship is a
pulse that satisfies "the frames differ" while showing the operator nothing
-- a character that changes in a column nobody looks at, a clock rendered
off the visible width, or a glyph that only differs by colour attribute on
a mono terminal. Print the frame at 80, 119 and 160 columns and look at it.

Then check the constraint that matters more than the feature: drive two
frames a second apart with a payload carrying live token counts and satisfy
yourself that **nothing but the clock and the pulse moved**. A display that
starts interpolating a token count between polls is inventing data, which
is card 103's failure re-introduced by the back door.

## Family-specific notes

None
