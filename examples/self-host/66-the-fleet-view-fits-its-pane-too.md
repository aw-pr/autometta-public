# Stage card 66: the fleet view fits its pane too

## Metadata

- **Authored:** 2026-08-25
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Verifier:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Base branch:** dev
- **Run branch:** autometta/66-the-fleet-view-fits-its-pane-too
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Gate:** stage-completed: 65-the-loop-stamps-its-own-heartbeat
- **Pairing rationale:** the family that built the repo ticker in card 63
  applies the same discipline to its sibling, verified by the other family
  which has no stake in the earlier design.

## Objective

Card 63 gave the per-repo ticker a bounded page: counts, escalations, spend
and loss, freshness, and a failures history moved out to a command. Its
criterion 10 was explicit, "the failures history is reachable as a command and
the live view no longer renders it".

The fleet view never got that treatment, and it is what an operator actually
lands on: `autometta attach` opens window 0, and window 0 is the fleet.

What that window shows today:

![the fleet ticker's totals and repos tables](../../docs/incidents/images/2026-08-25-fleet-ticker-totals-and-repos.png)

The top half is good and should survive: TOTALS with today's tokens and
estimated cost against the window, and a REPOS table with one row per
subscriber, state, queue depth, window and today's spend, and the rule that
binds. That is progress at a glance.

Then it keeps going:

![the fleet ticker's unbounded failures table, scrolling past the pane](../../docs/incidents/images/2026-08-25-fleet-ticker-unbounded-failures.png)

FAILURES lists every stage and non-pass dispatch across every subscriber, back
to `90d` and `never`, thirty-odd rows and growing with the age of the fleet.
It runs off the bottom of a 45-line pane on a large monitor, so the operator
scrolls to find out whether anything is wrong, which is the opposite of a
ticker. The rows are also badly truncated at their most useful columns:
`50-stage-cards-live-i…`, `ver…`, `verif…`.

**The failures are worth keeping. They are not worth rendering live.** Card 63
already decided that for one repo and shipped `scripts/failures-history.sh`.
This card applies the same decision one level up.

## Inputs (read these in your own context)

- `scripts/attach.sh`, the `--fleet-ticker` mode and `fleet_cmd` at line 678.
- `scripts/aggregate-dashboard.sh`, the sole subscriber walker.
- `scripts/lib/repo-ticker-render.py`, card 63's renderer, for its column
  allocation and its aggregate-versus-presentation boundary rule. Reuse rather
  than reimplement wherever the two views need the same thing.
- `scripts/failures-history.sh`, the command card 63 moved history into.
- `examples/self-host/63-one-ticker-per-repo-that-fits-its-pane.md`, whose
  acceptance criteria are the standard this card is holding the fleet view to.

## Deliverables

1. **The fleet view fits its pane at 119 and at 80 columns with no
   scrollback**, on a fleet of at least six subscribers. Fitting is the
   criterion, not a target.
2. **FAILURES leaves the live view.** History is reachable as a command,
   covering the fleet rather than one repo. Extend `failures-history.sh` if it
   fits; do not fork a second implementation.
3. **What stays is what an operator acts on**: which repos are enabled, which
   are halted or stalled and why, queue depth, today's and the window's spend
   against the cap that binds, and outstanding escalations. A row nobody acts
   on does not earn its line.
4. **Columns resize with the terminal and stop truncating the identifying
   column.** A stage id or repo name cut to `50-stage-cards-live-i…` fails the
   only job that column has. Card 63 settled the rule: the id column grows
   with the remainder, a column with a trailing detail field keeps its cap.
5. **One process draws the fleet page**, as card 63 established for the repo
   page, reading aggregated figures rather than recomputing them.
6. **Say which window an operator should land on.** If the repo view is the
   better default, make it window 0 and say why in your handoff envelope. Do
   not change the window order silently.
7. **A smoke in the shape of `scripts/repo-ticker-smoke.sh`**, with locale and
   TERM pinned as card 49 established, asserting the fit at both widths on a
   fixture fleet.

## Constraints

- Do not delete failure history. It moves; it does not go.
- Do not change what `aggregate-dashboard.sh` collects for other consumers.
  The HTML dashboard reads the same payload.
- Do not touch the repo ticker's behaviour. It passed eleven criteria
  yesterday and this card is not a second opinion on it.
- No new dependency. The renderer is Python and bash, as it is today.

## Acceptance criteria

1. The fleet view fits at 119 and at 80 columns against a fixture fleet of six
   or more subscribers, with no scrollback. Show both captures.
2. FAILURES is absent from the live view and reachable as a command that
   covers the fleet. Show the command's output.
3. Every repo that is halted, stalled or over cap is visible on the live page
   with its reason. Show a fleet containing all three.
4. No identifying column is truncated at 119 columns: repo names and stage ids
   render whole. Show the capture.
5. Allocation differs at 80, 119 and 160, per card 63's settled rule.
6. The renderer recomputes no aggregate, applying card 63's stated boundary.
7. The smoke passes with locale and TERM pinned, and fails on the pre-fix
   tree.
8. The chosen default window is implemented and justified in the envelope.

## Contract test

Render the current fleet, six subscribers with one halted on `token-cap`, one
paused, and two holding a stale vendor contract, into an 80-column pane and a
119-column pane. Neither may scroll, and the halted repo and its reason must
be visible without scrolling in both.

## Out of scope

- The HTML dashboard under `~/.phat-controller/dashboard/`.
- `last_tick_at`, which card 65 fixes and which this card may rely on.
- Any change to what counts as a failure.

## Budget

- **Worker wall-clock:** 90 minutes
- **Verifier wall-clock:** 45 minutes

## Verifier handoff

Return both fits, the history command's output, the three problem states
visible live, the untruncated identifying columns, the three allocations, the
recomputation check, the smoke before and after, and the window-order decision
with its reason.

## Family-specific notes

None
