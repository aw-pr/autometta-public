# Stage card 83: the trailers already knew the facts

## Metadata

- **Authored:** 2026-08-31
- **Orchestrator:** Claude Fable 5 <claude-fable-5@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Base branch:** dev
- **Run branch:** autometta/83-the-trailers-already-knew-the-facts
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Gate:** stage-completed: 82-a-fact-has-a-shape-before-anything-records-one
- **Path claims:** scripts/facts-backfill.sh, memory/facts.jsonl
- **Pairing rationale:** mechanical extraction over a fixed history suits the
  codex workhorse tier; the Claude verifier samples the emitted facts against
  the commits they cite, which is a reading job, not a writing one.

## Objective

The repo's history already carries typed provenance nothing can query: every
landed stage has `Autometta-Orchestrator`, `Autometta-Worker` and
`Autometta-Verifier` trailers, and `state/handoffs/` plus `docs/lessons.md`
record verdicts and causes in prose. Backfill the fact ledger from what the
commit DAG already knows, so the first real query has a corpus and card 82's
schema meets real data before the tick starts writing.

## Inputs (read these in your own context)

- schemas/fact-ledger.json
- docs/fact-ledger.md
- scripts/facts-lint.sh
- docs/dispatch-contract.md (step 7, the trailer block)

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/facts-backfill.sh`: walks `git log` on the current branch for
   commits carrying `Autometta-*` trailers and emits one fact per role per
   stage into `memory/facts.jsonl`: the stage as subject, `verified-by` for
   the verifier identity, and `fixed-by` where a commit subject marks a
   re-brief or fix of a named earlier stage. Every emitted fact cites the
   commit SHA as `source`. The script is idempotent: re-running it emits no
   duplicate lines (dedupe on the full line).
2. `memory/facts.jsonl`: the committed output of one run on this repo, passing
   `scripts/facts-lint.sh`.

## Constraints

- Facts come only from what a cited commit actually says. No inference beyond
  trailer fields and commit subjects; anything needing judgement is skipped,
  not guessed. A skipped commit is not an error.
- Do not modify the schema, the lint, `scripts/tick.sh`, or anything under
  `state/`.
- The script reads git history only; no network, no tokens.
- Append-only discipline from `docs/fact-ledger.md` applies from the first
  line.

## Acceptance criteria

1. `bash -n scripts/facts-backfill.sh` passes.
2. `bash scripts/facts-lint.sh memory/facts.jsonl` exits 0.
3. Running `scripts/facts-backfill.sh` twice leaves `memory/facts.jsonl`
   unchanged the second time (`git diff --exit-code memory/facts.jsonl`).
4. Ten facts sampled at random by the verifier each cite a commit whose
   trailers or subject state what the fact claims.
5. Every stage id appearing in `git log --format='%(trailers:key=Autometta-Worker,valueonly)'`-bearing
   commits appears as a subject at least once in the ledger.
6. `git diff --stat` on the run branch touches only the two claimed paths.

## Contract test

- **Test file:** None
- **Assertions digest:** None

## Out of scope

- Facts from prose sources (`docs/lessons.md`, `memory/*.md`): judgement calls
  belong to a human or a later judgement-tier card, not this extraction.
- Any change to how future commits are written.

## Budget

- **Worker wall-clock:** 2400s
- **Verifier wall-clock:** 1800s

## Verifier handoff

Leave the working tree dirty. Report the ledger line count, the lint result,
and the ten sampled facts with the commit evidence for each.

## Family-specific notes

None
