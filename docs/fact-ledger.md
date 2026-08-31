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
`scripts/facts-lint.sh` is the gate. Nothing writes to the ledger yet.

A fact earns its line when a later stage should be constrained by it. A
lesson learned in stage 12 that nothing can query does not reach stage 40.

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
