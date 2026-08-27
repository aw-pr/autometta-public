# Stage card 69: the TUI lands on the run page

## Metadata

- **Authored:** 2026-08-26
- **Orchestrator:** Claude Fable 5 <claude-fable-5@local>
- **Worker:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Verifier:** Claude Fable 5 <claude-fable-5@local>
- **Base branch:** dev
- **Run branch:** autometta/69-the-tui-lands-on-the-run-page
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Pairing rationale:** presentation work goes to the premium tier, per the
  operator's card-66 attempt-4 ruling: cheaper tiers softened the smoke three
  attempts running. Sol builds, Fable verifies with no stake in the design.
  The batch runs serial (all three cards share the TUI tree), so the
  family-alternation rule for pipeline overlap does not apply.

## Objective

The tickers answer "do I need to intervene?" from a distance. The operator
now wants a working surface: a full-screen, lazygit-shaped TUI for one repo,
panels on the left, one detail pane on the right, keyboard-driven, resizing
with its Ghostty pane. This card builds the skeleton and the first page, the
run page. Cards 70 and 71 add the history and messages pages onto this
skeleton; ship the tab bar with all three names, pages 2 and 3 rendering a
one-line "arrives with card 70/71" placeholder.

The operator signed off this mock (docs/proposals/instrumentation.md holds
the brief); layout decisions in it are settled, not suggestions:

```
┌─[1]─Status─────────────────────────────┐┌─[0]─Card detail: 68-a-pipeline-pair────────────────────────────────────┐
│ ● autometta → dev        RUNNING       ││ 68-a-pipeline-pair-runs-two-stages-at-once          IN FLIGHT  worker  │
│ last tick 0m42s ago      tick #214     ││                                                                        │
│ run start 06:12:09Z      elapsed 1h32m ││   worker    gpt-5.6-sol          started 07:41:03Z   elapsed 3m12s     │
│ tokens 12.4M  $9.12      cap 150M (8%) ││   verifier  claude-fable-5       queued                                │
└────────────────────────────────────────┘│   attempt   2 of 3               budget 1800s (11% used)               │
┌─[2]─This run───────────────── 5 of 7 ──┐│   card      stage-cards/68-a-pipeline-pair.md                         │
│ ✔ 65-loop-stamps-hb   sol→fable  412k  ││                                                                        │
│ ✔ 66-fleet-view-fits  sol→fable  9.1M  ││   tokens    in 2.31M   cached 1.9M (82%)   out 41k     $1.87          │
│ ✔ 67-outlier-says-so  terra→fable 1.2M ││   ▁▂▂▃▅▅▆█  burn last 8 polls (12k/min)                                │
│ ▶ 68-pipeline  WORKER sol→fable  2.3M  ││                                                                        │
│ ▶ 50-cards     VERIFY terra→fable 3.8M ││ ─ acceptance ──────────────────────────────────────────────────────────│
│ ○ 69-tui       queued sol→fable    -   ││   scripts/pipeline-pair-smoke.sh                                       │
│ ✖ 36-ship      ESCALTD codex→claude 76M││                                                                        │
└────────────────────────────────────────┘│ ─ recent log ──────────────────────────────────────────────────────────│
┌─[3]─Agents───────────────── 2 live ────┐│   [07:43:58] apply patch scripts/tick.sh                               │
│ ● 68 worker   sol     3m12s / 30m      ││   [07:44:10] running pipeline-pair-smoke.sh ... ok                     │
│ ● 50 verifier fable   1m03s / 20m      ││   [07:44:31] 2 files changed, 41 insertions                            │
└────────────────────────────────────────┘│                                                                        │
┌─[4]─Escalations & inbox ──── 1 · 0 ────┐│                                                                        │
│ ✖ 36-ship-fixes  failed ×3  needs you  ││                                                                        │
└────────────────────────────────────────┘└────────────────────────────────────────────────────────────────────────┘
 [1]run [2]history [3]messages   j/k select · enter detail · m message controller · q quit          autometta 776023d
```

Settled decisions the mock carries:

- **Panel [2] shows worker→verifier per card, wide-row form** (operator
  locked this variant on 2026-08-26). Short aliases (`sol`, `fable`,
  `terra`, `codex`) resolved from the card's declared pairing; full identity
  strings live in the detail pane only. On an in-flight pair the active
  role's alias renders emphasised (bold or colour), flipping from worker to
  verifier when the verifier picks the stage up. Where the pane is too
  narrow for the wide row, the pairing wraps to an indented second line
  under the drop-then-wrap rule; the pairing column never truncates.
- **Status glyphs:** `✔` completed, `▶` in flight (with role word), `○`
  queued, `✖` escalated or failed.
- **Burn sparkline:** derived inside the TUI process from token deltas
  between successive polls of the data seam, rendered with a rate figure.
  No transcript parsing, no new collection.

## Inputs (read these in your own context)

- `docs/proposals/instrumentation.md`, the operator's brief.
- `scripts/repo-ticker.sh` and `scripts/lib/repo-ticker-render.py`, for the
  data seam, the refresh loop shape, and the settled column and row rules
  (cards 63 and 66: columns drop whole, identifiers never truncate, content
  shrinks and the frame never clips).
- `scripts/aggregate-dashboard.sh`, the sole data seam (`--repo` mode).
- `scripts/lib/fleet-ticker-render.py`, for the drop-then-wrap
  implementation to reuse.
- `scripts/repo-ticker-smoke.sh` and `scripts/ticker-fit-smoke.sh`, the
  smoke shape and the pinned locale and TERM discipline (card 49).
- `state/active-agents/` schema via `docs/observability.md`, for elapsed and
  budget figures already present in the aggregate payload.

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. **`scripts/tui.sh <repo_root>`**, a bash launcher in the shape of
   `repo-ticker.sh`: resolves the repo, then hands the terminal to the
   renderer. Wire an `autometta tui [repo]` subcommand the same way
   existing subcommands are wired.
