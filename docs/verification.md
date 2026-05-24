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

The default failure budget is one re-brief at the same tier, then surface.

- First failure: orchestrator re-briefs once, preserving the same stage boundary.
- Second failure: orchestrator surfaces to the user, with evidence and unresolved blockers.

This keeps stage churn bounded and prevents indefinite retry loops.

## Cross-family verification default

Cross-family pairing is the default gate posture: worker in one family, verifier in another.

The named memory entries for stage 0 document why, same-family author and orchestrator missed style faults, while cross-family verification detected them quickly. Same-family verification is permitted only with an explicit rationale in the stage card metadata.

## Verifier and orchestrator role separation

The verifier judges criteria and reports evidence. The orchestrator owns integration, re-brief decisions, and final commit actions.

This separation keeps responsibilities clear:

- Verifier: run checks, produce evidence, return verdict.
- Orchestrator: read full diff, reconcile intent versus output, choose re-brief or surface path, and complete integration.

For the full operational sequence, see [Step 6: Orchestrator integration](dispatch-contract.md#step-6-orchestrator-integration) and [Step 7: Commit](dispatch-contract.md#step-7-commit).

## Family-specific verification notes

### Codex worker detail

For Codex headless dispatch, stdin redirection from `/dev/null` is mandatory at dispatch time. This is a worker-family detail that protects the gate from false timeout signals caused by stdin waits.

### Future scope boundary

Pass-2 loop artefacts are outside the pass-1 verifier contract. References to `state.yaml`, `autometta tick`, `phat-controller`, `budget.sh`, and `schemas/` should remain explicitly labelled as pass-2 concerns when a verifier is checking a pass-1-only stage.
