# Stage card 75: the run rows name models and line up

## Metadata

- **Authored:** 2026-08-26
- **Orchestrator:** Claude Fable 5 <claude-fable-5@local>
- **Worker:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Verifier:** Claude Fable 5 <claude-fable-5@local>
- **Base branch:** dev
- **Run branch:** autometta/75-the-run-rows-name-models-and-line-up
- **Worker effort:** medium
- **Verifier effort:** medium
- **Verifier panel:** false
- **Gate:** stage-completed: 74-the-seam-answers-in-a-second
- **Pairing rationale:** presentation work stays on a premium seat; a
  small card, so effort drops to medium. Re-paired pre-dispatch from Sol
  on the operator's 2026-08-26 ruling: the codex 5-hour window hit 95%,
  the rest of the batch runs on Claude seats only, same-family
  sanctioned. Serial batch.

## Objective

Operator feedback on the live run page (2026-08-26, with a capture):
panel `[2]` renders `codex→claude  0` style rows -- family aliases where
the model is known, and ragged fields that read as prose rather than
columns.

Two corrections, both settled by the feedback:

1. **The pairing alias names the model, not the family.** The alias
   derives from the identity's slug: `gpt-5-6-sol@local` renders `sol`,
   `codex-gpt-5-3@local` renders `gpt-5.3`, `claude-opus-4-7@local`
   renders `opus-4.7`, `claude-fable-5@local` renders `fable`. The rule:
   strip the family prefix (`claude-`, `codex-`) and any vendor noise,
   keep the distinguishing model token, prefer a bare release name
   (`sol`, `terra`, `luna`, `fable`) where the slug carries one. Family
   alone (`codex`, `claude`) renders only when the identity genuinely
   carries nothing more, and an unknown slug renders its slug rather
   than a guess. One mapping function, shared by every page that renders
   an alias (run page, history page, detail pane), so the aliases cannot
   drift apart. This also fixes the history footer's "claude 52% claude
   23%" duplicate, two distinct models collapsed to one family label.
2. **The rows tabulate.** Glyph, stage id, status, pairing and tokens
   align as columns down the panel, no header row -- alignment does the
   header's job. The settled column rules apply: the id column takes the
   remainder, identifying columns never truncate, drop-then-wrap below
   the width where the columns fit.

## Inputs (read these in your own context)

- `scripts/lib/tui/render.py`, the run page rows, the history footer and
  the detail pane's alias uses.
- `scripts/lib/tui/app.py`, only if the alias mapping lives better beside
  the payload handling.
- `scripts/tui-smoke.sh` and `scripts/tui-history-smoke.sh`, whose
  fixtures carry full identity strings already.

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. One alias function implementing the slug rule above, unit-exercised
   by the smoke against every canonical identity in the fixtures plus an
   unknown slug.
2. Panel `[2]` rows tabulated per the rule, model aliases in the pairing
   column, at 80, 119 and 160 columns.
3. The history page's by-model footer and per-card pairing column use
   the same function; the duplicate family label disappears.
4. Smoke assertions: column start offsets constant down panel `[2]` at
   each width (the card 66 offset discipline, applied to this panel),
   model aliases present for fixture identities, family fallback only
   for a fixture identity that genuinely lacks a model token.

## Constraints

- Python stdlib only; render-side change, no seam change.
- No header row in panel `[2]`.
- The settled identifier rules stay: ids whole, drop-then-wrap, ellipsis
  only in detail columns.
- Existing smokes pass, updated only where an assertion legitimately
  encodes the old family alias.

## Acceptance criteria

1. Panel `[2]` shows tabulated rows with aligned columns at 80, 119 and
   160 on a fixture spanning old-style identities (gpt-5.3, opus-4.7)
   and current ones (sol, terra, fable). Three captures.
2. No family-only alias renders for an identity whose slug carries a
   model; the unknown-slug fixture renders its slug.
3. The history footer names distinct models with no duplicate label; the
   pairing columns on both pages agree with the detail pane for the same
   card.
4. Column offsets are constant down the panel at each width, asserted by
   the smoke per the offset discipline.
5. Smokes pass with locale and TERM pinned, fail on the pre-fix tree,
   helpers fail loudly.

## Contract test

Against a fixture mixing gpt-5.3, opus-4.7, sol, terra, fable and one
unknown slug: panel [2] tabulates with constant column offsets at 80, 119
and 160, every pairing shows model-level aliases, the unknown slug shows
itself, and the history footer lists each model once.

## Out of scope

- The run scoping (card 72), the poll loop (card 73), the seam (card 74).
- Renaming identities in state or history; this is display only.
- Header rows or column configuration.

## Budget

- **Worker wall-clock:** 60 minutes
- **Verifier wall-clock:** 30 minutes

## Verifier handoff

Return the three width captures, the alias table for every fixture
identity, the matching history footer, the offset assertions, and the
smoke runs before and after.

## Family-specific notes

None

### Operator note on seats (2026-08-26, 12:32 London)

The codex weekly window reset and the Claude session limit bit mid-flight
(the Opus attempt on card 74 died on it at 9.7M tokens). Seats restored to
the original cross-family pairing above; the 95%-window ruling that moved
this card to Claude seats is spent.
