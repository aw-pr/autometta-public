# Stage card 156: the template asks what the card has not decided

## Metadata

- **Authored:** 2026-10-12
- **Orchestrator:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Worker:** Claude Sonnet 5.5 <claude-sonnet-5-5@local>
- **Verifier:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Base branch:** dev
- **Run branch:** autometta/156-the-template-asks-what-the-card-has-not-decided
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** templates/stage-card.md, templates/orchestrator-checklist.md, docs/dispatch-contract.md
- **Pairing rationale:** a prose and template change, written by Sonnet;
  Terra verifies to the letter, offline. The worker family alternates with
  155's and 157's Codex workers.
- **Open decisions:** none

## Surfacing concern

Over 123 loop-dispatched cards, 55 per cent of failed attempts with a
known, non-infrastructure cause traced to the card or the template rather
than the worker (2026-10-12 analysis, state-branch replay). The classes,
in order: a criterion the judging seat cannot satisfy or that was already
red on the base, missing harness context, an undecided design question,
wrong path claims, a wrong or toothless oracle. The checks that catch
them exist only by convention: 66 cards carry a `## Surfacing concern`
section the template does not have, 13 carry a spend basis, and no card,
template or doc has an "open decisions" field.

The run that authored this card also found a defect in the template
itself, by running the baseline step this card adds. Fill every
placeholder in `templates/stage-card.md` and queue the result:
`scripts/add-stage.sh` refuses it with "refusing dependency card with
Gate metadata; Depends on replaces legacy gates", because the examples
inside the template's HTML comments start at column 0 with `- **`, and
`add-stage.sh` reads them as the card's own `Gate` and `Depends on` lines.

A read-only Codex GPT-5.6 Sol cold read of this batch on 2026-10-12
raised 22 items across the three cards; each is answered in the card text.

## Objective

A card made from the template asks for the decisions, seats, baseline,
oracle proof and spend basis that catch card defects before dispatch, and
a card made by filling it in queues.

## Inputs (read these in your own context)

- `scripts/card-template-fields-smoke.sh`: the frozen contract; read it first.
- `templates/stage-card.md`
- `templates/orchestrator-checklist.md`, sections 1 and 2.
- `docs/dispatch-contract.md`, section "Contract tests", subsection
  "Separation of powers".
- `scripts/card-template-smoke.sh`: card 131's assertions on the same
  template, which must still hold.
