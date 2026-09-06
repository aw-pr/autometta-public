# Stage card 117: the TUI reads the alert set, it does not spell it

## Metadata

- **Authored:** 2026-09-06
- **Orchestrator:** Claude Fable 5.1 <claude-fable-5-1@local>
- **Worker:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Verifier:** Claude Opus 5 <claude-opus-5@local>
- **Base branch:** dev
- **Run branch:** autometta/117-the-tui-reads-the-alert-set-it-does-not-spell-it
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/lib/tui/render.py, scripts/superseded-status-smoke.sh, stage-cards/117-the-tui-reads-the-alert-set-it-does-not-spell-it.md
- **Pairing rationale:** cross-model, single family (re-seated 2026-09-06, see below). A single-definition rule the TUI broke on 2026-09-02; the
  verifying seat verifies because it reads Python renderers fluently and the
  criterion is that a grep finds nothing.
- **Type:** Red-smoke repair. Claims `scripts/lib`, so serial under the current rule.

## Surfacing concern

`scripts/superseded-status-smoke.sh:361-366` asserts that no renderer
spells out the alert statuses for itself; `scripts/alert-statuses.sh` is the
one definition. The 2026-09-02 TUI change that split `ESCALTD` into
`STALLED`, `V-FAILED` and `FAILED` re-enumerated the set at
`scripts/lib/tui/render.py:454`, `:459` and `:496`. The smoke has been red
on clean `dev` since, and the handoff for that session recorded it as
pre-existing, which it was not.

## Objective

`render.py` obtains the alert set from `scripts/alert-statuses.sh` (its JSON
entry point) and derives the three labels from it; the smoke's grep finds
no literal enumeration.

## Inputs (read these in your own context)

- `scripts/alert-statuses.sh`, both entry points
- `scripts/lib/tui/render.py:440-500`
- `scripts/superseded-status-smoke.sh:355-370`
- how `render.py` already receives shell-side facts (the payload it is
  given), so the set arrives the same way rather than by a subprocess per
  frame

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. `render.py` reads the alert set once from the payload or from the
   script's JSON output at startup, and maps status to label with a
   dictionary keyed by that set. `superseded` stays absent because the
   source omits it.
2. The `STALLED` / `V-FAILED` / `FAILED` labels are unchanged on screen.
3. `scripts/superseded-status-smoke.sh` passes; if its grep at `:361-363`
   needs to learn the new shape, update the frozen block and the digest.

## Constraints

- No subprocess per render frame; `tui-smoke` asserts the seam answers in
  a second (card 74).
- `scripts/tui-smoke.sh` and `scripts/tui-messages-smoke.sh` unchanged in
  outcome.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. `scripts/superseded-status-smoke.sh` passes on the run branch.
2. `grep -n 'verifier_failed' scripts/lib/tui/render.py` returns no line that
   enumerates the set alongside `stalled` and `failed`.
3. A TUI capture (the smoke's own fixture) still shows the three labels.
4. `scripts/tui-smoke.sh` and `scripts/tui-messages-smoke.sh` pass.

## Contract test

- **Test file:** scripts/superseded-status-smoke.sh
- **Assertions digest:** frame the assertions in a block between the begin
  marker and the end marker, the begin marker naming this card by its
  `card=stage-cards/117-the-tui-reads-the-alert-set-it-does-not-spell-it.md` field, and replace this line's text with the real
  digest printed by `scripts/check-contract-test-gate.sh print scripts/superseded-status-smoke.sh`. Do not
  write a `sha256:` comment inside the block, and do not spell the marker
  tokens anywhere in this card's prose; the card is in your path claims for
  exactly this edit.

## Out of scope

- Alerting on `superseded`; the source file says why not.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes

## Escalation

If the payload has no place to carry the set and adding one means
touching `aggregate-dashboard.sh`, do that within this card only if the
change is one field; otherwise stop and report.

## Verifier handoff

Run the smoke's grep yourself against the run branch, then add a fake
status to `alert-statuses.sh` in a scratch copy and confirm the TUI picks it
up without a `render.py` edit. That is the property the single definition
exists for.

## Family-specific notes

None

## Re-seat (2026-09-06, Codex subscription exhausted)

Both Codex seats were unavailable from 10:31Z with the subscription window
closed until 14:49Z, and every card in this batch carried one, so the queue
could not move. On the operator's instruction the batch was re-seated onto
Claude alone: high-effort cards run Opus as worker and Sonnet as verifier,
the rest run Sonnet as worker and Opus as verifier, so worker and verifier
are never the same model.

What this keeps: the sandbox boundary, which is what makes worker
self-verification structurally impossible, is a property of the dispatch and
not of the vendor, so it is untouched. What it costs: judgement diversity.
A Claude verifier shares training and failure modes with a Claude worker in
a way a Codex verifier did not, so a wrong assumption the worker makes is
likelier to survive verification. Two different Claude models recover part
of that and not all of it. Read this card's acceptance criteria as needing
more, not less, evidence than usual.
