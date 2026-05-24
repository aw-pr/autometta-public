# Lessons

This document records the failure patterns that shaped pass 1 of Autometta. It extends the protocol in [dispatch-contract step model](dispatch-contract.md#the-seven-steps) with incident context, failure modes, and mitigations.

## Headless gotcha 1: stdin hang

### One-sentence summary
A headless worker can block on stdin after parsing prompt arguments, then burn budget without producing output.

### Incident origin
Source project: fractals-from-the-90s, the named inputs identify this as a canonical headless gotcha in real use.

### Failure mode if ignored
The worker appears alive but never progresses, the stage times out, and the orchestrator gets no useful artefact.

### Mitigation
Apply the dispatch safeguards in [Step 3: Worker dispatch and sandbox](dispatch-contract.md#step-3-worker-dispatch-and-sandbox), including stdin redirection from `/dev/null`.

## Headless gotcha 2: card-sync race

### One-sentence summary
Worker and verifier can read different versions of the stage card when writes and reads are not serialised.

### Incident origin
Source project: fractals-from-the-90s, documented in the named inputs as a recurring race across worktrees or write timing.

### Failure mode if ignored
The worker executes one contract while the verifier checks another, which creates false failures or false passes.

### Mitigation
Use the controls in [Step 1: Stage card authoring](dispatch-contract.md#step-1-stage-card-authoring) and [Step 4: Acceptance command](dispatch-contract.md#step-4-acceptance-command), with one stable card snapshot before dispatch.

## Headless gotcha 3: opaque log paths

### One-sentence summary
Unstable harness-generated log paths make post-run diagnosis slow and unreliable.

### Incident origin
Source project: fractals-from-the-90s, identified in the named inputs as a repeated operational issue.

### Failure mode if ignored
Verifier and operator cannot find the right worker output quickly, so acceptance and failure triage stall.

### Mitigation
Follow [Step 2: Worker prompt assembly](dispatch-contract.md#step-2-worker-prompt-assembly) and [Step 3: Worker dispatch and sandbox](dispatch-contract.md#step-3-worker-dispatch-and-sandbox), and pin a predictable path such as `/tmp/codex-<stage-id>.log`.

## Headless gotcha 4: sandbox-as-role-boundary

### One-sentence summary
The worker sandbox is not just safety, it enforces separation between implementer and verifier.

### Incident origin
Source projects: fractals-from-the-90s and agentic-rag-kimble, both inputs frame this as a load-bearing boundary.

### Failure mode if ignored
If a worker can self-verify, it can report green without external evidence, which weakens the gate.

### Mitigation
Keep role separation from [Step 3: Worker dispatch and sandbox](dispatch-contract.md#step-3-worker-dispatch-and-sandbox) and [Step 4: Acceptance command](dispatch-contract.md#step-4-acceptance-command), with verifier checks outside the worker sandbox.

## Headless gotcha 5: prior-gate regressions

### One-sentence summary
A stage can pass local checks but still break a previously passing acceptance gate.

### Incident origin
Source project: fractals-from-the-90s, listed in the named inputs as a known headless regression class.

### Failure mode if ignored
A later stage ships with hidden regressions, then earlier guarantees silently rot.

### Mitigation
Run full-gate checks per [Step 4: Acceptance command](dispatch-contract.md#step-4-acceptance-command) and enforce reconciliation in [Step 6: Orchestrator integration](dispatch-contract.md#step-6-orchestrator-integration).

## Kimble production quirk 1: codex sandbox flag default

### One-sentence summary
Codex sandbox mode selection is a first-order control for what a worker can claim or change.

### Incident origin
Source project: agentic-rag-kimble pass 28-29, detail TBD, reconstruct from source project.

### Failure mode if ignored
A mismatched sandbox setting can block required writes or allow behaviour the stage did not intend.

### Mitigation
Declare and verify sandbox mode during [Step 3: Worker dispatch and sandbox](dispatch-contract.md#step-3-worker-dispatch-and-sandbox), with family-specific notes when needed.

## Kimble production quirk 2: state.yaml as the authority

### One-sentence summary
Loop decisions in pass 2 rely on a single authority file for current state.

### Incident origin
Source project: agentic-rag-kimble pass 28-29, described in named inputs as a core scaffold pattern.

### Failure mode if ignored
Multiple state sources drift, then dispatch decisions and status reporting diverge.

### Mitigation
For pass 1, keep this as future scope only and anchor current control flow in [What the contract does not cover](dispatch-contract.md#what-the-contract-does-not-cover) and [Future scope](dispatch-contract.md#future-scope).

## Kimble production quirk 3: publish-guard exemption for autonomous commits

### One-sentence summary
Autonomous commit flows may require a defined exemption path from standard publish guards.

### Incident origin
Source project: agentic-rag-kimble pass 28-29, detail TBD, reconstruct from source project.

### Failure mode if ignored
Autonomous runs can fail at commit or publish boundaries, or bypass policy without an explicit contract.

### Mitigation
Keep attribution and commit boundary explicit in [Step 7: Commit](dispatch-contract.md#step-7-commit), and document any exemption policy only when pass-2 artefacts are introduced.

## Kimble production quirk 4: result.json rename convention

### One-sentence summary
Verifier handoff naming conventions affect traceability of worker versus verifier outcomes.

### Incident origin
Source project: agentic-rag-kimble pass 28-29, the inputs note the `result.json` to `result.worker.json` rename question.

### Failure mode if ignored
Result files become ambiguous, then the orchestrator cannot tell which artefact reflects worker output and which reflects verifier judgement.

### Mitigation
Keep output ownership explicit through [Step 5: Verifier handoff](dispatch-contract.md#step-5-verifier-handoff) and [Step 6: Orchestrator integration](dispatch-contract.md#step-6-orchestrator-integration), with stable naming agreed in the stage card.
