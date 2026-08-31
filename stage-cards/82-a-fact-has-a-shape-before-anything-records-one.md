# Stage card 82: a fact has a shape before anything records one

## Metadata

- **Authored:** 2026-08-31
- **Orchestrator:** Claude Fable 5 <claude-fable-5@local>
- **Worker:** Claude Opus 5 <claude-opus-5@local>
- **Verifier:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Base branch:** dev
- **Run branch:** autometta/82-a-fact-has-a-shape-before-anything-records-one
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** schemas/fact-ledger.json, scripts/facts-lint.sh, docs/fact-ledger.md
- **Pairing rationale:** the deliverable is a contract, not a script, so the
  stronger Claude tier authors it and the other family checks that the schema
  and the prose agree with each other and with the graph engineering doc.

## Objective

`docs/graph-engineering.md` names the repo's gap: the commit DAG records what
changed, but nothing records what is true in a shape a script or a verifier
can query. `memory/` is prose with untyped links; `state/cost-log.jsonl`
records spend only.

Define the fact ledger before anything writes to it: a committed, append-only
JSONL file of typed triples at `memory/facts.jsonl`, a JSON schema for one
line of it, a lint script that validates a ledger file against the schema,
and the contract doc that says what belongs in the ledger and what does not.
This card ships the shape and the gate; no production code writes a fact yet.

## Inputs (read these in your own context)

- docs/graph-engineering.md
- memory/README.md
- schemas/handoff-envelope.json
- schemas/state.yaml.json
- docs/cost-log.md

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `schemas/fact-ledger.json`: JSON schema for a single ledger line. Required
   fields: `subject`, `predicate`, `object`, `source` (a commit SHA or a
   repo-relative doc path), `agent` (canonical identity string), `recorded_at`
   (ISO 8601 date). Optional: `stage_id`, `run_id`, `confidence`
   (`high|medium|low`, default high). The `predicate` field is an enum, not a
   free string.
2. `docs/fact-ledger.md`, at most 600 words: what the ledger is for, the
   closed predicate vocabulary with one example each, the append-only rule
   (correction is a new fact carrying the `supersedes` predicate, never an
   edit), what belongs in `memory/` prose instead, and how the vocabulary is
   extended (a schema change plus a doc change in one commit, never an ad hoc
   string).
3. `scripts/facts-lint.sh`: validates a given JSONL file line by line against
   the schema using only tools already on the machine (python3 and the
   standard library; no new dependencies). Exits non-zero naming the first bad
   line and why. Exits 0 on an empty or absent file when passed `--allow-missing`.
4. The starting predicate vocabulary, encoded in the schema enum and the doc
   together. Start from: `measured`, `verified-by`, `failed-criterion`,
   `supersedes`, `caused-by`, `fixed-by`, `depends-on`, `refutes`. The worker
   may argue any of these out or in; the schema and the doc must agree
   exactly.

## Constraints

- Do not create `memory/facts.jsonl` and do not modify `scripts/tick.sh`,
  `memory/README.md`, or any spawn script. Later cards do the writing.
- No new runtime dependencies: python3 stdlib only in the lint. The full
  jsonschema library is not on the machine; hand-roll the small validator this
  schema needs.
- British English, no em dashes, no AI-tell vocabulary in the doc.

## Acceptance criteria

1. `bash -n scripts/facts-lint.sh` passes.
2. A fixture line exercising every required and optional field validates:
   `printf '%s\n' '<good line>' > /tmp/facts-good.jsonl && bash scripts/facts-lint.sh /tmp/facts-good.jsonl` exits 0.
3. Each of these is rejected with a message naming the line and the reason:
   a missing required field, a predicate outside the enum, a `confidence`
   outside the enum, and a line that is not valid JSON.
4. `bash scripts/facts-lint.sh --allow-missing memory/facts.jsonl` exits 0 on
   this tree, where the file does not exist.
5. The predicate enum in `schemas/fact-ledger.json` and the vocabulary listed
   in `docs/fact-ledger.md` are identical sets.
6. `docs/fact-ledger.md` is at most 600 words and `grep -c '—' docs/fact-ledger.md` returns 0.
7. `git diff --stat` on the run branch touches only the three claimed paths.

## Contract test

- **Test file:** None
- **Assertions digest:** None

## Out of scope

- Writing any fact anywhere. The ledger file itself belongs to card 83.
- Entity resolution, aliases, and graph traversal tooling.
- Changing `memory/README.md` or the memory index conventions.

## Budget

- **Worker wall-clock:** 2400s
- **Verifier wall-clock:** 1800s

## Verifier handoff

Leave the working tree dirty. Report the lint output for the good fixture and
each rejection fixture, the word count of the doc, and the predicate sets from
schema and doc side by side.

## Family-specific notes

None
