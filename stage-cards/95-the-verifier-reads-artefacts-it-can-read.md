# Stage card 95: the verifier reads artefacts it can read

## Metadata

- **Authored:** 2026-08-31
- **Orchestrator:** Claude Fable 5 <claude-fable-5@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Opus 5 <claude-opus-5@local>
- **Base branch:** dev
- **Run branch:** autometta/95-the-verifier-reads-artefacts-it-can-read
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Gate:** stage-completed: 91-the-burn-is-visible-while-it-burns
- **Path claims:** scripts/verify-sdk.py, scripts/verify-sdk-openai.py, scripts/spawn-verifier.sh
- **Pairing rationale:** control-plane plumbing with existing smoke
  patterns beside it; codex worker on the mechanics, Claude verifier
  outside the sandbox, the standard seats for this run's script work.

## Objective

Stage 91's verifier died three times before evaluating a single criterion:
`verify-sdk: 'utf-8' codec can't decode byte 0x89 in position 0`. The
chain is structural. A card whose deliverables span multiple directories
makes `derive_artefact_glob` (scripts/spawn-verifier.sh:419) fall back to
`**`, the whole tree; `verify-sdk.py` then reads every match with
`read_text(encoding="utf-8")` (scripts/verify-sdk.py:207) to build the
prompt's artefact sections, and the repo's tracked
`docs/images/dashboard.png` starts with the PNG magic byte. Card 90 made
the SDK route the verifier's first choice, so every multi-directory card
in any repo holding one binary file now burns its whole attempt cap on
this crash, and the operator reads it as a stalled stage rather than a
transport defect.

Make the artefact collector robust in both SDK entrypoints: skip files
that are not decodable UTF-8 (and obvious non-text by a cheap sniff, a
NUL or the known magic bytes, without adding a dependency), note each
skip in the prompt's artefact section so the model knows the file existed,
cap the collected artefact bytes so `**` on a large repo cannot flood the
prompt, and never let one unreadable file kill the run. Tighten
`derive_artefact_glob` while there: exclude `.git`, `state`, and
`node_modules` segments from the broad fallback.

## Inputs (read these in your own context)

- scripts/verify-sdk.py (`read_text`, the artefact collection around
  line 273)
- scripts/verify-sdk-openai.py (imports and reuses the same helpers)
- scripts/spawn-verifier.sh (`derive_artefact_glob`, line 419)
- state/logs/91-the-burn-is-visible-while-it-burns-verifier.log (the
  crash, one line)

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/verify-sdk.py`: the artefact collector skips undecodable and
   binary files with a one-line note per skip in the artefact section,
   enforces a total collected-bytes cap (a sensible constant, stated in
   the code), and a *card* or *schema* that fails to read remains a hard
   error as today.
2. `scripts/verify-sdk-openai.py`: reuses the same collector; no fork of
   the logic. If it already imports the helper, the change lands once.
3. `scripts/spawn-verifier.sh`: `derive_artefact_glob`'s broad fallback
   excludes `.git`, `state`, and `node_modules` path segments.

## Constraints

- Reuse over re-implementation: one collector, imported by both
  entrypoints.
- No new dependencies; the binary sniff is stdlib-only.
- The rubric, schema validation, envelope writing, and effort handling
  are untouched.
- British English in prose, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

1. `python3 -m py_compile` passes on both entrypoints and `bash -n` on
   `scripts/spawn-verifier.sh`.
2. A fixture directory holding one PNG, one file of invalid UTF-8, and two
   small text files: the collector returns both text files, notes both
   skips, and raises nothing (evidence: a stubbed-transport run of the
   collector or `main()`).
3. With the fixture grown past the byte cap, collection stops at the cap
   with a note, and the run still completes.
4. A missing or unreadable card path still exits non-zero as on dev today.
5. The derived broad glob on this repo excludes `.git`, `state`, and
   `node_modules` matches (evidence: the glob or the matched list).
6. `git diff --stat` on the run branch touches only the three claimed
   paths.

## Contract test

- **Test file:** None
- **Assertions digest:** None

## Out of scope

- Reworking how cards declare artefacts (the glob derivation stays a
  best-effort fallback).
- The CLI verifier route, which never had this problem.
- Un-pinning this repo's manifest transport (the operator flips
  `verifier.claude.transport` back after this lands).

## Budget

- **Worker wall-clock:** 1800s
- **Verifier wall-clock:** 1500s

## Verifier handoff

Leave the working tree dirty. Report the fixture evidence for criteria
2, 3 and 5 verbatim, and the diff stat.

## Family-specific notes

None
