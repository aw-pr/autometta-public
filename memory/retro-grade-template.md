---
title: "Retro-grade <<date>>"
date: "<<date>>"
type: retro-grade-report
batch_id: "<<batch-id>>"
batch: true
model: "<<model>>"
stage_count: <<stage-count>>
drift_count: <<drift-count>>
input_tokens: <<input-tokens>>
output_tokens: <<output-tokens>>
total_tokens: <<total-tokens>>
---

# Retro-grade <<date>>

Batch id: `<<batch-id>>`

Model: `<<model>>`

Stages graded: <<stage-count>>

Batch token log: batch=true input_tokens=<<input-tokens>> output_tokens=<<output-tokens>> total_tokens=<<total-tokens>>

## Disagreements

<<drift-table>>

## Reading note

This report is advisory. It records where the current verifier rubric disagrees with the original stage verdict. It does not change `state/state.yaml` or any verifier artefact.
