# Stage card 49: the fleet pane reads as running, queued, failed, and when

## Metadata

- **Authored:** 2026-08-24
- **Orchestrator:** Claude Fable 5 <claude-fable-5@local>
- **Worker:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Verifier:** Claude Fable 5 <claude-fable-5@local>
- **Base branch:** dev
- **Run branch:** autometta/49-fleet-pane-reads-as-running-queued-failed-and-when
- **Worker effort:** medium
- **Verifier effort:** medium
- **Verifier panel:** false
- **Pairing rationale:** presentation over data that already exists, the
  cheaper codex tier's ground as cards 38, 41 and 44 reasoned. Claude
  verifies cross-family, against captures of the real pane rather than the
  code, because every fault this card fixes looked fine in the code and
  wrong on screen.

## Objective

The fleet pane answers "is the fleet healthy" but not the operator's actual
questions: what is running right now, what is waiting, what failed and how
long ago. Everything it knows arrives as one undifferentiated ALERTS table
that drags old decisions along indefinitely and breaks its own layout.

Reported by the operator with a screenshot of `autometta-autometta`, window
`fleet`, 2026-08-24 08:29Z. Faults visible in that one capture:

1. **Noise presented as alerts.** Five `repo / queue / empty` rows, one per
   healthy subscriber. An empty queue on an idle repo is a value for a queue
   column, not an alert; rendering it as one buries the two genuine failures
   in the same table.
