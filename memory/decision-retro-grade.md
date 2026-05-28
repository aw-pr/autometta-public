---
name: decision-retro-grade
description: Batch retro-grade is advisory and lives in memory.
type: project
---

# Decision: batch retro-grade is advisory

## Decision

Autometta uses Anthropic Message Batch for weekly retro-grade checks. The operator starts the run manually. The output is one report under `memory/`, and the run does not mutate `state/state.yaml` or `state/verifiers/`.

## Why batch, not live

Retro-grade is not interactive work. A 24-hour batch SLA is acceptable, and the lower batch price is a better fit for periodically rechecking many completed stages.

## Why advisory, not state-mutating

The original verifier result remains the audit trail for the commit that landed. A later rubric can disagree with that result, but changing state after the fact would blur history. The report should create operator attention, not rewrite acceptance.

## Why memory, not state

`state/` is the controller's live message bus. Retro-grade is institutional memory about how the rubric has moved. Storing it under `memory/` keeps it visible to future agents without making the controller treat it as runtime state.

## Why manual for v1

The cost is bounded by `--last`, but it is still real API spend. Manual triggering keeps v1 explicit while the report shape and usefulness settle. Cron can be considered later if the operator finds the report consistently useful.
