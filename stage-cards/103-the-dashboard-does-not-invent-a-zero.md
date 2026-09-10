# Stage card 103: the dashboard does not invent a zero

## Metadata

- **Authored:** 2026-09-01
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Codex GPT-5.6 Sol <codex-gpt-5-6-sol@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Base branch:** dev
- **Run branch:** autometta/103-the-dashboard-does-not-invent-a-zero
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/aggregate-dashboard.sh, scripts/dashboard-fail-closed-smoke.sh, docs/dashboard.md
- **Pairing rationale:** cross-family. The deliverable is that a failure
  becomes visible, and the verifier's job is to break the query on purpose and
  confirm the surface says so -- work best given to a seat that did not write
  the error path.
- **Type:** Fail-closed correction on a reporting surface.

## Surfacing concern

`scripts/aggregate-dashboard.sh:681` ends the spend query with:

```sh
' "$cost_log_path" 2>/dev/null || printf '%s' "$spend")"
```

`$spend` is the all-zeros default declared at line 538. So any failure of that
jq program -- a syntax error, a malformed row in `cost-log.jsonl`, jq missing
from `PATH` -- is written to `/dev/null` and replaced with a well-formed
object reading zero tokens, zero cost, zero history cards, empty fortnight.

Every consumer then renders that as fact. The TUI history tab shows "0 cards",
the web dashboard shows no spend, and nothing anywhere reports an error. The
handoff records that this "nearly shipped today": a jq syntax error returned
*no history at all*, silently, rather than erroring.

This is the same failure class as the three instruments already fixed on
2026-09-01 -- the dashboard replaying a stale snapshot against a dead server,
the re-queue reporting a previous attempt's spend, adjudicated work counted as
lost. Each reported healthy while being wrong, and each was found by
disbelieving the surface rather than by anything failing.

A zero that means "no spend" and a zero that means "the query died" must not
look the same.

## Objective

Make the failure visible. A query that cannot run must produce a payload that
says so, and every surface that renders the payload must show it rather than
render zeros.

## Inputs (read these in your own context)

- `scripts/aggregate-dashboard.sh`, line 538 (the default) and line 681 (the
  swallow), plus any other `|| printf`/`|| true` on a data path in that file
- `scripts/lib/tui/render.py`, how the history panel and the status panel read
  the payload
- `docs/dashboard.md`
- The `state_error` field already in the payload, which is the existing
  precedent for "this section could not be read" -- follow it rather than
  invent a second convention

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. The spend query fails closed: on failure the payload carries an explicit
   error marker, not a zeroed object. Reuse the `state_error` pattern.
2. Every other silent data-path fallback in that script audited. Fix the ones
   that hide a failure; leave the ones that are genuine "absent is fine"
   cases, such as a repo with no cost log yet, and say in the handoff which
   were which and why. **Absent and broken are different**, and only the
   second is a defect.
3. The TUI renders the marker on the history panel and anywhere else the
   spend figures appear, so a reader sees "spend unavailable" rather than a
   confident zero.
4. `scripts/dashboard-fail-closed-smoke.sh`: breaks the query on purpose and
   asserts the marker appears and the zeros do not.
5. A line in `docs/dashboard.md` stating the rule: a reporting surface says
   when it cannot answer.

## Constraints

- **A repo with no `cost-log.jsonl` is not an error.** It has genuinely spent
  nothing, and zeros are the right answer. Only a query that *fails* is the
  error. Getting this distinction wrong would alarm every fresh subscriber.
- Do not change any figure that is currently correct.
- The payload stays valid JSON on every path; consumers must not have to
  guard against a missing key.
- No new dependency.

## Acceptance criteria

1. With a deliberately broken jq program, the payload carries the error marker
   and does **not** carry zeroed spend presented as fact.
2. With a malformed row in `cost-log.jsonl`, same.
3. With no `cost-log.jsonl` at all, the payload reads zero spend with **no**
   error marker, because that is true.
4. The TUI shows the marker in case 1, demonstrated from a real capture, not
   from the payload alone.
5. `scripts/dashboard-fail-closed-smoke.sh` passes and fails against the
   pre-change script. Record both runs.
6. `scripts/tui-smoke.sh`, `scripts/tui-history-smoke.sh` and
   `scripts/dashboard-liveness-smoke.sh` are no more red than they are today.
   `tui-history-smoke.sh` is **already red on a clean `dev`** and is not this
   card's to fix; do not let it mask a regression you caused, and say in the
   handoff whether its failure message changed.

## Contract test

- **Test file:** scripts/dashboard-fail-closed-smoke.sh
- **Assertions digest:** a broken query and a malformed row each surface an
  error marker; an absent cost log surfaces zeros with no marker; the TUI
  renders the marker.

## Out of scope

- The two definitions of "tokens" in the aggregator (repo-level sums
  `input+cached+output`, a history card reads `total_tokens`). Real, recorded,
  and its own card.
- Fixing `tui-history-smoke.sh`.
- The web dashboard's own liveness handling, fixed on 2026-09-01.

## Budget

- **Worker wall-clock:** 75 minutes
- **Verifier wall-clock:** 30 minutes

## Escalation

If making the query fail closed turns out to break a consumer that assumes the
spend object is always fully populated, record which consumer and stop. Half a
fail-closed change is worse than none: a payload that some surfaces understand
and others render as a crash is a third state nobody designed.

## Verifier handoff

Break it yourself. Corrupt the jq program, corrupt a row, remove the cost log,
and check the payload and the rendered TUI in each case -- three states, and
the third must stay quiet.

Two things to disbelieve. First, that the error path was tested at all: run
the pre-change script with a broken query and confirm it really does emit
confident zeros, so you know the smoke has something to catch. Second, that
the "absent is fine" cases were not swept into the error path along with the
broken ones; a fresh subscriber with no cost log must show no alarm, and the
easy over-correction here is to mark everything.
