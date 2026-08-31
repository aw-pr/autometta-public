# Stage card 84: a landing leaves a fact behind

## Metadata

- **Authored:** 2026-08-31
- **Orchestrator:** Claude Fable 5 <claude-fable-5@local>
- **Worker:** Claude Opus 5 <claude-opus-5@local>
- **Verifier:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Base branch:** dev
- **Run branch:** autometta/84-a-landing-leaves-a-fact-behind
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Gate:** stage-completed: 83-the-trailers-already-knew-the-facts
- **Pairing rationale:** `tick.sh` is load-bearing and the failure modes are
  subtle (gotchas 9, 10, 12), so the stronger Claude tier does the surgery and
  the codex verifier runs the mechanical evidence from outside the sandbox.

## Objective

Make the loop remember what it learned without being asked. When the tick
lands a stage (verifier PASS, commit created), it appends facts to
`memory/facts.jsonl` in the same commit as the landing: who verified the
stage, and what earlier stage it fixed or superseded when the card or commit
subject names one. When a verifier FAILs, the tick appends a
`failed-criterion` fact citing the verifier envelope, committed with the
next state commit.

The ledger write must never take a landing down with it. The state file
destruction in gotcha 10 came from a helper doing more than its caller
expected; this card's failure budget is the opposite: on any ledger error,
warn to the controller log and land anyway.

## Inputs (read these in your own context)

- scripts/tick.sh
- schemas/fact-ledger.json
- docs/fact-ledger.md
- scripts/facts-lint.sh
- docs/lessons.md (gotchas 9, 10 and 12 only)

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. A `facts_append` helper (in `scripts/lib/` if one exists for such helpers,
   otherwise within `scripts/tick.sh`) that takes one JSON line, validates it
   with `scripts/facts-lint.sh` against a temp file, appends on pass, and
   returns non-zero with a controller-log warning on fail without touching the
   ledger.
2. The landing path in `scripts/tick.sh` emits the PASS facts described above;
   the verifier-FAIL path emits the `failed-criterion` fact.
3. `docs/fact-ledger.md` gains a short "who writes" section naming the tick as
   the only automated writer and the never-block-a-landing rule.

## Constraints

- A ledger failure must never change a tick's landing or state transition.
  The evidence is a forced-failure test, not an assertion in prose.
- No new fields and no new predicates: card 82's schema is the contract. If a
  fact does not fit, it is not written.
- Do not touch the budget accounting, the dispatch paths, or the state
  read/write guards in `state_apply_json`.
- Multi-token argument lists travel in bash arrays, expanded quoted (gotcha
  12).

## Acceptance criteria

1. `bash -n scripts/tick.sh` passes, plus `bash -n` on any new lib file.
2. A dry-run tick against a fixture state landing a fake stage appends facts
   that pass `scripts/facts-lint.sh`, and the facts land in the same commit as
   the landing (`git show --stat` names both the landed files and
   `memory/facts.jsonl`).
3. With `scripts/facts-lint.sh` replaced by a stub that always fails, the same
   fixture landing still completes, the state transition is identical, and the
   controller log carries the warning.
4. A fixture verifier FAIL produces a `failed-criterion` fact citing the
   verifier envelope path or commit as `source`.
5. `bash scripts/facts-lint.sh memory/facts.jsonl` exits 0 after all fixture
   runs.
6. No diff outside `scripts/tick.sh`, `scripts/lib/`, `docs/fact-ledger.md`,
   and `memory/facts.jsonl`.

## Contract test

- **Test file:** None
- **Assertions digest:** None

## Out of scope

- Reading the ledger anywhere (card 85).
- Facts about spend: `state/cost-log.jsonl` already owns that and stays the
  single source for it.
- Backfilling or rewriting any existing ledger line.

## Budget

- **Worker wall-clock:** 3000s
- **Verifier wall-clock:** 2400s

## Verifier handoff

Leave the working tree dirty. Report the fixture tick transcripts for the
PASS, FAIL and forced-ledger-failure cases, and the resulting ledger tail.

## Family-specific notes

None
