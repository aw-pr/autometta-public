# Stage card 15b-sdk-verifier-rubric-contract: Lift the verifier rubric into a JSON Schema and emit it from the SDK verifier

## Metadata

- **Authored:** 2026-05-27
- **Orchestrator:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Worker:** Codex GPT-5.3 <codex-gpt-5-3@local>
- **Verifier:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Pairing rationale:** Cross-family. Codex is comfortable with JSON Schema authoring; Claude verifies that the SDK output validates against the schema and that the new shape is a superset of the old (no information lost).

## Surfacing concern

The current verifier JSON is shaped by convention — each verifier emits roughly the same keys but there is no schema and no validator. The SDK prototype from 15a copied the existing shape by hand. To replace a verifier call in 15c safely, the schema needs to be explicit, the SDK verifier needs to emit against it, and the existing CLI verifier output needs to be backfilled against it so we can prove equivalence.

## Objective

Write a JSON Schema for the verifier artefact, update `scripts/verify-sdk.py` to validate its output against the schema before writing, and add a one-shot script that validates all historical `state/verifiers/*.json` against the schema. Schema additions over the current shape must be backward-compatible (existing artefacts still validate). No changes to `spawn-verifier.sh` yet.

## Inputs

- `scripts/verify-sdk.py` — from 15a.
- `state/verifiers/*.json` — every historical verifier artefact (this is the corpus the schema must accept).
- `schemas/state.yaml.json` — exemplar JSON Schema in this repo; mirror its `$id` / `$schema` / docstring conventions.
- `templates/verifier-prompt.md` — the rubric prose; the schema formalises what it asks for.

## Deliverables

1. `schemas/verifier.json` — JSON Schema 2020-12 for the verifier artefact. Must accept every existing `state/verifiers/*.json` unchanged.
2. `scripts/verify-sdk.py` — updated to validate its output against `schemas/verifier.json` before writing. On validation failure, write the artefact to `<out>.invalid.json` and exit 3.
3. `scripts/validate-verifier-artefacts.sh` — one-shot validator. Iterates `state/verifiers/*.json`, prints `PASS` / `FAIL <path>: <jsonschema error>` per file. Exits non-zero if any fail.
4. `scripts/requirements-sdk.txt` — add `jsonschema` pin.
5. `docs/sdk-verifier.md` — extend with a "Rubric schema" section pointing at `schemas/verifier.json` and the validator script.
6. `memory/decision-verifier-rubric-schema.md` — decision memo. Why a schema now rather than later, why backward-compatible only, why a separate validator script rather than CI.

## Constraints

- Schema must validate every existing `state/verifiers/*.json` with zero changes to those files.
- Schema additions beyond the existing shape are allowed only if they are optional (not in `required`).
- No changes to `spawn-verifier.sh`, `bin/autometta`, or the `claude -p` verifier prompt.
- No new system dependencies beyond `jsonschema` (Python stdlib + that one package).
- Validator script must work without internet access (no `$ref` resolution to external URIs).

## Acceptance criteria

1. `scripts/validate-verifier-artefacts.sh` exits 0 on the current `state/verifiers/` corpus.
2. Adding a deliberately malformed test artefact (missing `overall` key) at `/tmp/bad.json` and pointing the validator at it yields `FAIL` with a clear message naming the missing key.
3. `scripts/verify-sdk.py` against stage 14 (as in 15a acceptance #4) writes a schema-valid artefact.
4. Forcing the SDK to emit an invalid artefact (test by patching the script's emit step in-test) writes `<out>.invalid.json` and exits 3.
5. `schemas/verifier.json` carries `$id` and `$schema` keys matching the convention in `schemas/state.yaml.json`.
6. Every required key in the schema has a `description` field.
7. `docs/sdk-verifier.md` Rubric section names the schema path and validator script.
8. `memory/decision-verifier-rubric-schema.md` links to `[[decision-sdk-verifier-prototype]]`.
9. No files outside the deliverables list are modified.

## Out of scope

- Replacing the CLI verifier prompt with the schema. The current prose prompt continues to work.
- Validating the schema in CI / pre-commit. Manual run only for v1.
- Adding new rubric criteria. Shape-only change.

## Budget

- **Worker wall-clock:** 30 minutes.
- **Verifier wall-clock:** 15 minutes.

## Verifier handoff

Worker writes the deliverables, runs `scripts/validate-verifier-artefacts.sh` and pastes the output in its completion message, and confirms acceptance #4 by attaching the `<out>.invalid.json` diff. Verifier reads the card and deliverables, validates the schema against a sampled subset of `state/verifiers/`, and writes `state/verifiers/15b-sdk-verifier-rubric-contract.json`.

## Family-specific notes

None. JSON Schema work is family-neutral.
