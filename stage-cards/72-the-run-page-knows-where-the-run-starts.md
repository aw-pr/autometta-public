# Stage card 72: the run page knows where the run starts

## Metadata

- **Authored:** 2026-08-26
- **Orchestrator:** Claude Fable 5 <claude-fable-5@local>
- **Worker:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Verifier:** Claude Fable 5 <claude-fable-5@local>
- **Base branch:** dev
- **Run branch:** autometta/72-the-run-page-knows-where-the-run-starts
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Gate:** stage-completed: 71-the-operator-talks-to-the-controller
- **Pairing rationale:** same seats as the rest of the TUI batch; the fix
  spans the aggregator and the page those seats built. Serial batch, so
  family alternation for pipeline overlap does not apply.

## Objective

Card 69 passed on fixtures and misbehaves on the real repo, because the
fixtures only ever contained one run's worth of stages. Against live
`state/state.yaml` the run page shows:

- Panel `[2]` "This run  47 of 50", led by cards from May, with the
  current batch buried under "and 49 more". The page renders every stage
  the state store has ever recorded, because nothing in the store says
  where one run ends and the next begins.
- "run start 09:14:27Z  elapsed 2135h29m": elapsed computed from the
  oldest stage on record, roughly 89 days, same root cause.

The fix is state semantics first, rendering second: **a run gets an
identity the state store carries.**

The decision, settled here: `add-stage.sh` stamps each stage record with a
`run_id` at queue time. The run id is minted when a stage is added while no
other stage is pending or in progress (the queue-empty boundary), and every
stage added while that run's stages are still outstanding joins the same
run. The id is the mint timestamp, UTC, `run-YYYYMMDD-HHMMSS`. Stages
recorded before this card exist without a `run_id`; they are historic by
definition and belong to no current run. No backfill.

## Inputs (read these in your own context)

- `scripts/add-stage.sh`, which writes the stage record.
- `scripts/tick.sh` only as far as confirming it preserves unknown stage
  fields (it must not strip `run_id` on state transitions).
- `scripts/aggregate-dashboard.sh`, the data seam that must expose the
  scoping.
- `scripts/lib/tui/render.py` and `app.py`, card 69's run page.
- `scripts/tui-smoke.sh`, whose fixture must learn what live data taught.
- `schemas/`, if a schema there describes the stage record; extend it in
  the same commit.

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. **`run_id` stamping in `add-stage.sh`** per the settled decision above:
   minted at the queue-empty boundary, inherited while the run is
   outstanding, format `run-YYYYMMDD-HHMMSS`.
2. **The aggregator exposes the scoping additively**: the current run's id,
   its stages, its start (the mint time), and its token and cost totals.
   Nothing already emitted changes shape; the HTML dashboard and both
   tickers keep reading what they read today.
3. **Panel `[2]` renders the current run only**: the mock's "5 of 7"
   against the current run's cards, completed then in flight then queued,
   the current batch on top of the pane, not under "and N more". When no
   run is current (queue empty, nothing in flight), the panel says so and
   offers the history tab, rather than reaching back into history itself.
4. **Status panel figures scope to the run**: run start is the run's mint
   time, elapsed follows from it, tokens and cost are the run's own. The
   repo-lifetime cap figure stays, labelled as the cap it is.
5. **The smoke fixture carries two runs**: a historic run of at least
   forty stages without and with old `run_id`s, and a current run of
   seven, so the page can only pass by scoping correctly. This is the
   fixture-honesty lesson applied: the live-data failure this card fixes
   must be reproducible in the fixture before the fix and green after.
6. **The agents-panel timing question answered**: on the live try-out,
   panel `[3]` read "0 live" and Status read IDLE while a worker was in
   flight. Investigate; if the aggregate misses a registered agent, fix
   it; if it was genuinely the gap between dispatch and registration,
   record that in the envelope with the evidence and leave the code alone.

## Constraints

- Python stdlib and bash only.
- `run_id` is additive. No rewrite of existing stage records, no backfill,
  no migration script. A state file from before this card remains valid.
- Do not change what the aggregator already emits for existing consumers.
- The history page (card 70) deliberately keeps its all-time scope; this
  card does not touch it.
- The smoke supplies fixture data only and never asserts values it wrote
  into its own expected output.

## Acceptance criteria

1. Queueing a card into an empty queue mints a fresh `run_id`; queueing a
   second while the first is outstanding joins the same run; queueing
   after both land mints a new one. Shown with three real `add-stage.sh`
   invocations against a fixture repo.
2. A tick transition (pending to in_progress to completed) preserves
   `run_id` on the stage record. Shown on the fixture.
3. Against the two-run fixture, panel `[2]` shows only the current run's
   seven cards with the mock's count form, at 80, 119 and 160 columns; the
   historic forty are absent from page 1 and present on page 2.
4. Run start equals the current run's mint time and elapsed is computed
   from it; the fixture pins a known mint time and the smoke asserts the
   arithmetic.
5. With no current run, panel `[2]` renders the empty state naming the
   history tab, and Status carries no run start or elapsed rather than a
   fabricated one.
6. Existing consumers are undisturbed: `repo-ticker-smoke.sh`,
   `fleet-ticker-smoke.sh`, `tui-history-smoke.sh` and the dashboard
   aggregation pass unmodified except where a fixture legitimately gains
   the new field.
7. The pre-fix tree fails the new smoke assertions (the two-run fixture
   reproduces the live failure); the fixed tree passes.
8. The agents-panel finding is answered per deliverable 6: a fix with
   evidence, or a timing explanation with evidence, in the envelope.
9. The smoke passes with locale and TERM pinned and its helpers fail
   loudly on anything absent.

## Contract test

On a fixture holding a historic run of forty stages and a current run of
seven with a pinned mint time: three add-stage invocations demonstrate
mint, join and re-mint; the run page at 80, 119 and 160 columns shows only
the seven with correct count, start and elapsed; emptying the current run
yields the honest empty state; all pre-existing smokes stay green.

## Out of scope

- The history page's scope (all-time is its job).
- Run identity for other repos' state files beyond what add-stage writes.
- Any retroactive assignment of `run_id` to historic stages.
- Cross-run comparison views.

## Budget

- **Worker wall-clock:** 90 minutes
- **Verifier wall-clock:** 45 minutes

## Verifier handoff

Return the mint/join/re-mint demonstration, the preserved-field check, the
three width captures against the two-run fixture, the elapsed arithmetic
assertion, the empty state, the untouched-consumer smoke runs, the pre-fix
failure of the new assertions, and the agents-panel answer with evidence.

## Family-specific notes

None
