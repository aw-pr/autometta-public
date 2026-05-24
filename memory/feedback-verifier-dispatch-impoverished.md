---
name: feedback-verifier-dispatch-impoverished
description: spawn-verifier.sh builds a one-sentence prompt with no criteria, inputs, or artefact schema. No verifier-prompt template exists. Worker side is templated, verifier side is not.
metadata:
  type: feedback
---

`scripts/spawn-verifier.sh` constructs the verifier prompt inline:

```sh
cmd="Run verifier for stage ${stage_id}. Write JSON to ${artefact_path}."
codex exec --sandbox read-only "$cmd" </dev/null >"$log_path" 2>&1 &
```

That is the entire prompt. The verifier is given a stage id and a write path, nothing else. It does not know:

- which acceptance criteria to check
- where the stage card lives
- which files are the deliverables
- what JSON schema the artefact should conform to
- how to format pass/fail evidence

In every interactive cross-family verification this session has done (stages 0 through 5b), the verifier prompt was a substantial briefing constructed by the orchestrator, often 30+ lines, listing each acceptance criterion verbatim with explicit output structure. The spawn-verifier.sh dispatch path skips all of that.

`templates/worker-prompt.md` exists as the worker-side template, but there is no `templates/verifier-prompt.md`. Stage 5 implementation shipped a worker prompt template, not a verifier prompt template. Stage 5b did not add one. Stage 6 just discovered the gap.

**Why:** Surfaced while preparing the dispatch test in the stage 6 dry run. Before authoring a trivial test card, the orchestrator inspected spawn-verifier.sh and stopped: running a real dispatch with the current verifier brief would produce noise (improvised JSON with no relation to any acceptance criterion), at a cost of ~$1 in model spend per test. Better to fix the brief first.

**How to apply:** Add `templates/verifier-prompt.md` and update `scripts/spawn-verifier.sh` to render it the way `spawn-worker.sh::render_prompt` renders the worker prompt. The template must include slots for:

- `<<stage-id>>`
- `<<stage-card-path>>` (so the verifier can read the criteria)
- `<<artefact-path>>` (where to write the JSON report)
- `<<artefact-schema-hint>>` (or include the schema inline)
- The invariant verifier rules (read-only sandbox, output exactly the required JSON shape, no fabrication, criterion-by-criterion evidence with file:line citation)

The artefact JSON shape was sketched in `docs/phat-controller.md` section (d) but no schema was committed. Either commit `schemas/verifier-artefact.json` to make the shape enforceable, or keep it informal and rely on the template to dictate format.

**Cross-references and dependent gaps:**

- [[feedback-tick-respawns-verifier-while-worker-running]] (sibling gap: tick has no kill -0 check, so it would dispatch the verifier on every tick that current_stage is in_progress and artefact absent, stacking multiple verifier processes against a still- running worker).
- [[feedback-verifier-prompt-mirrors-stage-card]] (earlier lesson about verifier prompts needing to reflect the stage card; same principle scaled to the dispatch path).
- [[decision-verifier-handoff-naming]] (the artefact path convention is correctly applied: `state/verifiers/<stage-id>.json`).

This gap blocks stage 6 from running a real dispatch test. Fix is small (one template + ~20 line edit to spawn-verifier.sh) and focused; suitable for inclusion in stage 5c hardening alongside the branch-switch and add-stage helper.
