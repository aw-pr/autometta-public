# Stage card 133: the dashboard states its times in one zone

## Metadata

- **Authored:** 2026-09-07
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Verifier:** Claude Fable 5.1 <claude-fable-5-1@local>
- **Base branch:** dev
- **Run branch:** autometta/133-the-dashboard-states-its-times-in-one-zone
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** dashboard/dashboard.js, scripts/dashboard-clock-smoke.sh, docs/observability.md, stage-cards/133-the-dashboard-states-its-times-in-one-zone.md
- **Pairing rationale:** premium pairing for display work, the same reasoning
  as card 132. The failure here is not a wrong value, it is a true value a
  reader misreads, and only reading the rendered line catches that. A cheap
  tier satisfies "both stamps go through a formatter" without ever checking
  that the two now agree to a human eye.
- **Type:** Display honesty. Touches no dispatch path, so it pairs.

## Surfacing concern

The dashboard header states two times side by side in different zones:

```
generated 2026-09-07T17:43:24Z · 1 of 5 repo(s) live (file://, serve for a
reliable poll) · unchanged at 18:43:32
```

`dashboard/dashboard.js:712-713` writes `data.generated_at` straight into
the element, which is the aggregator's ISO stamp in UTC. `:840-846` builds
the freshness half from `new Date().toLocaleTimeString()`, which is local.
Under BST the same instant reads as an hour apart, so a page regenerated
eight seconds ago looks an hour stale.

This is not a cosmetic complaint. The freshness line exists to answer one
question -- is this page still being written? -- and card 62's liveness work
exists because a dead page once sat calling itself live. A line that
*claims* an hour of staleness that is not there is the same defect with the
sign flipped: the reader stops believing the line, and then it cannot do its
job in either direction.

It is also demonstrably misleading rather than theoretically so. On
2026-09-07 the operator asked about it, and the orchestrator read it as an
hour of staleness too and went looking for a stalled regenerator before
checking `data.json`, which had been written seconds earlier.

## Objective

A reader comparing the two times on the header line is comparing like with
like, and can tell at a glance how stale the page is.

## Inputs (read these in your own context)

- `dashboard/dashboard.js:705-720` (the generated-at line) and `:830-855`
  (`poll`, `setLiveStatus`, the freshness clock)
- `scripts/dashboard-liveness-smoke.sh`, for the established way of lifting
  one function out of the IIFE and running it under stubs
- `scripts/dashboard-clock-smoke.sh`, the frozen assertions for this card

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. A `formatClock(stamp)` in `dashboard/dashboard.js` that renders an ISO
   stamp in the same zone and format as the freshness clock, so
   `formatClock("2026-09-07T17:43:24Z")` equals
   `new Date("2026-09-07T17:43:24Z").toLocaleTimeString()`.

2. The generated-at line goes through it rather than concatenating
   `data.generated_at` raw. A formatter nothing calls fixes nothing.

3. `formatClock` degrades readably. An unparseable or missing stamp must not
   put `Invalid Date`, `undefined` or `null` in front of the operator; show
   the raw stamp, or a dash, or "unknown" -- your choice, but not those.

4. `docs/observability.md` states that the header's times are local, and
   that the ISO stamp the aggregator writes is UTC, so anyone reading
   `data.json` directly knows the two differ.

## Constraints

- Do not change what the aggregator writes. `generated_at` stays a UTC ISO
  stamp in `data.json`; this card is about how the page renders it.
- Do not change the liveness logic, the poll, or the failure path. Card 62
  owns those and `scripts/dashboard-liveness-smoke.sh` pins them.
- Do not add a date library. The page vendors Chart.js and nothing else.
- Keep the full ISO stamp reachable -- a `title` attribute is the obvious
  place -- so an operator comparing against a log in UTC still can.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. `formatClock` exists and renders an ISO stamp in the same zone as the
   freshness clock.
2. It never returns a bare UTC ISO stamp.
3. The generated-at line calls it and does not concatenate
   `data.generated_at` raw.
4. An unparseable stamp and a missing stamp both degrade readably.
5. `scripts/dashboard-clock-smoke.sh` passes, and fails against the
   pre-change `dashboard/dashboard.js`.
6. `scripts/dashboard-liveness-smoke.sh` and
   `scripts/dashboard-fail-closed-smoke.sh` are no more red than on clean
   `dev`.
7. The full UTC stamp is still reachable from the rendered page.

## Contract test

- **Test file:** scripts/dashboard-clock-smoke.sh
- **Assertions digest:** `sha256:69c3571af1546415cdbc1091c2103929cdb610f1867da770309a9f2c4275a0aa`

The file and its frozen block are **already written**, by the orchestrator,
before any implementation exists. Do not author, extend or edit the block:
satisfy it by changing the implementation. It fails today at the first
assertion, because `formatClock` does not exist. Fixtures and scaffolding
may be added outside the markers. If you become convinced an assertion is
wrong, stop and surface it as a blocker; the verifier recomputes this digest
and fails the stage if the assertions moved.

## Out of scope

- The `file://` transport note and the `--serve` advice. They are correct
  and are doing their job.
- The "N of M repo(s) live" count.
- The TUI. Card 132 owns its clock and pulse, and this card must not touch
  `scripts/lib/tui/`.

## Budget

- **Worker wall-clock:** 30 minutes
- **Verifier wall-clock:** 30 minutes

## Escalation

If matching the freshness clock's format exactly turns out to need the
page's locale at module load, stop and report rather than hard-coding a
format. A dashboard that shows 24-hour time to an operator whose machine
says 12-hour has replaced one misreading with another.

## Verifier handoff

Read the rendered header, do not only run the assertions. Open the page, or
reconstruct the line, and satisfy yourself that the two times now look like
the same kind of thing to a person glancing at them -- that is the entire
deliverable, and it is the one thing a passing assertion does not prove.

Then check the degradation cases by hand. `formatClock(undefined)` and
`formatClock("not-a-stamp")` are the shapes a half-written `data.json`
actually produces during a regeneration, and the failure mode this card is
most likely to ship is a page that reads `Invalid Date` at exactly the
moment the operator is trying to find out whether it is being written.

Finally, confirm the UTC stamp is still reachable. Dropping it entirely
would pass every assertion above and would take away the one thing that
reconciles this page with the tick log.

## Family-specific notes

None
