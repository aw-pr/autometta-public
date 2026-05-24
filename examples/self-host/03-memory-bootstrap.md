# Stage card 03: Memory bootstrap from philosophy `<ALW>` tags

## Metadata

- **Authored:** 2026-05-21
- **Orchestrator:** Claude Opus 4.7 (main session)
- **Worker:** Codex GPT-5.3 (`codex exec --sandbox workspace-write`, stdin from /dev/null)
- **Verifier:** Claude Sonnet 4.6 (Task sub-agent)
- **Pairing rationale:** Alternation maintained. Stage 2 was Claude/Codex; stage 3 is Codex/Claude. The cross-family habit is now the default per `memory/project-cross-family-verification-validated.md`.

## Objective

Convert the five `<ALW>` open-question tags in `docs/philosophy.md` into structured project memory entries, then remove the tags from `philosophy.md` by integrating Tony's resolved text into the surrounding prose. After this stage, future sessions read the resolutions from `memory/` and from clean philosophy text, not from inline open notes.

## Inputs (read these in your own context)

- `docs/philosophy.md`
- `memory/README.md`
- `memory/INDEX.md`
- One existing memory entry as a format reference: `memory/project-cross-family-verification-validated.md`
- `CLAUDE.md` (for the `<ALW>` convention)

Do not read anything else.

## The five open questions and their resolutions

These appear inline in `docs/philosophy.md` lines 104 to 114 as `<ALW>...</ALW>` (or variant) tags. The closing tags are inconsistently spelled in the source: `</>`, `<?ALW>`, `<ALW/>`. Treat any tag matching `<ALW>` opening or any plausible closing variant as the boundary. For each question, the user's resolved answer is the inline text between the tags.

1. **Naming the loop layer.** Question: keep "Mayor" or pick own? Resolution: name is `phat-controller`.
2. **Single-tenant vs multi-project.** Question: one cron tick per repo, or one tick servicing many? Resolution: one cron tick, with repos "subscribing" to it, perhaps by publishing a call into `phat-controller`.
3. **Identity drift.** Question: pin or float the model identity referenced in stage cards in flight? Resolution: use the `agent-orchestrator` skill to maintain agents and their equivalents in model families.
4. **Verifier handoff format.** Question: `result.json` to `result.worker.json` rename, or something less surprising? Resolution: call the artefact "verifiers".
5. **Failure budget.** Question: token cap only, or also wall-clock / consecutive-failure cap? Resolution: timeouts come from a clock tick count, implemented per repo with filesystem state as per the memory directive.

## Deliverables

All paths relative to repo root.

1. **Five memory entries** under `memory/`, one per resolved question. Naming convention: `decision-<short-kebab-case-slug>.md`. Use `type: project` in the frontmatter (these are project-level decisions). Each entry: lead with the decision, then a `**Why:**` line stating the question this resolves and any motivation, then a `**How to apply:**` line. Link related entries with `[[name]]`. Suggested slugs: `decision-loop-name-phat-controller`, `decision-single-tick-multi-repo-subscribe`, `decision-identity-via-orchestrator-skill`, `decision-verifier-handoff-naming`, `decision-failure-budget-clock-tick`.
2. **Update `memory/INDEX.md`** with one one-line entry per new memory file. Keep entries under 150 chars. Place new entries after the existing four lines.
3. **Update `docs/philosophy.md`** to remove the five `<ALW>` tags. Replace each bullet's tag region with a clean prose resolution integrated into the bullet, and a parenthetical `(see memory/<slug>.md)` cross-reference. Do not rewrite the question text; only the resolution region changes.

## Constraints

- **British English. No em dashes anywhere in any deliverable.** No AI-tell vocabulary (`delve`, `leverage`, `seamless`, `robust`, `comprehensive`, `tapestry`, `elegant`, case-insensitive).
- **Do not editorialise the resolutions.** Tony's inline text IS the resolution. Convert it into clean prose without adding new claims, new constraints, or new constraints-on-future-pass-2.
- **No phantom artefacts.** `tick.sh`, `state.yaml`, `phat-controller` as a *built artefact*, `budget.sh`, `schemas/` do not yet exist. `phat-controller` may be referenced as a name for the pass-2 layer that does not yet exist. Decisions about pass-2 design may state intent without claiming current existence.
- **Frontmatter format must match `memory/README.md`** exactly: name, description, type. The body structure for `type: project` is rule/fact, then `**Why:**`, then `**How to apply:**` as documented.
- **Cross-link the five new entries with `[[other-name]]` where related.** Entries 2 and 4 link to entry 1 (both reference `phat-controller`). Entry 5 links to entry 1 and entry 2.
- **Stage card exemption.** Per the criterion-exemption lesson (`memory/feedback-acceptance-criterion-stage-card-exemption.md`), the stage card at `examples/self-host/03-memory-bootstrap.md` is authored by the orchestrator and is exempt from criterion 6 below.

## Acceptance criteria

The verifier will check each independently.

1. **Five new memory files exist** under `memory/`, each with the correct frontmatter (`name`, `description`, `type: project`).
2. **Each memory file body** starts with a single-sentence decision, then a `**Why:**` line, then a `**How to apply:**` line. At least one entry contains a `[[other-entry-name]]` cross-link.
3. **`memory/INDEX.md`** lists each of the five new entries on its own line, in the format `- [Title](file.md): one-line hook`. Each line is under 150 characters.
4. **`docs/philosophy.md`** contains no occurrence of the substring `<ALW`, no closing variant (`</ALW>`, `</>`, `<?ALW>`, `<ALW/>`), and no remaining inline open-note remnant. The five bullet lines retain their original question text and now carry the integrated resolution prose plus a `(see memory/<slug>.md)` parenthetical.
5. **Style audit:** `grep -nE '-' docs/philosophy.md memory/decision-*.md memory/INDEX.md` returns nothing. Banned-vocabulary scan returns nothing across the same files.
6. **No files outside the deliverables set are modified by the worker.** Deliverables set: five files under `memory/decision-*.md`, `memory/INDEX.md`, `docs/philosophy.md`. The stage card itself at `examples/self-host/03-memory-bootstrap.md` is the orchestrator's audit-trail artefact and exempt from this criterion.
7. **Cross-references resolve.** Every `[[name]]` in the new memory entries points to a file under `memory/` that exists in this commit's tree.

## Out of scope

- Pass-2 design beyond what Tony's resolutions already state.
- Editing `docs/philosophy.md` beyond the five bullet regions named.
- Edits to `templates/`, `docs/dispatch-contract.md`, `docs/lessons.md`, `docs/verification.md`, `examples/fractals-stage-cards/`, `README.md`, `CLAUDE.md`, `AGENTS.md`, `skills/`.
- New memory entries beyond the five resolutions.

## Budget

- **Worker wall-clock:** 6 minutes.
- **Verifier wall-clock:** 5 minutes.

## Verifier handoff

When done, return a single paragraph naming each file written or modified and listing the criteria the worker believes satisfied. The orchestrator runs the style scan as the pre-verifier gate; if it fails, the worker is re-briefed once with the offending lines.

## Family-specific notes

- Codex worker: `codex exec --sandbox workspace-write "<prompt>" </dev/null > /tmp/codex-stage-03.log 2>&1`. Stdin redirect mitigates gotcha 1.
- Claude Sonnet verifier: Task sub-agent, model `sonnet`, read-only behaviour.
