# Scorecard - BENCH-005

> Scoring rubric and anchor definitions: see `rubric.md`.
> All scores are integers 1-5. Total is the sum of all six dimensions (max 30).

---

## Metadata

| Field | Value |
|-------|-------|
| Task ID | BENCH-005 |
| Date scored | 2026-05-23 |
| Scorer | {{name or "orchestrator"}} |
| Brief | [brief.md](./brief.md) |

---

## Tool provenance

Record the exact model and harness behind each row. This is mandatory: a Cursor or any row whose underlying model is not recorded is an uninterpretable datapoint - see the void rule in `rubric.md`.

| Tool row | Harness | Underlying model | Provider |
|----------|---------|------------------|----------|
| claude | Claude Code (native) | {{e.g. Opus 4.7}} | Anthropic |
| codex | Codex CLI (native) | {{e.g. GPT-5.5 x-high}} | OpenAI |
| cursor | Cursor (wrapper) | {{REQUIRED - the exact model Cursor was set to}} | {{Anthropic / OpenAI / other}} |
| gemini | Gemini (native) | {{e.g. gemini-2.5-pro}} | Google |

**Harness-isolation note.** Cursor wraps someone else's model, so its row is only meaningful read against the native row of the *same* model:

- Cursor on an Anthropic model -> compare to the `claude` row. Any delta is Cursor's scaffolding (context handling, tool loop, autocomplete), not the model.
- Cursor on an OpenAI/Codex model -> compare to the `codex` row, same logic.

State which native row Cursor is being diffed against and what the delta tells you, in the Cursor per-tool note below. If Cursor's model can't be established, mark the row void rather than guessing.

---

## Results

| Tool | Correctness | Iterations | Quality | Failure mode | Autonomy | Time | **Total** |
|------|:-----------:|:----------:|:-------:|:------------:|:--------:|:----:|:---------:|
| claude | | | | | | | |
| codex | | | | | | | |
| cursor | | | | | | | |
| gemini | | | | | | | |

---

## Per-tool notes

### Claude (Claude Max / Opus)

*Observations, failure modes, surprises.*

### Codex (Codex Plus)

*Observations, failure modes, surprises.*

### Cursor (Cursor Pro)

*Observations, failure modes, surprises.*

*Harness delta - required: which native row this is diffed against (claude or codex, per the model recorded in Tool provenance), and what differs that is attributable to Cursor's harness rather than the model itself.*

### Gemini (Gemini Plus)

*Observations, failure modes, surprises.*

---

## Verdict

**Winner:** {{tool-handle}}

**Runner-up:** {{tool-handle}}

**Key finding (one sentence):** {{KEY-FINDING}}

**iTone post angle (optional):** {{POST-ANGLE}}
