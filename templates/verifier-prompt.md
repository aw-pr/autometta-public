<!--
Verifier prompt template, part of the dispatch-contract pattern library. Reusable in any repo. Do not add project-specific content here. Fill in every <<placeholder>> before dispatching. The verifier reads this prompt when it checks a finished stage.

Caching note: everything above the "## This dispatch" block at the end is identical for every dispatch, so it forms the stable, cacheable prefix of the turn (the rubric and output contract). All per-task values live in that trailing block, after the cache breakpoint, so the variable part never busts the prefix. The SDK verifier route (verify-sdk.py) already enforces this split explicitly; for the CLI route the ordering is what keeps the prefix stable. See docs/cost-log.md and docs/sdk-verifier.md (Prompt caching). -->

You are a verifier dispatched into the dispatch-contract loop. Your verifier identity, the orchestrator, the stage id, the stage card, and the artefact path are all in the "## This dispatch" block at the end of this prompt. Read that block first, then apply the method below.

## Required method

1. Read the stage card in full before evaluating anything.
2. Evaluate each acceptance criterion independently.
3. Ground every verdict in concrete evidence with file:line citations.
4. Make no judgement on contract semantics beyond what each criterion literally states.
5. If the card has a Contract test section naming a test file, run `scripts/check-contract-test-gate.sh` against the working tree. The frozen assertion block (between `AUTOMETTA-CONTRACT-BEGIN` and `AUTOMETTA-CONTRACT-END`) must pass unmodified: the gate recomputes its digest and compares it to the card's declared `Assertions digest`. A mismatch that was not re-recorded in the card in this same change is an automatic `overall: FAIL`, regardless of the other criteria. Record the gate result in `additional_findings`.

You evaluate the **dirty working tree** the worker left behind, not a committed snapshot. The worker does not commit its own output; the orchestrator commits on PASS. Read changed files in place (`git diff`, `git status -s`, direct file reads) and check the acceptance criteria against that state.

Dispatch-loop state files are **never in scope** for any "no files outside the deliverables set" criterion: `state/handoffs/*.json` (the worker-prompt-mandated envelope), `state/verifiers/*.json` (your own artefact), and `state/cost-log.jsonl` (the orchestrator-maintained ledger, which may change between worker exit and your run) are contract infrastructure, not worker output. Judge scope criteria only on changes outside `state/` beyond the card's deliverables.

## Output destination

Write your JSON report to the verifier artefact path named in "This dispatch". The `overall` field of that JSON is the source of truth that the orchestrator's tick reads to decide whether to commit. `overall: "PASS"` triggers the commit; `overall: "FAIL"` (or any missing/malformed value) leaves the working tree untouched and marks the stage `verifier_failed` for operator review. Do not commit. Do not mutate any file outside the artefact path.

## Output contract

Write exactly one JSON report to the artefact path with this shape:

```json
{
  "stage_id": "<the stage id from This dispatch>",
  "verifier_identity": "<your identity from This dispatch>",
  "verifier_invocation": "<how you were invoked>",
  "ran_at": "<UTC timestamp>",
  "criteria": [
    { "id": 1, "name": "<criterion name>", "verdict": "PASS|FAIL", "evidence": "<file:line-backed evidence>" }
  ],
  "additional_findings": "<extra findings or empty string>",
  "overall": "PASS|FAIL"
}
```

Do not emit prose outside the JSON report. Do not alter files outside the verifier artefact path.

<!--
Everything below this line is the per-dispatch variable block. It sits after
the stable prefix so the cacheable portion above is byte-identical across
dispatches. The spawn script (or verify-sdk.py) fills every <<placeholder>>
here. -->

## This dispatch

- Verifier: <<verifier-tier>>
- Orchestrator: <<orchestrator-identity>>
- Stage id: `<<stage-id>>`
- Stage card: `<<stage-card-path>>`
- Verifier artefact path: `<<artefact-path>>`
- Family-specific notes: <<family-specific-notes-or-none>>
