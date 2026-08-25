# Stage card 41-fleet-pane-spend-columns-and-an-alerts-table: the fleet pane shows raw digits and a list of unsorted sentences, two of which are its own commit messages

## Metadata

- **Authored:** 2026-08-23
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Fable 5 <claude-fable-5@local>
- **Worker effort:** medium
- **Verifier effort:** medium
- **Verifier panel:** false
- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes
- **Pairing rationale:** presentation over data that already exists, so the
  cheaper Codex tier is right, exactly as card 38 reasoned. Defect C is the
  exception and wants care: the verifier should check the exclusion against
  real logs rather than reason about the regex.

## Objective

Card 38 built the fleet roll-up. This card makes it readable and makes its
alert list trustworthy.

Three asks, plus one small fix without which the first two are decoration.

## Reported by

Operator, reading the pane on 2026-08-23 at 15:02Z. The screenshot that
prompted this is the state of the pane at `6c06888`.

### Ask 1: per-repo spend, in numbers a person can read

The REPOS table carries `window` as a bare ratio of digits:

```
automometta            yes    running    1/1    16096027/150000000    46m
emergence-lab          yes    running    1/0    5921327/100000000     1d
```

`16096027/150000000` is a percentage nobody can compute at a glance, and the
row says nothing about money or about today. TOTALS already carries `today:
16878265 tokens / $37.205664 est`, so the per-repo figures exist and are
aggregated; they are simply not broken out per row.

Give each repo row today's tokens and today's cost estimate alongside the
window figure, and render large token counts in a human unit (`16.1M/150M`,
`5.9M/100M`). Keep the exact figures available somewhere: the point of the
short form is scanning, not hiding.

`$37.205664` is also six decimal places of an estimate against list prices.
Two is enough, and the estimate is already labelled as one.

### Ask 2: ALERTS as a table

Today the union is one sentence per line, sorted by nothing in particular:

```
ALERTS (fleet union)
  aegis-guardrails: queue empty
  automometta: 36-ship-fixes-and-recover-emergence-lab failed
  emergence-lab: 05-math-formula-rendering verifier_failed
  fractals-from-the-90s: queue empty
```

Those are three different kinds of thing sharing a shape: a repo-level
condition, a stage-level terminal status, and a provider error. Give them
columns, something along the lines of repo, stage or card, kind, detail, with
a stable sort so the pane does not reshuffle between refreshes. Kind is the
column that makes it scannable: an empty queue and a stalled stage want
different reactions from the operator.

A stage-level alert should name the stage; a repo-level one should say so
rather than leaving the column blank in a way that reads as missing data.

### Ask 3: the alert list is not trustworthy, which is worse than ugly

Three of the eleven alerts on screen are false:

```
automometta:   # Provider limit alerts (usage/rate limit, overload, exhausted credit)
automometta: 71f99a7 996d42eab40d765bc5ea681511ecfe7234cb823c fix(budget): rate-limit the halt log; keep one halt-clearing path
automometta: 71f99a7 fix(budget): rate-limit the halt log; keep one halt-clearing path
```

None is a provider error. The first is a source comment from
`scripts/aggregate-dashboard.sh:169`; the other two are card 33's commit
subject, `71f99a7 fix(budget): rate-limit the halt log`. All three reached a
worker's log because the worker was editing those very lines, and
`USAGE_LIMIT_PATTERN` matches `rate[ _-]limit` anywhere in a log.

`USAGE_LIMIT_EXCLUDE` already anticipates this class. Its comment reads: "An
agent working on the limit-handling code writes `scan-usage-limits.sh` into
its own log and would otherwise park the whole loop." That covers lines naming
the scanner's own machinery, and not lines that are the loop's commit subjects
or source. `tick.sh` learned the same lesson a second time in
`handle_limit_refusal`, which is gated on the absence of a handoff envelope
precisely because "a stage whose subject matter is rate limiting would
otherwise match the refusal pattern from its own output".

So this is the third appearance of one bug, in a third place. Fix the scan,
and consider whether the three call sites should share one judgement rather
than three regexes drifting apart.

A false provider-limit alert is not cosmetic. The same pattern parks
dispatch elsewhere in the loop, and an alert panel that cries wolf trains the
operator to skim the panel that exists to be read.

### Ask 4, small and load-bearing: nothing refreshes `data.json`

The pane's header, correctly, says:

```
FLEET DATA STALE: generated 2593s ago (limit 600s)
```

Card 38 required exactly that honesty and got it. But the aggregation runs
only when someone types `autometta dashboard`, so the default state of the
pane is stale, and every number above is 43 minutes old. Spend columns nobody
can trust the freshness of are worse than no spend columns.

