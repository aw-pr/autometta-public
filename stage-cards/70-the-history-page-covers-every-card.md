# Stage card 70: the history page covers every card

## Metadata

- **Authored:** 2026-08-26
- **Orchestrator:** Claude Fable 5 <claude-fable-5@local>
- **Worker:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Verifier:** Claude Fable 5 <claude-fable-5@local>
- **Base branch:** dev
- **Run branch:** autometta/70-the-history-page-covers-every-card
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Gate:** stage-completed: 69-the-tui-lands-on-the-run-page
- **Pairing rationale:** same seats as card 69; this page extends that
  card's skeleton and the pair that built it carries the context. Serial
  batch, so family alternation for pipeline overlap does not apply.

## Objective

Page 2 of the TUI built in card 69: the historic view for this repo only,
every card ever run here, not just the current run. The operator's brief
(docs/proposals/instrumentation.md) and the signed-off mock:

```
┌─[0]─History: autometta ─── 47 cards · 101.4M lost 7d · $98.47 ──────────────────────────────────────────────────┐
│ card                          result   attempts  tokens    lost     cost    worker→verifier      when           │
│ 50-stage-cards-live-in…       PASS     3         3.8M      1.1M     $4.20   terra→fable          26 Aug 07:02   │
│ 68-pipeline-pair              PASS     1         2.3M      0        $1.87   sol→fable            26 Aug 06:58   │
│ 66-fleet-view-fits-pane       PASS     4         9.1M      6.2M     $11.40  sol→fable            25 Aug 21:14   │
│ 36-ship-fixes-and-recover…    FAIL     3         76.5M     76.5M    $61.02  codex→claude         24 Aug 03:11   │
│ ── spend by day ▂▃▁▅█▃▂   by model: sol 41% fable 28% terra 19% codex 12% ──────────────────────────────────────│
└──────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

One correction to the mock now the column rules apply: the card column in
the mock shows ellipsis, and the settled rule says identifying columns
never truncate. Stage ids render whole; the drop-then-wrap rule from cards
63 and 66 decides what gives way instead.

## Inputs (read these in your own context)

- `docs/proposals/instrumentation.md`, the operator's brief.
- Card 69's deliverables under `scripts/lib/tui/` and `scripts/tui.sh`.
- `scripts/failures-history.sh`, card 63's history command, the nearest
  existing reader of this data.
- `scripts/aggregate-dashboard.sh`, and `docs/cost-log.md` for the
  cost-log schema (per-dispatch rows: role, tokens, cached split,
  `cost_usd_est`, result).
- `scripts/cost-log.sh` for how rows are appended and what fields exist.

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. **The history page renders on tab `[2]`** of the card-69 TUI: one row
   per card for this repo across all runs, with result, attempts, total
   tokens, lost tokens, estimated cost, worker→verifier aliases and the
   most recent dispatch time, newest first.
2. **A summary header**: card count, 7-day lost tokens and estimated cost.
3. **A footer strip**: spend by day as a sparkline over the trailing
   fortnight, and share by model over the same window.
4. **One history seam.** The page's figures come from a single command
   invocation, not from the renderer walking files. Extend
   `failures-history.sh` with a JSON mode, or extend the aggregator
   additively; either way the renderer consumes one payload and computes
   nothing but presentation. Do not fork a second cost-log parser: whatever
   already parses it grows the capability, and both callers stay green.
5. **Selection and detail**: `j`/`k` moves through history rows; `enter`
   pins that card into the right-hand detail pane (card 69's pane, reused),
   showing its per-attempt dispatch rows: role, result, tokens, cost, when.
6. **Known data honesty**: some codex dispatches record `output_tokens` 0
   (the ticker already footnotes this). Rows whose cost rests on a zero
   read render the figure marked (for example a trailing `?`), and the
   summary header carries the same one-line note. Do not silently sum
   marked and unmarked figures without the mark surviving into the total.
7. **Smoke coverage added to `scripts/tui-smoke.sh`** (or a sibling
   `tui-history-smoke.sh` if separation is cleaner): fixture cost-log and
   state, at 80, 119 and 160 columns, asserting whole identifiers, the
   drop-then-wrap behaviour, the marked-figure rule, and that the summary
   figures equal what the fixture rows sum to, computed by the seam and
   not supplied ready-made by the fixture's expected output.

## Constraints

- Python stdlib and bash only.
- This repo only; the fleet stays out of this page.
- Do not change what existing consumers of the cost log or the aggregate
  payload receive.
- Page 1's behaviour is card 69's and is not re-opened here; the shared
  skeleton may be extended, not reshaped.
- The smoke supplies fixture data only and never asserts values it wrote
  into its own expected output.

## Acceptance criteria

1. Tab `[2]` renders the history table for a fixture repo with at least
   twelve cards spanning three days, newest first. Show 119 and 80 column
   captures.
2. Stage ids and aliases render whole at every width, drop-then-wrap
   applied where space ran out; no ellipsis in an identifying column.
3. The summary header's count, 7-day lost and cost equal the fixture rows'
   sums, and the smoke computes the expectation from the fixture input
   independently of the page's own seam output.
4. The by-day sparkline and by-model shares match the fixture distribution;
   the smoke asserts at least the ordering and the largest share.
5. `enter` on a history row populates the detail pane with per-attempt
   dispatch rows; show the capture for a card with three attempts
   including one FAIL.
6. A fixture dispatch with `output_tokens` 0 renders marked, and every
   total containing it carries the mark. Show it.
7. The renderer opens no state file and parses no cost log of its own;
   figures arrive through the one declared seam. Verified against imports
   and file access, not the claim.
8. The smoke passes with locale and TERM pinned, fails on the pre-fix
   tree, and its helpers fail loudly on anything absent.
9. Pages 1 and 3 are undisturbed: switching 1→2→1 preserves page 1's
   selection.

## Contract test

Render the history page against a fixture of twelve cards over three days,
one card with three attempts ending FAIL, one dispatch with a zero
output_tokens read, at 80, 119 and 160 columns. Whole identifiers at every
width, sums matching the fixture arithmetic, the zero-read figure marked
through to its totals, and per-attempt detail reachable by keyboard.

## Out of scope

- The messages page (card 71).
- Fleet-wide history.
- Live burn instrumentation (card 69 owns it).
- Any backfill or repair of historic cost-log rows.

## Budget

- **Worker wall-clock:** 90 minutes
- **Verifier wall-clock:** 30 minutes

## Verifier handoff

Return the width captures, the whole-identifier evidence, the sum
assertions with the fixture arithmetic, the marked zero-read figure, the
per-attempt detail capture, the single-seam check, and the smoke before
and after.

## Family-specific notes

None

## Re-brief (attempt 2, 2026-08-26)

Attempt 1 passed eight of nine and is preserved on
`wip/70-the-history-page-covers-every-card-attempt-1` (`0d3624a`).
**Restore that branch's tree and correct the one finding in place.** The shape of the
solution is settled and is not in question; a re-brief that corrects a
detail has cost a seventh of one that reshapes.

The finding, criterion 2: the history table honours the whole-identifier
rule, but the DETAIL pane heading truncates the pinned card's stage id
(`12-history-card-identifier-is-d` at 119 columns,
`...-deliberately-` at 160), because `history_detail_lines`
(`scripts/lib/tui/render.py:355-359`) emits the id as a plain content line
and `draw_box` hard-clips every line to the pane width. Page 1's detail
pane already word-wraps overlong lines before `draw_box`
(`render.py:581-596`); the history pane missed that existing wrap. Use the
existing helper rather than a second wrapping implementation.

The smoke gap that let it through: `tui-history-smoke.sh` asserts the
whole-identifier rule on the table but not on the detail pane. Extend it to
assert the pinned card's full id is present, wrapped not clipped, at 119
and 160 columns, on the 63-character fixture id. The assertion must fail
loudly if the id is absent or any line of it is cut.
