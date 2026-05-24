# Stage card 00: Bootstrap dispatch contract templates

## Metadata

- **Authored:** 2026-05-21
- **Orchestrator:** Claude Opus 4.7 (main session)
- **Worker:** Claude Sonnet 4.6 (Task sub-agent)
- **Verifier:** Codex GPT-5.3 (`codex exec --sandbox read-only`)
- **Pairing rationale:** Cross-family verification from day one. Stage 0 is also the first card and is necessarily hand-written, since the template it produces does not yet exist.

## Objective

Produce the four dispatch-contract artefacts that the rest of this self-host plan depends on. The templates this stage produces will be used by every subsequent stage in autometta's own build-out, including this self-host plan from stage 1 onwards.

## Inputs (read these in your own context)

- `README.md`
- `CLAUDE.md` (canonical; `AGENTS.md` is a symlink)
- `docs/philosophy.md`
- `docs/prior-art.md`

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All four files must be created. Paths are relative to repo root.

1. `templates/stage-card.md`: parameterised template; filling it in must reproduce a card of the same shape as this one.
2. `templates/worker-prompt.md`: the prompt a worker reads when picking up a card. Includes the load-bearing instructions a worker needs every time (read the card, do not exceed the deliverables list, surface blockers rather than guess).
3. `templates/orchestrator-checklist.md`: the orchestrator-side checklist to run through *before* dispatching a worker (have you specified acceptance criteria? have you named the verifier? is the sandbox role set correctly? etc.).
4. `docs/dispatch-contract.md`: the prose contract document. Describes the protocol end-to-end: orchestrator authors card -> worker reads card
   + prompt -> worker writes deliverables inside its sandbox -> orchestrator hands off to verifier -> verifier runs acceptance command outside the worker's sandbox -> orchestrator integrates. Must reference all five headless gotchas where relevant.

## Constraints

- **Language:** British English. No em dashes. No "AI-tell" vocabulary (`delve`, `leverage`, `seamless`, `robust`, `comprehensive`, `tapestry`, `elegant`).
- **Family neutrality:** templates and the contract doc must work for Claude Code workers, Codex CLI workers, and any future family. Do not hard-code Claude-specific or Codex-specific instructions. Where a step is genuinely family-specific (e.g. `codex exec`'s stdin gotcha), name the family explicitly and put it in a "family-specific notes" subsection.
- **Placeholder syntax:** `<<placeholder>>` (double angle brackets, kebab- case slug inside). Example: `<<objective>>`, `<<inputs>>`, `<<verifier-family>>`.
- **Self-evident templates:** a competent operator should be able to fill in the stage-card template once, without reading the contract doc, and produce something a worker can act on. The contract doc is the reference; the templates are the working surface.
- **No pass-2 references as if they exist:** `state.yaml`, `tick.sh`, `phat-controller`, `budget.sh`, `schemas/` do not yet exist in this repo. Mention them only as future scope, never as if they're current.
- **No autometta-specific content in templates.** The templates live under `templates/` and must be reusable in another repo by copying alone. Autometta-specific narrative belongs in `docs/`, not in templates.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. **All four files exist** at the named paths and are non-empty.
2. **Round-trip:** filling in `templates/stage-card.md` with this card's content would produce a document of the same structure as this card (same section headings, same metadata fields, same placeholder slots).
3. **Contract completeness:** `docs/dispatch-contract.md` describes each of these steps in order: stage card authoring -> worker prompt -> worker sandbox -> acceptance command -> verifier handoff -> orchestrator integration -> commit. It also enumerates the five headless gotchas (stdin hang, card-sync race, opaque log paths, sandbox-as-role- boundary, prior-gate regressions) and explains where in the protocol each one is mitigated.
4. **Style audit:** no em dashes anywhere in the four files; none of `delve|leverage|seamless|robust|comprehensive|tapestry|elegant` case-insensitive.
5. **No phantom artefacts:** no file references `state.yaml`, `tick.sh`, `phat-controller`, `budget.sh`, or `schemas/` as currently existing. They may be mentioned as future scope under an explicit "future scope" heading.
6. **Family neutrality:** the templates contain no occurrence of "Claude" or "Codex" except inside an explicitly labelled "family-specific notes" subsection.
7. **No autometta-specific text in `templates/`:** the three template files must not contain the word "autometta" outside frontmatter comments.

## Out of scope

- `docs/lessons.md`, `docs/verification.md` (these are stage 1).
- Populating `examples/` (stage 2).
- Pass-2 artefacts (scripts/, schemas/, state.yaml, tick.sh).
- Updating `README.md`, `CLAUDE.md`, or `docs/philosophy.md`.

## Budget

- **Worker wall-clock:** 6 minutes. If you cannot complete within that budget, surface a partial result with a clear blocker statement and stop. Do not silently continue.
- **Verifier wall-clock:** 8 minutes (T1 budget).

## Verifier handoff

When deliverables are written, return a one-paragraph summary naming each created file and the acceptance criteria you believe are satisfied. The orchestrator will then dispatch the Codex verifier to check independently.

## Family-specific notes

None at this stage. The worker is a Claude Sonnet sub-agent dispatched via the Task tool; the verifier is `codex exec --sandbox read-only` with stdin redirected from `/dev/null`.
