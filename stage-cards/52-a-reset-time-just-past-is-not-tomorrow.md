# Stage card 52: a reset time just past is not tomorrow

## Metadata

- **Authored:** 2026-08-24
- **Orchestrator:** Claude Fable 5 <claude-fable-5@local>
- **Worker:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Base branch:** dev
- **Run branch:** autometta/52-a-reset-time-just-past-is-not-tomorrow
- **Worker effort:** medium
- **Verifier effort:** medium
- **Verifier panel:** false
- **Pairing rationale:** a small time-arithmetic fix with a fixture-friendly
  shape; Codex works it, Claude verifies cross-family against fixtures
  around the boundary, where off-by-one-day is exactly the kind of bug that
  reads correctly.

## Objective

Observed 2026-08-24: a Claude worker for stage 46 was refused with
"You've hit your session limit · resets 12:10pm (Europe/London)" at 12:06
local. The tick parsed the banner at 12:10:02, seconds after the named
time had passed, resolved "next 12:10pm" to **tomorrow**, and paused the
repo until 2026-08-25 12:10 BST: a 25-hour pause for a limit that had
already lifted. The orchestrator cleared it by hand; an unattended
overnight window would have slept through entirely.

The parse lives in `scripts/usage-limit.sh` (consumed at
`scripts/tick.sh:514`). A reset time that has just passed means "the
window has already reset, dispatch now", not "wait until this time
tomorrow".

## Inputs (read these in your own context)

- `scripts/usage-limit.sh` — the banner parse and epoch resolution.
- `scripts/tick.sh` around line 514 — `budget_pause_until` and the
  provider-refusal path (card 35's machinery).
- `scripts/budget.sh` — `budget_pause_until`, `budget_pause_active`.
- `scripts/usage-error-smoke.sh` — the fixture style for this surface.
- The 2026-08-24 tick log lines in `~/.phat-controller/log/tick.err.log`
  (read-only evidence of the misparse).

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/usage-limit.sh` — a parsed reset time within a grace window
   in the past (suggest 15 minutes, one named constant) resolves to "no
   pause needed"; further past than the grace window keeps today's date
   only if still future, else rolls forward as now. State the rule in a
   comment where the arithmetic lives.
2. A pause is never longer than the provider's real window: cap any
   computed pause at 6 hours (one named constant, above the 5-hour
   session window), so a parse gone wrong costs one window, not a day.
3. `scripts/usage-error-smoke.sh` (or a sibling fixture script) covers:
   reset time 2 minutes past (no pause), 2 minutes ahead (short pause),
   crossing midnight, and a nonsense time (falls back to the capped
   default, not to tomorrow).
4. `docs/lessons.md` — the incident recorded with the log lines, as the
   gotcha it is.

## Constraints

- Card 35's semantics unchanged: a provider refusal still burns no
  attempt and leaves the worktree standing.
- No timezone database heroics: the banner's zone name is already
  handled today; this card fixes only the day-rollover and the cap.
- Offline fixtures only; no live limit is provoked to test this.
- British English, no em dashes.

## Acceptance criteria

1. Against a fixture banner whose reset time is 2 minutes in the past,
   the tick path computes no pause and the stage redispatches on the
   next tick.
2. Against one 2 minutes ahead, the pause ends within the grace of that
   time, today.
3. No fixture, however malformed, produces a pause longer than the cap.
4. The 2026-08-24 banner and timestamps from the incident, replayed as a
   fixture, produce "no pause" instead of 25 hours.
5. Existing usage-error and budget smokes still pass; `bash -n` on every
   touched shell file.

## Contract test

- **Test file:** None
- **Assertions digest:** None

## Out of scope

- Groq/OpenRouter 429 handling; card 46's caller owns its own caps.
- Any change to what counts as a refusal.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes

## Verifier handoff

Return the four fixture outcomes, the incident replay result, and the
named constants' values as shipped.

## Family-specific notes

None
