# Stage card 19-batch-retro-grade: Weekly batch retro-grade of past stage outputs via Anthropic Batch API

## Metadata

- **Authored:** 2026-05-27
- **Orchestrator:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Worker:** Codex GPT-5.3 <codex-gpt-5-3@local>
- **Verifier:** Claude Sonnet 4.6 <claude-sonnet-4-6@local>
- **Pairing rationale:** Cross-family. Codex builds the batch submit + result-poll script; Sonnet (cheaper than Opus, structured-output friendly) verifies that the drift report shape matches the spec and that no batch result is silently dropped.
- **Depends on:** 15b (rubric schema) and 17 (handoff envelope). Independent of 18 (panel).

## Surfacing concern

Verifier acceptance criteria evolve as the repo learns. A stage that PASSed under last month's rubric might FAIL under today's, and vice versa. Today there is no way to surface that drift; the only signals are forward (next stage's verifier) and incident-driven (something breaks and we audit retrospectively). Anthropic's Batch API is ~50% the price of live calls and has a 24-hour SLA, which is the right shape for a periodic "would this still pass?" sweep.

## Objective

Add a `scripts/retro-grade.sh` runner that selects the last N completed stages (default N=20), submits them as a batch to the Anthropic Batch API with the *current* rubric, polls for completion, parses results, and writes a single drift report to `memory/retro-grade-<YYYY-MM-DD>.md` listing any stage whose retro grade disagrees with the original. No state mutation — the report is advisory.

## Inputs

- `state/state.yaml` — to enumerate completed stages.
- `state/verifiers/*.json` — original verifier outputs.
- `examples/self-host/*.md` — original stage cards.
- `schemas/verifier.json` — current rubric schema.
- `templates/verifier-prompt.md` — current rubric prose.
- Anthropic Batch API docs (worker reads via SDK package; no live web fetch).

## Deliverables

1. `scripts/retro-grade.sh` — orchestrates the batch. Args: `--last N` (default 20), `--dry-run` (build the batch payload but don't submit). Uses `op-fetch OP_REF_ANTHROPIC_API_KEY -- python3 scripts/retro-grade-batch.py` under the hood.
2. `scripts/retro-grade-batch.py` — Python entrypoint. Builds the batch JSONL, submits via SDK, polls (with backoff inside the 24-hour SLA), parses, writes the drift report.
3. `schemas/retro-grade-report.json` — JSON Schema for the drift report payload (a Markdown-with-frontmatter file; the schema covers the frontmatter only).
4. `memory/retro-grade-template.md` — the report template the worker substitutes against.
5. `docs/retro-grade.md` — when to run, what it costs, how to read the report, why the report is advisory not state-mutating.
6. `memory/decision-retro-grade.md` — decision memo. Why batch not live, why advisory not state-mutating, why memory/ not state/, why the operator triggers it (not cron) for v1.
7. `bin/autometta` — new subcommand `autometta retro-grade [--last N] [--dry-run]`.

## Constraints

- Batch submission must use the existing `op-fetch` auth boundary. No new credential surface.
- The retro grade is advisory: it never mutates `state/state.yaml`, never overwrites `state/verifiers/<stage-id>.json`. Output is one file under `memory/`.
- Drift report lists only disagreements. A stage that re-grades identically is not in the report (silence = no drift).
- Default `--last 20` keeps batch cost predictable (~$0.10-0.20 at current Sonnet batch pricing per stage).
- Batch polling has a hard wall-clock cap (default 25 hours, slightly over SLA). On timeout, the run aborts with a clear message and the partial batch ID is recorded for manual recovery.
- No live API fallback. If batch submission fails, the script exits non-zero and writes nothing.

## Acceptance criteria

1. `autometta retro-grade --dry-run --last 5` builds a batch payload to `/tmp/retro-grade-batch.jsonl` containing five rubric calls and exits 0 without hitting the API.
2. The dry-run payload validates against the Anthropic Batch JSONL shape (one request per line, each with `custom_id`, `params`, etc.).
3. A live run (`autometta retro-grade --last 5` with auth) submits, polls, and produces `memory/retro-grade-<YYYY-MM-DD>.md`.
4. The drift report frontmatter validates against `schemas/retro-grade-report.json`.
5. The report includes only stages whose retro `overall` differs from the original `overall`.
6. `state/state.yaml` is byte-identical before and after the run.
7. `state/verifiers/*.json` is byte-identical before and after the run.
8. A simulated batch timeout (test by patching the poll function in-test) yields a clear error message naming the batch ID and exits non-zero.
9. The cost log records the batch's total `input_tokens` + `output_tokens` separately from live-run usage (tag the log entry `batch=true`).
10. `docs/retro-grade.md` documents the cost and the advisory-only contract.

## Out of scope

- Auto-revising stage cards from drift report. The operator decides whether to re-brief.
- Triggering the batch from cron. v1 is operator-triggered.
- Codex side equivalent (OpenAI Batch). Different API shape, separate card if useful.
- Per-stage opt-out flag. Every completed stage is eligible.
- Trend graphs over time. v1 is per-run report only.

## Budget

- **Worker wall-clock:** 60 minutes (includes a live dry-run submit-and-poll cycle if the operator authorises).
- **Verifier wall-clock:** 25 minutes (dry-run only; the verifier does not submit a live batch).

## Verifier handoff

Worker writes the deliverables, runs `autometta retro-grade --dry-run --last 5` and pastes the resulting JSONL in its completion message. If the operator authorises a live run, worker also pastes the drift report path. Worker writes `state/handoffs/19-batch-retro-grade.json`. Verifier reads card and deliverables, runs the dry-run command, validates the JSONL shape, and writes `state/verifiers/19-batch-retro-grade.json`.

## Family-specific notes

- **Codex (worker):** stdin redirect for any subprocess. Sandbox `workspace-write` is sufficient (writes to `/tmp` and to `memory/`).
- **Sonnet (verifier):** runs outside the worker sandbox. Verifier does not submit a live batch (cost guard).
