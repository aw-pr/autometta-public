# Stage card 32-cost-log-attribution-and-totals: every cost line is anonymous and some are impossible

## Metadata

- **Authored:** 2026-08-16
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** <<worker-identity>>
- **Verifier:** <<verifier-identity>>
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Pairing rationale:** <<fill at dispatch — cross-family>>

## Objective

`state/cost-log.jsonl` lines in `emergence-lab-gpu` carry `"stage": null` and
`"family": null`, and several report per-run token totals larger than any
model's context window. The cost log is the only record of what a run cost and
it cannot currently answer which stage, which family, or — for some lines —
whether the number is real.

## Reported by

Found on 2026-08-16 while quantifying the budget overrun in card 31. Sample
lines from `~/repos/emergence-lab-gpu/state/cost-log.jsonl`:

```json
{"ts":"2026-08-15T21:50:31Z","stage":null,"role":"worker","family":null,"tok":19019631,"usd":57.058893}
{"ts":"2026-08-15T22:15:38Z","stage":null,"role":"worker","family":null,"tok":16699506,"usd":50.098518}
{"ts":"2026-08-15T21:25:23Z","stage":null,"role":"verifier","family":null,"tok":3924435,"usd":58.866525}
```

Three separate problems in three lines:

1. **`stage` and `family` are null on every line.** `role` survives, so the
   writer is reached and partially populated. 38 lines, no stage attribution on
   any of them. Per-stage cost analysis — the thing the cost log exists for —
   is impossible.
2. **19,019,631 tokens in one worker run.** No model this loop dispatches to
   has a context anywhere near that. A single run cannot legitimately produce
   it. The plausible readings are a cumulative usage figure being re-added per
   streaming event, or one log being parsed more than once, but that is a guess
   and settling it is the work.
3. **The rate applied looks wrong per role.** The verifier line bills
   3,924,435 tokens at $58.87 while the worker line bills 19,019,631 tokens at
   $57.06 — roughly a 5x difference in implied unit rate. With `family` null,
   `scripts/rates.sh` cannot be selecting a tier from anything reliable, so
   whichever default it falls back to is being applied inconsistently.

This matters beyond tidiness. Card 31 shows the budget cap was blown by 150x;
these totals are the numbers a future operator would reach for to understand
that, and at least one of the three defects makes them untrustworthy.

## Inputs (read these in your own context)

- scripts/cost-log.sh — the writer, and where `stage` / `family` should come from
- scripts/rates.sh — per-tier rates and how a tier is chosen with `family` null
- scripts/tick.sh — the per-role cost-log call sites, and what it has in scope
  at that point (it knows the stage; the question is why the writer does not)
- scripts/budget.sh — `budget_parse_tokens_from_log` and the two documented
  log formats, for the double-count question
- scripts/claude-token-log.sh — the `Total tokens:` line it synthesises
- docs/cost-log.md — the schema and the prompt-caching notes
- scripts/cost-log-smoke.sh — the existing offline gate, which passes today and
  therefore does not cover any of this
- `~/repos/emergence-lab-gpu/state/cost-log.jsonl` — 38 real lines
- `~/repos/emergence-lab-gpu/state/logs/` — the worker and verifier logs those
  lines were parsed from, still on disk

## Deliverables

1. `stage` and `family` populated on every cost-log line. Establish why they
   are null now rather than only fixing the symptom — `role` arrives intact
   from the same call, so something specific is dropping the other two.
2. A determination on the impossible totals: real, double-counted, or
   cumulative-summed. The logs that produced them are still on disk, so this is
   answerable from evidence rather than argument. If they are inflated, say by
   roughly how much, because card 31's figures inherit it.
3. Correct rate selection per family and tier, including whatever default
   applies when family genuinely cannot be determined. A wrong rate silently
   applied is worse than a null.
4. Extend `scripts/cost-log-smoke.sh` to cover all three: a line with a null
   stage or family fails; a per-run total above a sane ceiling fails; the same
   token shape on two families produces two different costs. It must fail
   against the pre-fix commit.
5. A note in `docs/cost-log.md` on what the historical lines mean, since the
   existing ones cannot be re-derived. An analyst reading 2026-08-15 later
   needs to know those figures are suspect and why.

## Constraints

- Do not rewrite historical cost-log lines. They are the incident record.
- Do not change the cost-log schema shape in `docs/cost-log.md` beyond filling
  fields that are already specified.
- Keep the smoke offline: no API spend, no network.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. The repo's own acceptance suite is green.
2. A dispatched role writes a cost-log line carrying its stage id and family.
3. The impossible-totals question is answered with evidence from the retained
   logs, not by assertion.
4. Rate selection is correct per family, and the fallback when family is
   unknown is stated and defensible.
5. The extended smoke fails against the pre-fix commit. Check it out, run it,
   state the failure.
6. `docs/cost-log.md` warns about the historical lines.

## Contract test

- **Test file:** `scripts/cost-log-smoke.sh` (extended)
- **Assertions digest:** <<fill at dispatch>>

## Out of scope

- Budget cap enforcement — card `31-budget-cap-did-not-stop-dispatch`. The two
  are independent: over-counting would have made the cap halt *sooner*, so this
  is not 31's cause.
- The cost dashboard's presentation of these figures.
- Retrospective correction of past spend.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes

## Verifier handoff

Worker reports: why stage and family were null while role was not; the verdict
on the impossible totals with the log evidence behind it and an inflation
factor if there is one; how a rate is chosen and what happens when family is
unknown; and the smoke's failure output against the pre-fix commit.

## Family-specific notes

The parsing question spans both families — codex two-line `tokens used` and
claude `Total tokens:` — so read both formats before concluding. A defect in
one is not evidence about the other.