2. **A false provider-limit alert built from card prose.** The row for stage
   45 with detail "weights through the same `codex` CLI. Zero marginal cost,
   no rate limits, no" is `scan-usage-limits.sh` phrase-matching the card
   text quoted inside the worker's log. The card *about* free routes tripped
   the limit scanner by containing the words "rate limits". The genuine
   limit on the same screen ("You've hit your session limit · resets
   6:50pm") shows what the scanner is for; the false one shows it cannot
   tell a CLI's own limit banner from prose that mentions limits.
3. **The false alert also broke the table**: its long detail wrapped onto a
   second line, splitting "no rate limits, no" across rows and misaligning
   everything below it.
4. **No timestamps.** The emergence-lab `verifier_failed` rows date from
   days ago and render identically to this morning's failure. Nothing on
   the pane distinguishes a live problem from an archived one.
5. **Nothing says what is running.** Every repo reads `running` in REPOS
   whether it is dispatching an agent or idling; the one agent actually
   at work (stage 45's verifier, at that moment) appears nowhere.

Restructure the pane so a human reads it top to bottom as a story: what is
happening now, what is waiting, what went wrong and when, what it costs.

Second screenshot, 2026-08-24 12:13Z, adds the presentation asks and one
landed fix to keep:

6. **Colour and emphasis.** The pane is monochrome, so a failure and a
   healthy row carry equal weight. Colour-code state: red for failures,
   halts and required actions, yellow for stalls, limits and drift,
   green for running and pass, dim for the quiet rows. Use `tput`
   capabilities with a plain-text fallback when the terminal offers no
   colour or `NO_COLOR` is set; the smoke asserts both renderings.
7. **Human-readable times.** Absolute ISO stamps ("2026-08-24T12:05:59Z
   (79s ago)") become relative first, absolute on demand: "79s ago",
   "3m", "10d". The age column from deliverable 4 uses the same
   vocabulary everywhere; one formatter, not per-panel copies.
8. **REQUIRED ACTIONS section**, above FAILURES: the rows that need a
   human, distinct from the rows that merely report. Initially: halts,
   attempt-cap exhaustion, `awaiting` integrations with conflicts, and
   PROPOSED-AMENDMENT markers once the queue-minder role (card 54)
   lands. Empty section renders as one quiet line, not omitted, so its
   absence is never ambiguous.
9. **Tables drawn as tables.** The operator pointed at Claude Code's own
   TUI rendering as the bar: box-drawing borders (`─ │ ┌ ┬ ┼`), header
   row separated by a rule, numeric columns right-aligned, emphasis in
   bold for the rows that matter. Render every tabular section that way,
   sized to the pane per deliverable 2, with an ASCII fallback (`- | +`)
   when the locale or terminal cannot take the box-drawing set, chosen
   the same way as the colour fallback. One table renderer shared by all
   sections, not per-section drawing code.
10. **Keep the tail-erase repaint.** The interleaved double-frame in the
   screenshot (REPOS printed over agentic-rag-kimble as
   "REPOSntic-rag-kimble") was home-and-repaint without per-line erase;
   fixed in `04b6dec` by suffixing every rendered line with
   erase-to-end-of-line. The restructured renderer must preserve that
   behaviour, and the no-wrap criterion catches the line-overrun half of
   the same screenshot.

## Inputs (read these in your own context)

- `scripts/attach.sh` — `render_fleet_once`, the whole pane.
- `scripts/aggregate-dashboard.sh` — the data.json the pane reads; where the
  alerts array and any missing timestamps come from.
- `scripts/scan-usage-limits.sh` and `scripts/alerts-table-smoke.sh` — the
  limit scanner and its existing fixture style, including the "genuine"
  marker the smoke test already asserts.
- `state/active-agents/` in a subscriber — the registry rows the RUNNING
  section renders.
- Card 43 (single alert-worthy definition, `superseded`), card 44 (pane
  fit, tear-free repaint, version header) — consume what has landed; where
  a dependency has not landed, leave the single named seam it will fill.
- `docs/observability.md`, `docs/dashboard.md`.

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `render_fleet_once` restructured into sections, in this order: TOTALS
   (unchanged), RUNNING (one row per registered live agent fleet-wide:
   repo, stage, role, family, elapsed, and the in-flight token figure if
   card 44's transcript reader has landed, else the registry's log-size
   fallback with its limits stated), QUEUE (per repo: depth and next stage;
   `empty` is an ordinary value here and never an alert), FAILURES
   (alert-worthy terminal stages with an age column, newest first), LIMITS
   (only genuine provider-limit detections, with the reset time where the
   banner carries one). The REPOS table keeps its spend columns and drops
   the constant `running` state column in favour of what RUNNING now shows.
2. No row ever wraps: every cell truncated to its column width with an
   ellipsis, the detail column last so truncation costs the least. Shares
   card 44's fit helper if that has landed; otherwise the logic lives in
   one function card 44 can adopt.
3. `scan-usage-limits.sh` anchored to the CLI families' own limit banners
   (the messages the CLIs actually print) rather than phrase-matching, so
   quoted card prose cannot raise a provider-limit alert. The card 45
   worker-log text becomes a negative fixture in
   `scripts/alerts-table-smoke.sh`; the existing genuine-banner fixture
   still matches.
4. Ages on every FAILURES and LIMITS row (`8h`, `3d`), derived from the
   state timestamps `aggregate-dashboard.sh` already has or is extended to
   carry. No new walker.
5. `scripts/fleet-pane-smoke.sh` — fixtures for the section order, the
   queue-empty reclassification, the no-wrap guarantee at 80 and at 120
   columns, and the age column.
6. `docs/dashboard.md` documents the section order and what belongs in
   each.

## Constraints

- What counts as alert-worthy does not change beyond the two
  reclassifications this card is for (queue-empty out of alerts, prose
  matches out of provider-limit). Card 43 owns the status-level
  definition; read its single definition if landed, else the single named
  constant card 44's brief describes.
- Read-only on every repo; the fleet pane renders state, it never writes
  it.
- Both families throughout, per the two-family invariant.
- The tmux layout, session names and window structure stay as they are;
  this card is the fleet window's renderer only. The per-repo tickers are
  card 44's.
- Keep the exact figures reachable, as cards 41 and 44 require.
- British English, no em dashes.

## Acceptance criteria

1. Against a fixture fleet with one live agent, one queued stage, one
   fresh failure, one old failure and one genuine provider limit, the pane
   shows five sections in the stated order, the live agent in RUNNING with
   its elapsed time, and the two failures with distinguishable ages.
2. The queue-empty case appears in QUEUE as a value and nowhere in
   FAILURES or LIMITS.
3. The card 45 worker-log prose raises no provider-limit alert, and the
   genuine session-limit banner still does, both against fixtures in
   `alerts-table-smoke.sh`.
4. At 80 and at 120 columns, no rendered line exceeds the pane width and
   no row wraps; a truncated cell ends with an ellipsis. Demonstrate by
   capturing the pane, not by reading the code.
5. A `superseded` stage in a fixture ledger appears in no section, and a
   genuinely failed one still appears, matching card 43's criterion 7 from
   the fleet side.
6. `scripts/fleet-pane-smoke.sh` passes, and every existing offline smoke
   script still passes. `sdk-cache-smoke.sh` requires live API credentials
   and is not run: say so.
7. `bash -n` passes on every shell file touched; no file outside the
   deliverables is modified except this card.
8. With colour available, a failure row, a stalled row and a running row
   render in visibly distinct colours; with `NO_COLOR=1` the same frame
   is plain text and still readable. Both captured.
9. REQUIRED ACTIONS renders its rows above FAILURES, and renders its
   one-line quiet form when empty. Times render relative everywhere,
   from one formatter.
10. Tabular sections render with box-drawing borders, ruled header and
    right-aligned numerics from one shared renderer, and degrade to the
    ASCII set under the same conditions as the colour fallback. Both
    captured.

## Contract test

- **Test file:** None
- **Assertions digest:** None

## Out of scope

- The per-repo tickers and the version header, which are card 44's.
- The alert-worthy status set and `superseded`, which are card 43's.
- The web dashboard under `dashboard/` beyond any field
  `aggregate-dashboard.sh` gains; a different UI format for the cockpit is
  a design conversation for a later card, not this one.
- Changing what the tick does, what queues, or any budget.

## Budget

- **Worker wall-clock:** 75 minutes
- **Verifier wall-clock:** 30 minutes

## Verifier handoff

Return the fixture-fleet capture for criterion 1, the 80- and 120-column
captures for criterion 4, both scanner outcomes for criterion 3, and the
superseded/failed pair for criterion 5. State which smoke scripts ran.

## Family-specific notes

None

## Re-brief (attempt 2, 2026-08-24)

Attempt 1 (WIP preserved at commit `2db88cb` on branch `wip/49-attempt-1`)
passed every criterion except 6, and criterion 6 failed on a defect in the
new smoke itself, not in the renderer. The verifier's evidence, confirmed:
`fleet-pane-smoke.sh`'s colour capture pins `TERM=xterm-256color` and
`PHAT_CONTROLLER_FLEET_STYLE=colour` but not a UTF-8 locale, while
`fleet_style_init` (scripts/attach.sh) also requires `locale charmap` to
report UTF-8 before selecting box drawing. In a headless dispatch shell
(charmap US-ASCII) the renderer correctly falls back to ASCII and the
smoke's box-drawing assertion fails against correct behaviour.

Do, in order:

1. Cherry-pick or restore the attempt-1 WIP (`2db88cb`) onto the fresh run
   branch. It is one commit holding the whole implementation; do not
   re-derive it.
2. Close the one gap: the smoke's colour capture must pin a UTF-8 locale
   (`LC_ALL=en_GB.UTF-8` alongside the existing TERM/style pins), and its
   ASCII capture must pin the opposite (`LC_ALL=C`) rather than inheriting
   whatever the dispatch shell has. State in a comment why both pins exist.
3. Re-run scripts/fleet-pane-smoke.sh from a shell with LANG unset to prove
   the capture no longer depends on the caller's locale, then the full
   offline smoke sweep as criterion 6 requires.

Nothing else in the attempt-1 implementation needs changing.
