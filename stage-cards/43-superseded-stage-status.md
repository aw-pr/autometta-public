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

### The status is not the whole job: the alerts have to stop

Reported by the operator on 2026-08-23 at 19:35Z, reading the emergence-lab
pane. Four retired cards were still raising alerts on every refresh of every
panel:

```
! 05-math-formula-rendering verifier_failed crit 6
! 14-fractal-colour-cycle-pacing verifier_failed crit 4
! 15-boids-density-motion-tuning stalled
! 16-sandpile-larger-slower failed
```

An alert panel that shows four decisions the operator has already made is the
cry-wolf failure card 41 fixed for the fleet pane in another form. Three
things have to line up before those four lines go, and this card originally
delivered only the first:

1. The status exists. That is deliverables 1 to 4 above.
2. The subscriber's ledger actually carries it. This card must not reach into
   another repo, so what it owes is a documented operator procedure, not the
   edit.
3. Every alert renderer agrees that `superseded` is not alert-worthy.

Point 3 is the one that will be missed, because the alert-worthy set is not
defined anywhere. It is spelled out as a literal list in at least four places:

```
scripts/attach.sh:107   select(.status == "failed" or .status == "verifier_failed" or .status == "stalled")
scripts/attach.sh:122   select(.status == "failed" or .status == "verifier_failed" or .status == "stalled")
scripts/agent-ticker.sh:170   if current_status in ("failed", "verifier_failed", "stalled"):
scripts/agent-ticker.sh:176   if current_status in ("failed", "verifier_failed", "stalled"):
```

Each is a whitelist, so a new status is silently excluded from all four and
this appears to work. That is luck rather than design, and card 41 has already
paid for the general version of this lesson: it found the same judgement
written three times in three places and drifting apart. Make the alert-worthy
set one definition that every renderer reads, and make `superseded`'s absence
from it a deliberate, tested fact rather than an accident of enumeration.

Note the discrepancy on card 05 before acting on it. Card 40's disposition
table records it as `verifier_failed` and "genuine failure, leave alone",
while the operator now counts it among the retired four. One of those is out
of date. The reason belongs on card 05 itself before its status changes; a
retirement with no recorded reason is indistinguishable next month from a
failure someone hid.

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
   terminal states, with the retirement of emergence-lab 05/14/15/16 as the
   worked example, and guidance that the card itself must carry the reason.
6. The contract version bumped per the repo's own rule that a change to the
   shape of the contract is a versioned decision.
7. One definition of the alert-worthy stage statuses, read by every renderer
   that currently spells the list out: `scripts/attach.sh` (both sites),
   `scripts/agent-ticker.sh` (both sites), and `scripts/aggregate-dashboard.sh`
   if it carries its own copy. `superseded` is not in it.
8. `docs/dispatch-contract.md` — an operator procedure for retiring a card in
   a subscriber repo that is already running: which field changes, what to
   write on the card, and how to confirm the alert has gone. Written so it can
   be followed against emergence-lab 05/14/15/16 without further design.

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
7. A stage with status `superseded` raises no alert in the fleet pane, the
   per-repo ticker, or the dashboard. Demonstrate against a fixture ledger
   carrying one superseded stage and one genuinely failed stage: the failed
   one still alerts. A test that only proves the superseded stage is quiet is
   half a test.
8. The alert-worthy set has exactly one definition in the tree. Show that
   changing it in one place changes every renderer.
9. Following the operator procedure from deliverable 8 against a copy of
   emergence-lab's ledger clears the four alerts and leaves every other alert
   standing.
10. `bash -n` passes on every shell file touched; `npm run verify` or the repo's
   own gate passes if one applies; no file outside the deliverables is modified
   except this card. The `state` symlink and the `state/handoffs/` deletions it
   implies are the worktree dispatch's own substitution, present in every run
   worktree before the worker starts, and are not worker changes. (Amended
   2026-08-24 after attempt 1 failed solely on this false positive.)

## Contract test

- **Test file:** None
- **Assertions digest:** None

## Out of scope

- Any status beyond `superseded` (no `blocked`, no `deferred`).
- A CLI subcommand for retiring a card. Editing state plus writing the reason on
  the card is enough; add the verb only if the need recurs. The need has now
  recurred once, for four cards at a time, so record in the handoff whether it
  is time.
- Editing emergence-lab's ledger. The procedure is this card's deliverable;
  running it is the operator's, after this card lands.
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

## Re-brief for attempt 2 (2026-08-24, after the criterion 10 false positive)

Attempt 1 passed criteria 1 to 9; the artefact at
`state/verifiers/43-superseded-stage-status.json` holds the evidence. The
whole implementation is committed as `296bff1` (branch `wip/43-attempt-1`).
Restore it, re-run `scripts/superseded-status-smoke.sh`, and hand off. No
functional change is asked for; criterion 10 above now states that the
dispatch's own `state` substitution is not in scope.
