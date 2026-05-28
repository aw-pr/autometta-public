# Retro-grade

`autometta retro-grade` re-runs the current verifier rubric over recent completed stages through the Anthropic Message Batch API. It is for drift detection: a stage that passed under an older rubric might fail under the current one, or the reverse.

## Run it

Dry-run builds the payload without credentials or API spend:

```sh
autometta retro-grade --dry-run --last 5
```

The payload is written to `/tmp/retro-grade-batch.jsonl`. Each line is one Anthropic batch request with `custom_id` and `params`.

Live mode submits and polls the batch:

```sh
autometta retro-grade --last 20
```

Live submission goes through `op-fetch` with `OP_REF_ANTHROPIC_API_KEY`, then runs `python3 scripts/retro-grade-batch.py`. There is no live API fallback. If submission fails, no report is written.

## Cost

The default is `--last 20` to keep spend predictable. Anthropic batch pricing is lower than live calls, and this job can wait for the batch SLA rather than spending on interactive latency.

The report frontmatter records:

- `batch: true`
- `input_tokens`
- `output_tokens`
- `total_tokens`

The body repeats those values as a batch token log. This keeps batch usage separate from the normal worker and verifier token accounting in `state/budget.json`.

## Report

The live report is written to:

```text
memory/retro-grade-<YYYY-MM-DD>.md
```

The report body lists only disagreements. Silence means the retro grade matched the original verdict. A completed stage without a verifier artefact is treated as original `PASS`, because completion is the only stored acceptance signal for that stage.

The frontmatter validates against `schemas/retro-grade-report.json`.

## Advisory contract

Retro-grade is advisory only. It never edits `state/state.yaml`, never overwrites `state/verifiers/<stage-id>.json`, and never reopens a completed stage. The operator decides whether a disagreement deserves a new card, a rubric change, or no action.

## Timeout

Polling has a hard cap, defaulting to 25 hours. If the batch has not ended before that cap, the command exits non-zero and prints the batch id for manual recovery. Partial results are not written as a report.
