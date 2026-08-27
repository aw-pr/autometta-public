# Stage card 80: long stage ids line up in the run table

## Metadata

- **Authored:** 2026-08-27
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Verifier:** Claude Fable 5 <claude-fable-5@local>
- **Base branch:** dev
- **Run branch:** autometta/80-long-stage-ids-line-up-in-the-run-table
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/lib/tui/render.py, scripts/tui-smoke.sh
- **Pairing rationale:** the premium display pair. The deliverable is what an
  operator sees, and a cheap tier writes a smoke that passes while the columns
  are still wrong.

## Objective

In the TUI's `[2] This run` pane, a stage id longer than the column drops to
its own line and leaves its status row beneath it, so one row occupies two
lines while its neighbours occupy one and nothing lines up. Captured at 110
columns:

```
▶  01-stats        WORKER  gpt-oss-20b→gpt-oss-120b  153.7K
○  02-percent      queued  gpt-oss-120b→gpt-oss-20b  0
○  03-memory       queued  gpt-oss-20b→gpt-oss-120b  0
  04-wire-exports
○                  queued  gpt-oss-120b→gpt-oss-20b  0
```

The wrap is deliberate: identifying columns are never truncated, they
drop-then-wrap. The rule is right and stays. What is wrong is the result,
which reads as a rendering glitch rather than as a wrapped identifier, because
the marker column empties, the id loses its own marker, and the continuation
is not visibly a continuation.

Make a wrapped row read as one row. The design is yours to choose and defend;
whatever you pick must hold at 80, 119 and 160 columns and must never truncate
an id.

## Inputs (read these in your own context)

- scripts/lib/tui/render.py
- scripts/tui-smoke.sh
- docs/observability.md

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. A change to the run table's row rendering in `scripts/lib/tui/render.py` so
   a wrapped stage id reads as a single logical row.
2. Assertions in `scripts/tui-smoke.sh` covering an id long enough to wrap at
   each of 80, 119 and 160 columns, asserting the id survives whole and that
   the row's marker and status stay associated with it.

## Constraints

- No id may be truncated or ellipsised at any width. That rule is load-bearing.
- Do not change the column set or the order of columns.
- Do not touch `app.py`, `messages.py` or any script outside Path claims.
- The pane must still fit its height without scrollback at 80x24.
- British English, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

1. `bash scripts/tui-smoke.sh` exits 0.
2. `bash scripts/tui-history-smoke.sh` and `bash scripts/tui-messages-smoke.sh`
   both still exit 0.
3. A capture at 80, 119 and 160 columns of a fixture containing an id of at
   least 40 characters is included in the handoff, and in each the id appears
   whole and its status is unambiguously attached to it.
4. Reverting the render change makes the new assertions fail, shown in the
   handoff.
5. No file outside Path claims is modified.

## Contract test

- **Test file:** scripts/tui-smoke.sh
- **Assertions digest:** None

## Out of scope

- The history and messages pages.
- Column widths in the repo ticker or fleet ticker, which are separate
  renderers with their own cards.

## Budget

- **Worker wall-clock:** 2400s
- **Verifier wall-clock:** 1800s

## Verifier handoff

Leave the working tree dirty. Include the three captures inline and say in one
sentence what rule you chose for a wrapped row and why.

## Family-specific notes

None
