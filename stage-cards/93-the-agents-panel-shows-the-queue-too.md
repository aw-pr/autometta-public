# Stage card 93: the agents panel shows the queue too

## Metadata

- **Authored:** 2026-08-31
- **Orchestrator:** Claude Fable 5 <claude-fable-5@local>
- **Worker:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Verifier:** Claude Fable 5 <claude-fable-5@local>
- **Base branch:** dev
- **Run branch:** autometta/93-the-agents-panel-shows-the-queue-too
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Gate:** stage-completed: 91-the-burn-is-visible-while-it-burns
- **Path claims:** scripts/lib/tui/render.py, scripts/lib/tui/app.py, docs/observability.md
- **Pairing rationale:** premium pairing for display work, the standing
  feedback rule: cheap tiers game display smokes, so Sol builds the surface
  and the Fable verifier sits where the operator will sit. Same seats as
  card 92, whose dashboard panel this card's TUI panel mirrors.

## Objective

UAT feedback from the 2026-08-31 run: the dashboard's AGENTS AND QUEUE
panel shows queued next stages with their worker and verifier seats, but
the TUI's `[3] Agents` panel goes blank between dispatches and reads
"no live agents". Between ticks that is most of the time, so the panel
spends most of its life saying nothing while the operator's actual
question is "what runs next, and who sits where".

The data is already on the seam: `scripts/aggregate-dashboard.sh` emits a
per-repo `queue` array (stage_id, worker, verifier) in the same payload
the TUI polls, and the dashboard renders those rows as `next`/`queued`.
The TUI's `agent_lines` in `scripts/lib/tui/render.py` renders only the
live registry and ignores `queue` entirely. Close the gap on the render
side only: append the queued stages below the live agents, dimmed, with a
`queued` marker and the worker/verifier aliases, and retitle the panel so
its count reads "N live, M queued". No new data source, no new poll, no
seam change.

## Inputs (read these in your own context)

- scripts/lib/tui/render.py (`agent_lines`, `identity_alias`, the panel
  title helpers)
- scripts/lib/tui/app.py (panel focus and selection over the agents list)
- dashboard/dashboard.js (the queued-row rendering this mirrors, around
  the AGENTS AND QUEUE table)
- docs/observability.md (the TUI panel descriptions)

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/lib/tui/render.py`: `agent_lines` (and the panel title) render
   live agents first, then one dimmed row per `queue` entry:
   `○ <stage_id> queued  <worker alias> / <verifier alias>`. The
   "no live agents" placeholder appears only when both lists are empty.
2. `scripts/lib/tui/app.py`: selection on the agents panel stays confined
   to live rows; queued rows are display-only and unreachable by the
   cursor, so nothing downstream (messages, detail) receives a queued row
   as if it were a live agent.
3. `docs/observability.md`: the agents panel description says it shows
   live agents and the queued next stages, and names the payload `queue`
   field as the source.

## Constraints

- Render-side only: no change to `scripts/aggregate-dashboard.sh`, the
  payload shape, or the poll cadence. If a field the card names is absent
  from the payload, render what is present rather than adding a producer
  change; a producer gap is a finding for the verifier handoff, not scope.
- A payload with no `queue` key (older aggregate, other repos) must render
  exactly as today; the panel never crashes or blanks on missing data.
- Alias rendering reuses `identity_alias`; no second identity formatter.
- British English in prose, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

1. `python3 -m py_compile scripts/lib/tui/render.py scripts/lib/tui/app.py`
   passes and `scripts/tui-smoke.sh` still passes.
2. From a fixture payload with zero live agents and two queued stages, the
   agents panel renders two dimmed queued rows with stage id, the word
   `queued`, and both seat aliases; "no live agents" does not appear.
3. From a fixture payload with one live agent and one queued stage, the
   live row renders first in today's format, the queued row below it, and
   the panel title counts both ("1 live, 1 queued").
4. From a fixture payload with no `queue` key, the panel renders exactly
   as it does on dev today (live rows, or the placeholder).
5. With the cursor on the agents panel, selection skips queued rows: the
   selectable index range equals the live-agent count (evidence from a
   fixture-driven run or a unit-level check of the selection bound).
6. `git diff --stat` on the run branch touches only the three claimed
   paths.

## Contract test

- **Test file:** None
- **Assertions digest:** None

## Out of scope

- Any producer change to aggregate-dashboard.sh or the payload contract.
- Interacting with queued rows (dispatch, reorder, message): the queue is
  the tick's to move, per the load-bearing beliefs.
- The dashboard side, which already shows the queue (and card 92 extends).

## Budget

- **Worker wall-clock:** 1800s
- **Verifier wall-clock:** 1500s

## Verifier handoff

Leave the working tree dirty. Report the rendered panel for each of the
four fixture cases verbatim (captured frames or line dumps), the selection
bound evidence, and the smoke output.

## Family-specific notes

None