Refresh it on a schedule the pane can rely on, and say plainly when it was
generated. Do not make the ticker itself walk the fleet: card 38's constraint
against a third walker still holds.

## Inputs (read these in your own context)

- `scripts/attach.sh` - `render_fleet_once` and the fleet ALERTS union, lines
  around 90 to 110.
- `scripts/aggregate-dashboard.sh` - the walker that writes `data.json`,
  including the per-repo `cost_rollup` and `alerts` fields.
- `~/.phat-controller/dashboard/data.json` - the current shape. Read it before
  changing the renderer; most of what ask 1 needs may already be in it.
- `scripts/scan-usage-limits.sh` and `scripts/usage-limit.sh` -
  `USAGE_LIMIT_PATTERN`, `USAGE_LIMIT_EXCLUDE`, and the comment explaining the
  exclusion.
- `scripts/tick.sh` - `handle_limit_refusal` and its envelope gate, the same
  lesson learned in another place.
- `scripts/agent-ticker.sh` - the per-repo SPEND panel from card 38, whose
  formatting the fleet rows should not contradict.
- `docs/cost-log.md` - the cost-log schema behind the money figures.
- `docs/dashboard.md`, `docs/observability.md`, `MANUAL.md`.
- `state/logs/*.log` in this repo, which still contain the three false
  positives. They are the fixture.

## Deliverables

- `scripts/attach.sh` - spend columns on the REPOS rows, ALERTS as a table.
- `scripts/scan-usage-limits.sh` and/or `scripts/usage-limit.sh` - the
  exclusion fix.
- `scripts/aggregate-dashboard.sh` - only if a field the renderer needs is
  missing, and for the refresh path if that is where it belongs.
- `scripts/alerts-table-smoke.sh` - new. Asserts the table renders the three
  kinds distinctly, sorts stably, and that the three known false positives in
  this repo's logs do not appear.
- `docs/dashboard.md`, `docs/observability.md`, `MANUAL.md` as required.

## Constraints

- Read-only on every repo, adopter repos included.
- No third fleet walker. Reuse `aggregate-dashboard.sh`, as card 38 required.
- The exclusion must not blind the scanner to real provider errors. Show both
  directions: a real limit line still alerts, and the known false positives do
  not. A test that only proves the false positives are gone is half a test.
- Keep the exact token figures reachable. Short units are for scanning.
- The stale banner stays. Refreshing more often is not a reason to stop saying
  when the data was generated.
- The ticker refresh budget from card 38 still applies: no full re-scan of a
  large `cost-log.jsonl` per refresh.
- British English, no em dashes.

## Acceptance criteria

1. Each REPOS row shows today's tokens and today's cost estimate as well as
   the window figure, with large counts in a human unit and money to two
   decimal places. Check one row against a hand-computed figure from that
   repo's `cost-log.jsonl`.
2. ALERTS renders as a table with a column identifying the kind of alert, a
   stage-level alert names its stage, and a repo-level one is marked as such
   rather than leaving the column empty.
3. The table's sort is stable across two consecutive renders of unchanged
   data.
4. None of the three known false positives appears in the alert list, and a
   log line carrying a genuine provider limit error still does. Demonstrate
   both against real or fixture logs, not by reading the regex.
5. `data.json` is refreshed without anyone typing `autometta dashboard`, the
   pane states when it was generated, and the stale banner still appears when
   the data genuinely is stale.
6. `scripts/alerts-table-smoke.sh` passes, and every existing offline smoke
   script still passes. `sdk-cache-smoke.sh` requires live API credentials and
   is not run: say so.

## Out of scope

- The per-repo SPEND panel from card 38, which is correct. Match its
  formatting; do not rewrite it.
- Changing what counts as an alert-worthy stage status.
- The web dashboard renderer under `dashboard/`.
- Changing budgets, caps or the halt logic.
- Consolidating the emergence-lab subscribers.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes

## Notes for the worker

- Read `data.json` before touching the renderer. Card 38 already aggregates
  `cost_rollup` per repo, so ask 1 may be renderer-only.
- On ask 3, resist widening `USAGE_LIMIT_EXCLUDE` with one more literal. That
  is how it got here: each fix excluded the last specific string that fooled
  it. Ask what distinguishes a provider's error from a log that merely
  discusses one, and note that the loop already answers this in `tick.sh` by
  gating on the handoff envelope rather than on the text.
- Criterion 6 excludes `sdk-cache-smoke.sh` deliberately: it needs
  `ANTHROPIC_API_KEY` and this repo bills on the subscription route. Card 39
  burned a verifier attempt on that wording before it was fixed.