2. **`scripts/lib/tui/`**, a Python stdlib curses application. No package
   beyond the standard library. Layout: panels `[1]` Status, `[2]` This
   run, `[3]` Agents, `[4]` Escalations & inbox on the left; `[0]` detail
   pane on the right; tab bar and key hints on the bottom line, per the
   mock.
3. **One data seam.** All figures come from `aggregate-dashboard.sh --repo`,
   re-polled on the refresh interval (default 5s, `AUTOMETTA_TUI_INTERVAL`
   to override). The renderer reads no state.yaml, no cost-log, no
   transcripts. If a figure the mock needs is missing from the payload,
   extend the aggregator additively; never change what it already emits
   (the HTML dashboard and both tickers read the same payload).
4. **Keys:** `j`/`k` (and arrows) move selection within the focused panel,
   `1`-`4` focus a panel, `tab` cycles focus, `enter` pins the selected
   card into the detail pane, `q` quits cleanly (terminal restored). `m`
   and the page tabs `[2]`/`[3]` may render as hints but need no behaviour
   beyond the placeholder pages this card ships.
5. **Resize is an event, not a fault.** On SIGWINCH the layout reflows:
   below 110 columns the left column narrows and panel `[2]` wraps its
   pairing line; below 80 the panels stack vertically, detail pane below.
   The settled row and column rules apply throughout: identifying columns
   render whole at every width, sections give up rows by priority with an
   explicit "and N more" line, the frame never clips silently.
6. **A smoke, `scripts/tui-smoke.sh`,** locale and TERM pinned, driving the
   renderer against a fixture payload (no live repo, no spend) at 80, 119
   and 160 columns, asserting: the five panels and tab bar render; panel
   `[2]` shows the wide worker→verifier row at 119 and 160 and the wrapped
   form at 80; no identifying column truncates; the burn rate figure is
   the delta the two fixture polls imply, not a value the fixture supplies
   ready-made; and the natural page height fits the pane at a tall render
   so a clip cannot hide an overflow. The fixture carries at least one
   58-character stage id and one full-length identity string.

## Constraints

- Python stdlib and bash only. No pip, no brew, no vendored package.
- Do not touch the behaviour of `repo-ticker.sh`, the fleet view, or the
  HTML dashboard. This card adds a surface; it does not re-litigate three.
- Reuse the drop-then-wrap and fit machinery from the ticker renderers
  where it transplants cleanly; do not fork a third width-allocation
  implementation if a shared helper will serve. If sharing means moving
  code into `scripts/lib/`, move it and keep both callers green.
- The smoke supplies fixture data only; it never asserts against values it
  wrote into the expected output itself (run-lessons entry 15).
- Curses cleanup must be unconditional: a crash or ^C restores the
  terminal (endwin in a finally block, cbreak and echo restored).

## Acceptance criteria

1. `scripts/tui.sh` on a fixture repo renders the run page per the mock at
   119 columns: five panels, tab bar, key hints. Show the capture.
2. Panel `[2]` renders the wide row (glyph, id, role word where in flight,
   worker→verifier aliases, tokens) at 119 and 160, and the two-line
   wrapped form at 80. Show all three captures.
3. The active role of an in-flight pair is visibly emphasised, and the
   emphasis sits on the worker alias while the worker runs and the
   verifier alias once the verifier is dispatched. Fixture provides both
   states; show both.
4. No identifying or enumeration column truncates at any of the three
   widths: stage ids, aliases, role words, status words render whole, with
   drop-then-wrap visibly applied where space ran out.
5. The detail pane shows the selected card's roles, attempt, budget,
   token breakdown and burn sparkline, and `enter` on a different row in
   panel `[2]` repopulates it. Show before and after.
6. The burn rate is computed from successive poll deltas: the smoke feeds
   two fixture payloads differing by a known token count and asserts the
   rendered rate matches that delta over the interval.
7. Resize reflows: captures at 160, 119 and 80 show three genuinely
   different layouts (wide, narrowed, stacked), none clipped, and `q`
   afterwards leaves a working terminal (`stty -a` sane, demonstrated).
8. All figures trace to one `aggregate-dashboard.sh --repo` invocation per
   refresh; the renderer opens no state file of its own. The verifier
   checks imports and file access, not just the claim.
9. The smoke passes with locale and TERM pinned, fails on the pre-fix tree,
   and every assertion helper can fail loudly (an absent expected string is
   a FAIL, never a silent skip).
10. Pages 2 and 3 exist as tabs rendering their placeholder line; switching
    to them and back does not disturb page 1's state.

## Contract test

Render the run page against a fixture payload holding seven cards (three
completed, two in flight with opposite active roles, one queued, one
escalated), two live agents, one escalation, at 80, 119 and 160 columns.
Every stage id, alias, role and status renders whole at every width; panel
[2] carries worker→verifier on every row; the burn figure equals the
fixture's poll delta; nothing scrolls, nothing clips.

## Out of scope

- The history page (card 70) and the messages page (card 71), beyond their
  placeholder tabs.
- The HTML dashboard; the browser gets this treatment after the TUI settles.
- Any change to tick.sh, the controller, or what the aggregator already
  emits for existing consumers.
- Mouse support.

## Budget

- **Worker wall-clock:** 120 minutes
- **Verifier wall-clock:** 45 minutes

## Verifier handoff

Return the three width captures of the run page, the wide and wrapped panel
[2] rows, the two active-role states, the detail-pane before and after, the
burn-rate assertion, the resize sequence with the restored terminal, the
single-seam check, and the smoke run before and after.

## Family-specific notes

None
