# Stage card 02: Fractals stage cards as examples

## Metadata

- **Authored:** 2026-05-21
- **Orchestrator:** Claude Opus 4.7 (main session)
- **Worker:** Claude Sonnet 4.6 (Task sub-agent)
- **Verifier:** Codex GPT-5.3 (`codex exec --sandbox read-only`)
- **Pairing rationale:** Rotates back to the stage-0 direction (Claude worker, Codex verifier) to keep both directions exercised. Stage 1 ran the reverse; alternation is the default.

## Objective

Populate `examples/fractals-stage-cards/` with a curated subset of real stage cards from the `fractals-from-the-90s` source project, plus a README that explains what each card illustrates and why these specific cards were chosen. The cards are committed verbatim as historical artefacts; they predate the autometta template and are not expected to conform to it.

## Inputs (read these in your own context)

- `<fractals-repo-root>/docs/stages/README.md`
- `<fractals-repo-root>/docs/stages/STAGE-TEMPLATE.md`
- `<fractals-repo-root>/docs/agents/WORKER-PROMPT-TEMPLATE.md`
- `docs/dispatch-contract.md`
- `templates/stage-card.md`

After reading the README in `fractals-from-the-90s/docs/stages/`, scan the directory listing (you can use `ls` or `Glob`) but only fully read the four cards you select for copying. Do not read all 25.

## Deliverables

All paths relative to repo root.

1. Four card files copied verbatim into `examples/fractals-stage-cards/` from the source project. Choose representatively:
   - One **K-series** card (kernel / architect work).
   - One **U-series** card (UI / coder work).
   - One **I-series** card (integration / cross-cutting work).
   - One **U-FIX or recovery card** (illustrates a stage that emerged from a prior-stage regression, since that is gotcha #5 in `docs/lessons.md`). The card filenames inside `examples/fractals-stage-cards/` should match their source names so that future readers can grep them against the source project. Do not rename.
2. `examples/fractals-stage-cards/STAGE-TEMPLATE.md`: copy verbatim from `<fractals-repo-root>/docs/stages/STAGE-TEMPLATE.md` so readers can compare the original template against the autometta one.
3. `examples/fractals-stage-cards/WORKER-PROMPT-TEMPLATE.md`: copy verbatim from `<fractals-repo-root>/docs/agents/WORKER-PROMPT-TEMPLATE.md`.
4. `examples/fractals-stage-cards/README.md`: written fresh. State: (a) the cards are imported verbatim as historical artefacts and predate the autometta templates, (b) which four cards you chose and why each was chosen, (c) what each card illustrates about the dispatch contract (cross-reference `docs/lessons.md` and `docs/dispatch-contract.md` by section name), (d) where in the source project they originally lived (one-line `source:` line per card).

## Constraints

- **Verbatim cards:** the four chosen cards plus the two source templates are copied byte-for-byte. Do not edit them for style, paths, or any other reason. They are artefacts.
- **Style audit applies to `examples/fractals-stage-cards/README.md` only**, since that is the only file you author. British English. No em dashes. No `delve|leverage|seamless|robust|comprehensive|tapestry|elegant` (case-insensitive).
- **No phantom artefacts in the README:** the README must not reference `state.yaml`, `tick.sh`, `phat-controller`, `budget.sh`, `schemas/` as currently existing.
- **No fabrication:** if a card you read mentions a person, an external project, or a specific commit hash that you cannot independently verify from the inputs, do not editorialise about it in the README.
- **Stay inside scope:** do not modify any file outside `examples/fractals-stage-cards/`. Do not read more source cards than you copy plus a quick scan of the source `docs/stages/README.md` for selection guidance.

## Acceptance criteria

1. The directory `examples/fractals-stage-cards/` exists and contains exactly seven files: four cards, `STAGE-TEMPLATE.md`, `WORKER-PROMPT-TEMPLATE.md`, plus a `README.md`.
2. Each of the four imported cards is byte-identical to its source counterpart (`diff -q` returns empty).
3. The two imported templates are byte-identical to their source counterparts.
4. `examples/fractals-stage-cards/README.md` names each of the four chosen cards explicitly, states which series each belongs to (K / U / I / U-FIX), gives a one-sentence rationale per choice, and lists what each illustrates about the dispatch contract with at least one cross-reference to `docs/lessons.md` or `docs/dispatch-contract.md` by section name.
5. Style audit on `README.md`: `grep -c '-' examples/fractals-stage-cards/README.md` returns 0; banned-vocabulary scan returns no matches.
6. No phantom artefacts in `README.md`.
7. No files outside `examples/fractals-stage-cards/` are modified by the worker. The stage card itself at `examples/self-host/02-fractals-examples.md` is authored by the orchestrator and committed alongside as the audit trail per dispatch-contract step 7; it is not in the worker's scope and is exempt from this criterion.

## Out of scope

- Editing the copied artefacts.
- Reading all 25 source cards.
- Pass-2 design.
- Any file under `templates/`, `docs/`, `memory/`, `scripts/`, `state/`, `schemas/`, `skills/`.

## Budget

- **Worker wall-clock:** 5 minutes. The task is mechanical copy + a short README.
- **Verifier wall-clock:** 5 minutes.

## Verifier handoff

When done, return a short paragraph naming the four cards chosen, the directory contents, and the acceptance criteria the worker believes satisfied. The orchestrator will run a `diff -q` check on each imported file against its source before dispatching the Codex verifier.

## Family-specific notes

Worker uses the Task tool with model `sonnet`. Use `Read` to view source files and `Write` to create copies in the autometta repo (Write into a path is equivalent to copy when the source content is read first; do not invoke shell `cp` since the Task sub-agent's working directory is the autometta repo, not the fractals repo).
