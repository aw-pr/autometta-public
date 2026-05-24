# Stage card 01: Lessons and verification docs

## Metadata

- **Authored:** 2026-05-21
- **Orchestrator:** Claude Opus 4.7 (main session)
- **Worker:** Codex GPT-5.3 (`codex exec --sandbox workspace-write`, stdin from /dev/null)
- **Verifier:** Claude Sonnet 4.6 (Task sub-agent)
- **Pairing rationale:** Pairing rotated from stage 0 (Claude worker / Codex verifier) to exercise the other direction of cross-family verification. Banked lesson [[project-cross-family-verification-validated]] is provisional; this stage tests whether Claude-as-verifier catches Codex-side faults with the same reliability that Codex-as-verifier caught Claude's.

## Objective

Produce the two reference documents that flesh out the dispatch contract: `docs/lessons.md` (the five headless gotchas plus the four production quirks from the source projects, with incident context) and `docs/verification.md` (the gate model: how acceptance criteria are written, how the verifier reports, how re-brief works).

## Inputs (read these in your own context)

- `README.md`
- `docs/philosophy.md`
- `docs/prior-art.md`
- `docs/dispatch-contract.md`
- `templates/stage-card.md`
- `templates/orchestrator-checklist.md`
- `memory/INDEX.md` and the three entries it points to

Do not read anything else.

## Deliverables

All files relative to repo root. Write both; do not skip either.

1. `docs/lessons.md`: a structured catalogue of the five headless gotchas and the four kimble production quirks. For each lesson: name, one-sentence summary, the incident that surfaced it (source project + brief context), the failure mode if ignored, the mitigation (cross-referencing the dispatch-contract step where it lives). The five gotchas are: stdin hang, card-sync race, opaque log paths, sandbox-as-role-boundary, prior-gate regressions. The four kimble quirks are: codex sandbox flag default, state.yaml as the authority, publish-guard exemption for autonomous commits, result.json rename convention. If any quirk's detail cannot be reconstructed from the inputs, mark it explicitly as "detail TBD, reconstruct from source project" rather than invent.
2. `docs/verification.md`: the gate model. Cover: what makes a good acceptance criterion (structural, machine-checkable, single-judgement), the verifier's report format (criterion-by-criterion PASS/FAIL with file:line evidence, additional findings, overall verdict), the failure budget (one re-brief at the same tier, then surface), cross-family pairing as the default, and the role separation between verifier and orchestrator. Reference but do not duplicate the seven-step protocol in `dispatch-contract.md` - that document is the protocol; `verification.md` is the deeper view of step 4 and step 5.

## Constraints

- **Language:** British English. No em dashes anywhere. No "AI-tell" vocabulary: `delve`, `leverage`, `seamless`, `robust`, `comprehensive`, `tapestry`, `elegant`.
- **No fabrication.** If an incident detail is not in the inputs, mark "detail TBD" rather than invent. The lessons doc is the contract's institutional memory; a confabulated incident is worse than a stub.
- **No phantom artefacts.** `state.yaml`, `tick.sh`, `phat-controller`, `budget.sh`, `schemas/` do not yet exist. Reference them only as pass-2 future scope.
- **Cross-reference, do not duplicate.** Where dispatch-contract.md already covers a topic, link to its section by name rather than restating. Verification.md is a deepening, not a replacement.
- **Family-neutral protocol description.** The gate model in `verification.md` must not assume a specific family. Where a step is family-specific (e.g. `codex exec` stdin), name the family explicitly under a clearly labelled subsection.

## Acceptance criteria

The verifier will check each independently. Failure of any one is a failure of the stage.

1. **Both files exist** at the named paths and are non-empty.
2. **Lessons completeness:** `docs/lessons.md` contains a dedicated section for each of the five headless gotchas and each of the four kimble quirks (nine sections in total). Each section has: a name, a one-sentence summary, an incident origin, a failure mode, a mitigation.
3. **Verification gate-model completeness:** `docs/verification.md` covers each of (a) acceptance criterion design, (b) verifier report format, (c) failure budget, (d) cross-family default, (e) verifier-orchestrator role separation. Each as a distinct section or clearly labelled subsection.
4. **Style audit:** `grep -c '-' docs/lessons.md docs/verification.md` returns 0 for both files. Case-insensitive search for `delve|leverage|seamless|robust|comprehensive|tapestry|elegant` returns no matches.
5. **No phantom artefacts as current:** any mention of `state.yaml`, `tick.sh`, `phat-controller`, `budget.sh`, `schemas/` appears only in an explicit future-scope or pass-2 context, never as if currently existing.
6. **Cross-references resolve:** every internal link `docs/dispatch-contract.md#...` points to a section that exists. Every `[[memory-entry-name]]` reference resolves to a file under `memory/`.
7. **No fabricated incidents:** if a quirk's detail is not derivable from the inputs, the file must say "detail TBD" rather than carry a confident-sounding fabrication.

## Out of scope

- Anything under `templates/`, `examples/`, `scripts/`, `schemas/`, `state/`, `memory/`.
- Edits to `README.md`, `CLAUDE.md`, `docs/philosophy.md`, `docs/prior-art.md`, `docs/dispatch-contract.md`.
- Pass-2 design (that is stage 4).
- The `phat-controller` working name beyond a parenthetical mention under future scope.

## Budget

- **Worker wall-clock:** 8 minutes (codex exec, two documents).
- **Verifier wall-clock:** 6 minutes (Sonnet sub-agent, structural checks).

## Verifier handoff

When both files are written, surface a single paragraph summary naming each file and the acceptance criteria the worker believes are satisfied. Do not paste file contents back. The orchestrator runs a deterministic style scan (`grep -c '-' ...`) before handing to the verifier. If the style scan fails, the worker is re-briefed once with the offending lines pasted in. The verifier sees only files that pass the style scan.

## Family-specific notes

- Codex worker: invoked as `codex exec --sandbox workspace-write "<prompt>" </dev/null > /tmp/codex-stage-01.log 2>&1`. The `</dev/null` redirect mitigates the stdin-hang gotcha. The sandbox is workspace-write because the worker needs to create new files under `docs/`; this remains tighter than read-only's reverse problem (worker cannot commit, cannot fake acceptance).
- Claude Sonnet verifier: invoked via the Task tool with `model: sonnet`. The verifier reads from the same committed git state; the orchestrator must not modify the deliverables between worker return and verifier dispatch.
