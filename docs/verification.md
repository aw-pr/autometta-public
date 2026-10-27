# Verification gate model

This document deepens the verification logic behind [Step 4: Acceptance command](dispatch-contract.md#step-4-acceptance-command) and [Step 5: Verifier handoff](dispatch-contract.md#step-5-verifier-handoff). The seven-step protocol remains canonical in [The seven steps](dispatch-contract.md#the-seven-steps).

## Acceptance criterion design

Good acceptance criteria are structural, machine-checkable, and single-judgement.

- Structural means each criterion points to a concrete artefact or rule, for example file existence, required section presence, or banned-token absence.
- Machine-checkable means a verifier can run deterministic checks without inventing interpretation.
- Single-judgement means each criterion can produce one PASS or FAIL outcome without compound ambiguity.

A stage card should define criteria so each one can map to one check and one evidence line.

## Verifier report format

Verifier output should be criterion-by-criterion, with explicit evidence.

- `Criterion N: PASS|FAIL`
- Evidence with file and line references for each judgement.
- Additional findings that are outside strict criteria but still relevant risk.
- Overall verdict, pass only if all required criteria pass.

This report is an input to the orchestrator, it is not an autonomous decision artefact.

## Failure budget and re-brief policy

For a manually driven pass-1 stage, the default failure budget is one re-brief at the same tier, then surface.

- First failure: orchestrator re-briefs once, preserving the same stage boundary.
- Second failure: orchestrator surfaces to the user, with evidence and unresolved blockers.

This keeps stage churn bounded and prevents indefinite retry loops.

The automated loop distinguishes mechanical recovery from a verifier rejection. A dead worker may receive a bounded recovery attempt; a verifier FAIL leaves the stage `verifier_failed` for an operator decision. It does not authorise the tick to change criteria or retry until green. Preserve the prior attempt and use the [requeue procedure](../skills/autometta-requeue/SKILL.md) before another authorised dispatch.

## Cross-family verification default

Cross-family pairing is the default gate posture: worker in one family, verifier in another.

The named memory entries for stage 0 document why, same-family author and orchestrator missed style faults, while cross-family verification detected them quickly. Same-family verification is permitted only with an explicit rationale in the stage card metadata.

## Verifier and orchestrator role separation

The verifier judges criteria and reports evidence. The orchestrator owns integration, re-brief decisions, and final commit actions.

This separation keeps responsibilities clear:

- Verifier: run checks against the dirty working tree, produce evidence, return verdict via the `overall` field of the artefact JSON.
- Orchestrator: read full diff, reconcile intent versus output, branch on `overall`, and either commit (PASS) or surface for operator review (FAIL).

For the full operational sequence, see [Step 6: Orchestrator integration](dispatch-contract.md#step-6-orchestrator-integration) and [Step 7: Commit](dispatch-contract.md#step-7-commit).

## Commit-on-verifier-pass branching (pass-2)

The pass-2 tick (`scripts/tick.sh`) operationalises Step 7's "orchestrator commits, not worker" rule by branching on the verifier artefact's `overall` field:

- `overall: PASS`: the orchestrator commits the worker's changes in the run worktree with `--author=<worker-identity>`, co-author attribution for orchestrator and verifier, and `Autometta-*` role trailers. The commit subject is `<stage-id>: <headline>`. The stage moves to `completed`; its separate integration record says whether the commit reached base.
- `overall: FAIL`: no accepted delivery commit. The stage moves to `verifier_failed`. The tick preserves the attempt on a `wip/<stage>-attempt-<n>` branch when possible and retains the run worktree for review. A preservation commit records failed work; it is not a passing delivery.
- Missing / malformed `overall`: treated as FAIL (fail-safe). Same handling as FAIL.
- Clean working tree on PASS: logged as the worker-self-commit path, retired by card 7 (2026-05); stage marked `completed` without erroring so a subscriber on a pre-card-7 worker prompt still lands.

The worker prompt explicitly forbids `git commit` so the dirty-tree contract holds. The verifier prompt explicitly states that the verifier reads the dirty tree (not a committed snapshot) and that the `overall` field drives the orchestrator's commit decision.

**PASS is not proof of integration.** The tick fast-forwards a passing run when possible. If base moved, it may rebase a disjoint change under the integration guards. Work that cannot land safely remains `integration.state: awaiting`, with its branch and worktree retained. Check that record and the current base before declaring the change available to a dependent stage. See [worktree-per-run dispatch](dispatch-contract.md#worktree-per-run-dispatch).

## Family-specific verification notes

### Codex worker detail

For Codex headless dispatch, stdin redirection from `/dev/null` is mandatory at dispatch time. This is a worker-family detail that protects the gate from false timeout signals caused by stdin waits.

### Future scope boundary

Pass-2 loop artefacts are outside the pass-1 verifier contract. References to `state.yaml`, `autometta tick`, the tick loop, `budget.sh`, and `schemas/` should remain explicitly labelled as pass-2 concerns when a verifier is checking a pass-1-only stage.
