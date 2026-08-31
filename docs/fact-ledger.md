# Fact ledger

The commit DAG records what changed. Nothing in this repo records what is
true in a shape a script can query: `memory/` is prose with untyped
`[[wikilinks]]`, and `state/cost-log.jsonl` records spend only. See
`docs/graph-engineering.md` for the assessment behind that gap.

The fact ledger is the second graph. It lives at `memory/facts.jsonl`,
committed, one JSON object per line, each a typed triple with provenance:
`subject`, `predicate`, `object`, plus `source`, `agent` and `recorded_at`.
Optional `stage_id`, `run_id` and `confidence` say which dispatch observed it
and how much weight it carries. `schemas/fact-ledger.json` is the shape and
`scripts/facts-lint.sh` is the gate.

A fact earns its line when a later stage should be constrained by it. A
lesson learned in stage 12 that nothing can query does not reach stage 40.

## Who writes

`scripts/tick.sh` is the only automated writer, and it writes at exactly two
moments. On a verifier PASS it records a `verified-by` line naming the
verifier that cleared the stage, and, when the card or the commit subject
names an earlier stage this one repairs, a `fixed-by` or `supersedes` line
for that. On a verifier FAIL it records a `failed-criterion` line citing the
verifier envelope. Nothing else in the loop appends, and no worker should:
a worker writes deliverables, and the ledger is a statement about work that
has already been judged.

The tick reads a repair relation from a card metadata line when the card
declares one,

```
- **Fixes:** 30-effort-flags-ifs-wordsplit
- **Supersedes:** 43-alert-worthy-status
```

and otherwise from the objective or the commit subject, where the stage id
has to follow the verb directly ("fixes 30-effort-flags-ifs-wordsplit").
Cards say "card 37 fixes two panels" all the time, so a looser match would
manufacture edges nobody asserted, and a ledger line is permanent. A
declared metadata line is recorded at `high` confidence, a match read out of
prose at `medium`.

Facts recorded by the tick carry `phat-controller <phat-controller@local>`
as their `agent`. The loop recorded them, not the model behind any one
dispatch; the worker and the verifier are named in the fact itself.

### Never block a landing

A ledger write must never change a landing or a state transition. Two things
enforce that rather than a promise to be careful.

Every line goes through `scripts/facts-lint.sh` against a temp file before
the ledger is opened, so the gate on the committed ledger is the gate on the
write. A rejected line warns to the controller log and is dropped; the stage
lands regardless, and the ledger is untouched.

A PASS is written into the run worktree after the worker diff is staged and
before the commit, so the facts land in the same commit as the work. A FAIL
has no commit to ride, so its fact is spooled to `state/facts-pending.jsonl`,
captured by the state commit the same tick makes, and drained into the ledger
by the next landing. The spool is cleared only once that landing commit
exists. Appending straight into the operator checkout would leave a dirty
tracked `memory/facts.jsonl`, and the next fast-forward merge of a run branch
refuses to overwrite one: every later landing would drop to `awaiting`
manual integration. That is a ledger write costing a landing, which is the
one outcome this design does not allow.

## Vocabulary

The `predicate` field is a closed enum of eight. Subjects and objects are
plain strings, but use the identifiers the rest of the repo already uses:
stage ids, commit SHAs, repo-relative paths, gotcha labels, agent identity
strings. A measurement is written as `name=value`.

| Predicate | Reads as | Example subject and object |
| --- | --- | --- |
| `measured` | an observed number | `73-verifier-panel-quorum` / `verifier_wall_clock_s=412` |
| `verified-by` | who cleared it | `82-fact-ledger` / `Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>` |
| `failed-criterion` | which gate rejected it | `64-tui-messages` / `acceptance-3: lint accepted a bad line` |
| `caused-by` | the mechanism behind a failure | `stage-58-worker-death` / `gotcha-9: SIGHUP from the tick` |
| `fixed-by` | what closed it | `gotcha-12` / `commit 4f2ab1c` |
| `depends-on` | ordering that outlives one run | `83-facts-backfill` / `82-fact-ledger` |
| `supersedes` | a correction, see below | `73-verifier-panel-quorum` / `a109131` |
| `refutes` | evidence against a stated belief | `docs/lessons.md#gotcha-19` / `claim: codex --oss runs any pulled model` |

`supersedes` retires a line; `refutes` contradicts a claim without replacing
it, which is why both exist.

## Append-only

The ledger is never edited and never reordered. A wrong fact is corrected by
appending two lines: the replacement fact, then a `supersedes` line carrying
the same `subject`, whose `object` is the `source` of the line being retired
and whose own `source` is the commit making the correction. A reader
gathering facts about a subject drops any line whose `source` is named that
way. Editing in place would break every `source` a reader has already cited,
and the diff would hide the correction rather than record it.

## What stays in prose

`memory/` keeps the reasoning: decisions and the arguments for them, open
questions, coordination notes, anything whose value is the paragraph rather
than the edge. The ledger keeps assertions a script can act on. If a fact
needs a caveat to be true, the caveat belongs in `memory/` and the fact
should probably not be recorded. Neither replaces the other, and `memory/`
conventions are unchanged by this document.

## Extending the vocabulary

A new predicate is a schema change and a doc change in one commit: add it to
the enum in `schemas/fact-ledger.json` and add its row to the table above.
The lint rejects anything else, which is the point. A free string would let
each agent invent its own edge type and leave the ledger unqueryable within a
handful of runs. Argue the predicate first, in `memory/` or a stage card,
then land both edits together.
