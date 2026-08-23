# Stage card 43: a terminal status for a card that should not run

## Metadata

- **Authored:** 2026-08-23
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Claude Opus 5 <claude-opus-5@local>
- **Verifier:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Base branch:** dev
- **Run branch:** autometta/43-superseded-stage-status
- **Worker effort:** medium
- **Verifier effort:** medium
- **Verifier panel:** false
- **Pairing rationale:** a schema change plus the tick's reading of it. Verified
  cross-family because the risk is a status that reads fine to its author and
  wrongly to every later reader of the ledger.

## Objective

`state.yaml`'s status enum is `pending, in_progress, completed, failed, stalled,
verifier_failed`. There is no way to say "this card should not run, and that is
not a failure".

On 2026-08-23 three emergence-lab cards (14, 15, 16) were retired because later
work had overtaken their acceptance criteria. Card 16's own implementation had
been deliberately reverted ten days after it landed. None of that is failure,
but `failed` was the only terminal status available, so the ledger now records
three failures that misstate what happened, and `consecutive_failures` counted
them against the halt cap.

Add a terminal `superseded` status that is honest about this and is not treated
as a failure by the budget.

## Inputs (read these in your own context)

- `schemas/state.yaml.json`
- `scripts/tick.sh` (stage selection and terminal handling; `next_stage` is the
  narrow point, it selects on `status == "pending"`)
- `scripts/budget.sh` (consecutive-failure accounting)
- `scripts/requeue-stage.sh`
- `docs/dispatch-contract.md`

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `schemas/state.yaml.json` — `superseded` added to the status enum, with the
   description stating it is terminal, means the card should not run, and is
   not a failure.
2. `scripts/tick.sh` — a superseded stage is never dispatched and never
   reaped as stalled.
3. `scripts/budget.sh` — a superseded stage does not increment
   `consecutive_failures` and cannot contribute to a failure-cap halt.
4. `scripts/requeue-stage.sh` — re-queueing a superseded stage requires an
   explicit `--force`, since doing so contradicts a recorded human decision.
   Without it, refuse non-zero with a message naming the status.
5. `docs/dispatch-contract.md` — the status documented alongside the existing
   terminal states, with the retirement of emergence-lab 14/15/16 as the worked
   example, and guidance that the card itself must carry the reason.
6. The contract version bumped per the repo's own rule that a change to the
   shape of the contract is a versioned decision.

## Constraints

- Existing states keep their present meanings. This adds one value; it does not
  redefine `failed`.
- A state file written before this change must still validate and behave
  identically. No migration step may be required.
- Do not retroactively rewrite emergence-lab's state or any other subscriber's.
  That is a separate operator decision, and this card must not reach into
  another repo.
- Terminal means terminal: `superseded` must not become a state the tick can
  leave on its own.

## Acceptance criteria

1. A `state.yaml` carrying a `superseded` stage validates against the schema.
2. With a superseded stage ahead of a pending one, a tick dispatches the pending
   stage and leaves the superseded one untouched.
3. A superseded stage does not increment `consecutive_failures`, demonstrated
   against `scripts/budget.sh`.
4. `requeue-stage.sh` on a superseded stage refuses non-zero without `--force`
   and proceeds with it.
5. A pre-change `state.yaml` fixture validates and ticks exactly as before.
6. `docs/dispatch-contract.md` documents the status and the version is bumped.
7. `bash -n` passes on every shell file touched; `npm run verify` or the repo's
   own gate passes if one applies; no file outside the deliverables is modified
   except this card.

## Contract test

- **Test file:** None
- **Assertions digest:** None

## Out of scope

- Any status beyond `superseded` (no `blocked`, no `deferred`).
- A CLI subcommand for retiring a card. Editing state plus writing the reason on
  the card is enough; add the verb only if the need recurs.
- Changing how cards are authored or re-briefed.

## Budget

- **Worker wall-clock:** 60 minutes
- **Verifier wall-clock:** 30 minutes

## Verifier handoff

Return the schema diff, the tick behaviour from criterion 2 with the ledger
lines showing which stage was chosen, the budget result from criterion 3, both
`requeue-stage.sh` outcomes from criterion 4, and the backward-compatibility
evidence from criterion 5. State the old and new contract version.

## Family-specific notes

None
