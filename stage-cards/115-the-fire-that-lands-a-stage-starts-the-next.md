# Stage card 115: the fire that lands a stage starts the next

## Metadata

- **Authored:** 2026-09-06
- **Orchestrator:** Claude Fable 5.1 <claude-fable-5-1@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Base branch:** dev
- **Run branch:** autometta/115-the-fire-that-lands-a-stage-starts-the-next
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Gate:** stage-completed: 111-dev-moving-does-not-park-a-disjoint-landing
- **Path claims:** scripts/tick.sh, scripts/landing-dispatch-smoke.sh, docs/tick-loop.md, docs/philosophy.md, stage-cards/115-the-fire-that-lands-a-stage-starts-the-next.md
- **Pairing rationale:** cross-family. The change is small and the invariant it bends is
  documented as a belief; the verifying seat is asked to read the belief
  and confirm the envelope argues for the exception honestly.
- **Type:** Loop latency. Touches `scripts/tick.sh`, so serial.

## Surfacing concern

`consume_verifier_artefact` returns at `scripts/tick.sh:2700-2704` after
landing a stage, and the pending-dispatch branch is the `else` at `:3038`,
so landing N and dispatching N+1 never happen in the same fire. The same
holds when the verifier writes its artefact and lingers: the artefact is
consumed one fire later (`:2683-2689`). Each is one fire of pure waiting,
46 seconds today (card 114 aims at 15), paid on every stage.
`docs/tick-loop.md:35` states the belief: a tick is one transition.

## Objective

When a fire lands a stage and the queue holds an eligible pending stage,
the same fire dispatches it. The one-transition rule is restated as one
transition *per stage* per fire, and the document says why.

## Inputs (read these in your own context)

- `scripts/tick.sh:2680-2710` and `:3030-3060`, the consume path and the
  pending-dispatch branch
- `docs/tick-loop.md:26-35` and `docs/philosophy.md`, the one-transition
  belief
- `scripts/tick-cost-smoke.sh`, for how the smoke counts work ticks

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. After a successful `consume_verifier_artefact` that lands the stage,
   `process_repo` falls through to the pending-dispatch logic instead of
   returning, guarded by every check that branch already applies (budget,
   gate, halt, preflight from card 108 if landed). A park (awaiting
   integration) also falls through; a FAIL does not.
2. The work-tick accounting counts this as one work tick, not two; document
   the choice.
3. `scripts/landing-dispatch-smoke.sh`: a fixture with two pending stages,
   worker and verifier stubbed, lands stage 1 and shows stage 2's worker
   dispatched in the same fire's log; a fixture where stage 2's gate is
   unmet lands stage 1 and dispatches nothing. Frozen block around those
   assertions.
4. `docs/tick-loop.md` and `docs/philosophy.md`: the rule becomes one
   transition per stage per fire, with the reason (a landed stage is
   terminal; nothing about it can be re-read by the next fire) and the
   boundary (never two transitions on the same stage in one fire).

## Constraints

- Never dispatch the next stage in the fire that *fails* a stage; a FAIL
  needs a human between it and the next dispatch.
- The `return 0` lines that protect against double-writes on the same stage
  stay.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. Fixture one dispatches stage 2 in the landing fire; fixture two does not.
2. `state.yaml` after fixture one shows stage 1 `completed` and stage 2
   `in_progress` with a `started_at` later than stage 1's `completed_at`.
3. `scripts/landing-dispatch-smoke.sh` passes and fixture one fails against
   the pre-change `tick.sh`.
4. `scripts/tick-cost-smoke.sh`, `scripts/budget-cap-smoke.sh` and
   `scripts/pipeline-pair-smoke.sh` are no more red than on clean `dev`.

## Contract test

- **Test file:** scripts/landing-dispatch-smoke.sh
- **Assertions digest:** frame the assertions in a block between the begin
  marker and the end marker, the begin marker naming this card by its
  `card=stage-cards/115-the-fire-that-lands-a-stage-starts-the-next.md` field, and replace this line's text with the real
  digest printed by `scripts/check-contract-test-gate.sh print scripts/landing-dispatch-smoke.sh`. Do not
  write a `sha256:` comment inside the block, and do not spell the marker
  tokens anywhere in this card's prose; the card is in your path claims for
  exactly this edit.

## Out of scope

- Consuming a lingering verifier's artefact before its process exits;
  card 96 owns that seam.

## Budget

- **Worker wall-clock:** 60 minutes
- **Verifier wall-clock:** 30 minutes

## Escalation

If falling through requires re-reading `state.yaml` mid-fire in a way the
read/write guards (`state_apply_json`) forbid, stop and report the guard
that fires.

## Verifier handoff

Count transitions in the fixture log yourself: exactly two, on two
different stages. Then break it: make the fixture's stage 1 FAIL and
confirm no dispatch follows. Read the philosophy edit and reject wording
that removes the belief rather than bounding it.

## Family-specific notes

None

## Seat history (2026-09-06)

The Codex subscription closed at 10:31Z and this batch was re-seated onto
Claude alone; when Claude session windows then drained faster than the batch
was sized for, the verifying seat moved to the free local route
(`gpt-oss:120b` via `codex exec --oss`). The Codex window reopened the same
afternoon and the card is back on the seats it was authored with. Nothing
about the work changed across either move.
