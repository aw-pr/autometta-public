# Stage card 119: the fleet ticker smoke asks for the plan attach prints

## Metadata

- **Authored:** 2026-09-06
- **Orchestrator:** Claude Fable 5.1 <claude-fable-5-1@local>
- **Worker:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Verifier:** Claude Opus 5 <claude-opus-5@local>
- **Base branch:** dev
- **Run branch:** autometta/119-the-fleet-ticker-smoke-asks-for-the-plan-attach-prints
- **Worker effort:** low
- **Verifier effort:** medium
- **Verifier panel:** false
- **Path claims:** scripts/fleet-ticker-smoke.sh, stage-cards/119-the-fleet-ticker-smoke-asks-for-the-plan-attach-prints.md
- **Pairing rationale:** cross-model, single family (re-seated 2026-09-06, see below). Smallest card in the batch; the verifying seat verifies by
  reading `attach.sh`'s plan and deciding whether the smoke or the plan is
  the authority.
- **Type:** Red-smoke repair. Pipeline-eligible.

## Surfacing concern

`scripts/fleet-ticker-smoke.sh:454-457` asserts the `attach.sh --dry-run`
plan contains `third window: fleet` and `default window: repo`. Card 69
(the TUI lands on the run page) changed the plan deliberately:
`scripts/attach.sh:307-314` now prints `default window: tui`, then repo,
status, and `fourth window: fleet`. The smoke was never updated and has
been red on clean `dev` since.

## Objective

The smoke asserts what the plan is meant to guarantee, that the fleet
page is reachable as its own window and that window 0 is not the fleet
page, in terms that survive the window order card 69 chose.

## Inputs (read these in your own context)

- `scripts/attach.sh:290-340`
- `scripts/fleet-ticker-smoke.sh:445-460`
- `stage-cards/69-the-tui-lands-on-the-run-page.md`, for what was decided

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. The two assertions become: the plan contains a line matching
   `window: fleet` that is not the default window; the default window line
   names `tui`. Frozen block and digest updated.

## Constraints

- `attach.sh` is not touched.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. `scripts/fleet-ticker-smoke.sh` passes on the run branch.
2. Changing `attach.sh` in a scratch copy to make fleet the default window
   makes the smoke fail.

## Contract test

- **Test file:** scripts/fleet-ticker-smoke.sh
- **Assertions digest:** frame the assertions in a block between the begin
  marker and the end marker, the begin marker naming this card by its
  `card=stage-cards/119-the-fleet-ticker-smoke-asks-for-the-plan-attach-prints.md` field, and replace this line's text with the real
  digest printed by `scripts/check-contract-test-gate.sh print scripts/fleet-ticker-smoke.sh`. Do not
  write a `sha256:` comment inside the block, and do not spell the marker
  tokens anywhere in this card's prose; the card is in your path claims for
  exactly this edit.

## Out of scope

- The ticker's column layout; the rest of the smoke covers it and passes.

## Budget

- **Worker wall-clock:** 30 minutes
- **Verifier wall-clock:** 20 minutes

## Escalation

If `attach.sh`'s plan output is itself inconsistent between the `--ensure`
and plain forms, report it and assert on the plain form only.

## Verifier handoff

Run criterion 2 yourself. Read card 69 to confirm the landing-window
decision is the current intent rather than assume the smoke was right.

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