- `scripts/add-stage.sh`, to see why the comment examples are parsed (read,
  do not edit).

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `templates/stage-card.md`:
   - A metadata line `- **Open decisions:** <<none-or-numbered-open-questions>>`
     after `Pairing rationale`, and a comment saying a card is not queued
     until it reads `none`, that each answer is written into the card
     section it belongs to rather than left in chat, and that
     `scripts/card-lint.sh --strict` (card 157) enforces it.
     `scripts/add-stage.sh` does not read the line, which is why the
     smoke's filled-in card queues with it unanswered.
   - A `## Surfacing concern` section between Metadata and Objective, with
     the placeholder `<<why-this-card-exists-and-the-evidence>>` (commit,
     file:line, incident).
   - In Acceptance criteria, a comment containing the exact phrase "names
     the seat that judges it and the command that produces its evidence",
     saying each criterion does so and that every acceptance command has
     been run once on the clean base, with its result recorded beside the
     criterion.
   - In Contract test, `- **Oracle proof:** <<fails-today-at-and-reference-result>>`
     and a comment: which assertion fails today on the base and why, and
     that a throwaway reference passed every assertion, or why that step
     was skipped.
   - In Budget, `- **Spend basis:** <<spend-basis>>`.
   - The examples inside the template's HTML comments (`Gate`, `Depends
     on`, `Path claims`, `Dispatch`) are indented by four spaces so that no
     comment line starts with `- **`; their text is otherwise unchanged.
   - Every existing heading and placeholder is kept.
2. `templates/orchestrator-checklist.md`: five items, each a checkbox that
   begins with its bold label exactly as written here. In section 1:
   `- [ ] **Open decisions.**` (the card's line reads none; answers live in
   the card) and `- [ ] **Claims closure.**` (for every symbol, field or
   rule the card changes, grep its consumers and read them; each file the
   worker must touch is a Deliverable inside Path claims). In section 2:
   `- [ ] **Seat and command.**` (each criterion names the seat that judges
   it and the command; confirm that seat can run it: network, GUI, writes
   outside the worktree, waiting on a background batch),
   `- [ ] **Baseline run.**` (run every acceptance command on the clean
   base and record red or green; a criterion already red on the base, or
   one that forbids what the tool does by design, is a card defect) and
   `- [ ] **Oracle proof.**` (the contract test fails today at a named
   assertion and passed a throwaway reference built in a detached scratch
   worktree that is then removed; both go on the card's Oracle proof line).
3. `docs/dispatch-contract.md`: in "Separation of powers", the orchestrator
   bullet also says that before queueing the orchestrator proves the block
   red on the base and green against a throwaway reference, and records
   that on the card's `Oracle proof` line.

## Constraints

- The frozen block in `scripts/card-template-fields-smoke.sh` is read-only.
- `scripts/add-stage.sh` is not edited; the fix for the comment examples
  lives in the template.
- Section headings in the template are load-bearing: rename none.
- British English, no em dashes (U+2014), no AI-tell vocabulary.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of
the stage. Each criterion names the seat that judges it and the command
that produces its evidence; the verifier runs every command itself, in the
run worktree, offline.

1. Verifier: `bash scripts/card-template-fields-smoke.sh` prints PASS and
   exits 0, and `scripts/check-contract-test-gate.sh print
   scripts/card-template-fields-smoke.sh` prints the digest recorded below.
2. Verifier: `bash scripts/card-template-smoke.sh` prints PASS.
3. Verifier: `bash scripts/dependency-graph-smoke.sh` fails no test other
   than `test_queue_parsing_and_schema`. That one test errors on the clean
   base too, with "No module named 'jsonschema'", because the module is not
   installed on this machine; the baseline run before queueing recorded
   it. Judge this criterion on the set of failing tests being unchanged,
   not on the smoke's exit code.
4. Verifier: `git diff templates/stage-card.md` removes no `<<...>>`
   placeholder and renames no heading; the only changed lines inside HTML
   comments are the four-space indents and the new comments.
5. Verifier: `git diff -U0` shows no added line containing an em dash, and
   `git status --porcelain` in the run worktree lists only the claimed
   paths, apart from the card itself and `state/`.
6. Verifier: reading the three diffs, the Open decisions and Claims closure
   items sit in checklist section 1 and the other three in section 2, each
   with the content Deliverable 2 gives it; the Separation of powers
   sentence states red on the base and green against a throwaway
   reference; and the template's new comments say what Deliverable 1
   says. The smoke checks only that the labels and phrases exist.

## Contract test

- **Test file:** scripts/card-template-fields-smoke.sh
- **Assertions digest:** `sha256:ff7c35b8253e1e6fd63a008ef9f106f492cb1582929b252bf1cd1043fb09fbaf`
- **Oracle proof:** fails today at its first assertion, because the
  template has no Open decisions line; its last assertion (a card filled
  from the template queues) is also red on the base, for the comment
  examples reason above. A throwaway edit of the three files in a detached
  scratch worktree, then removed, passed every assertion, and
  `scripts/card-template-smoke.sh` still passed beside it.

## Out of scope

- `scripts/add-stage.sh`, `scripts/card-lint.sh` (card 157) and every skill.
- Existing stage cards: no card is rewritten to the new template.

## Budget

- **Worker wall-clock:** 25 minutes (kill at 40)
- **Verifier wall-clock:** 20 minutes
- **Spend basis:** `state/cost-log.jsonl` on 2026-10-12: worker median
  1.1M tokens, verifier median 1.2M. Plan 3M for the stage.

## Dispatch envelope

Write `state/envelopes/156-the-template-asks-what-the-card-has-not-decided.json`
using `schemas/envelope.json`. List changed deliverables, the exact smoke
commands and their results, and any criterion you could not satisfy with
why. If the card itself is wrong, stop with `status: fail` and say so in
`notes` rather than working round it. Do not self-verify or land your own
branch. The verifier writes
`state/verifiers/156-the-template-asks-what-the-card-has-not-decided.json`
under the existing verifier contract, giving a criterion-by-criterion
verdict.

## Family-specific notes

Codex verifier: workspace-write is enough; the smokes are offline and
build their fixtures under `mktemp -d`.
