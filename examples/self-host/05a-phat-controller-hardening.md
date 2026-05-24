<!--
Stage card 05a: phat-controller hardening. Authored by copying templates/stage-card.md. -->

# Stage card 05a: phat-controller hardening (gate items for stage 6)

## Metadata

- **Authored:** 2026-05-22
- **Orchestrator:** Claude Opus 4.7 (main session)
- **Worker:** Codex GPT-5.3 (`codex exec --sandbox workspace-write`, stdin from /dev/null)
- **Verifier:** Claude Sonnet 4.6 (Task sub-agent)
- **Pairing rationale:** Codex wrote `scripts/tick.sh` in stage 5 and knows the file shape; same family for surgical edits is the right tier. Cross-family verifier (Sonnet) catches regressions per `memory/project-cross-family-verification-validated.md`.

## Objective

Address the three production-blocking issues the stage-5 verifier flagged in `scripts/tick.sh`. Each issue is documented at `memory/feedback-stage-5-silent-failure-risks.md`; this card converts that diagnostic into committed fixes. The scope is surgical: only the named issues are addressed, not broader refactoring.

## Inputs (read these in your own context)

- `scripts/tick.sh`
- `scripts/budget.sh`
- `docs/phat-controller.md`
- `memory/feedback-stage-5-silent-failure-risks.md`
- `memory/decision-tick-implementation-parameters.md`

Do not read anything else.

## Deliverables

One file modified: `scripts/tick.sh`. Three surgical changes:

1. **`yq` absence detection.** Before any call to `yq`, the script must probe `command -v yq` and abort cleanly if absent. The abort path writes `halt_reason: yq-missing` into `state/budget.json` via `budget_halt`, logs the message to stderr, and exits non-zero. The current behaviour (silent abort under `set -euo pipefail` mid-tick) must not be reachable.
2. **Dirty working tree guard before `git checkout -B phat-controller/state`.** The script must check `git status --porcelain` first; if non-empty (excluding the changes the script itself just wrote to `state/`), the script aborts the tick with `halt_reason: dirty-working-tree` and exits non-zero rather than silently switching branches. The check should accept changes inside `state/` only.
3. **Elapsed-time stall detection.** The script's stall logic must compare the in-progress stage's `started_at` timestamp against the stage card's declared worker wall-clock budget plus 1.5x grace (default from `memory/decision-tick-implementation-parameters.md`). When elapsed exceeds budget + grace, the stage is marked `stalled`, the worker PID (if recorded) is sent `kill -TERM`, `consecutive_failures` is incremented, and the tick exits cleanly. Read the wall-clock budget from the stage card's `## Budget` section by grepping for "Worker wall-clock:"; if the budget cannot be parsed, default to 600 seconds and log a warning.

## Constraints

- **Surgical edits only.** Do not refactor unrelated parts of `scripts/tick.sh`. The diff should be a focused set of changes addressing the three issues. The verifier will check the diff size and call out scope creep.
- **Preserve the existing public surface.** Function names already in use by other scripts (`process_repo`, `state_apply_json`, etc.) keep their names and signatures. Helpers can be added.
- **Shell discipline.** Lines 1-3 of `scripts/tick.sh` remain exactly `#!/usr/bin/env bash`, `set -euo pipefail`, `IFS=$'\n\t'`. `bash -n` must remain clean after edits.
- **Style:** British English in comments. No em dashes. No AI-tell vocabulary.
- **No new external dependencies.** The fixes use only the existing dep set (`bash`, `jq`, `git`, `codex`, `claude`, `python3`, optional `yq`).
- **No execution.** Static validation only; the tick is not invoked as part of this stage.
- **Stage card exemption.** The stage card at `examples/self-host/05a-phat-controller-hardening.md` is exempt from criterion 6. New memory entries banked under the anchored-decisions rule are also exempt. `examples/self-host/PLAN.md` updates are exempt.

## Acceptance criteria

The verifier checks each independently.

1. **`yq` absent path.** Worker can demonstrate (by quoting the relevant lines) that the script probes for `yq` before any use and calls `budget_halt` on absence. The verifier greps for `command -v yq` or equivalent presence-check, and for `yq-missing` as the halt reason string.
2. **Dirty-tree guard.** The verifier greps for `git status --porcelain` in the same logical block as `git checkout -B phat-controller/state`, and confirms a guard that excludes `state/` changes but blocks on anything else. The halt reason `dirty-working-tree` must be present in the script.
3. **Elapsed-time stall.** The verifier greps for the budget parsing (something like `grep -E 'Worker wall-clock' <card>`), the time arithmetic (subtraction of `started_at` from `now`, using `date -d` or `python3 -c`), the 1.5x grace factor (constant `0.5` or `15` somewhere indicating the +50% rule), and the `kill -TERM` invocation guarded by `"${worker_pid:-}"`.
4. **`bash -n scripts/tick.sh` clean.**
5. **Lines 1-3 unchanged** (shebang + safety triplet).
6. **Diff stays surgical.** `git diff --stat HEAD scripts/tick.sh` shows a manageable change. The verifier looks at the diff and confirms no rewrite of unrelated logic.
7. **Style audit.** `grep -c '-' scripts/tick.sh` returns 0; banned-vocabulary scan returns no matches.

## Out of scope

- All other scripts (`budget.sh`, `spawn-worker.sh`, `spawn-verifier.sh`). They may need their own hardening eventually; not this stage.
- The init scripts (stage 5b, separate card).
- Execution of `tick.sh`.
- Edits to `docs/phat-controller.md` to reflect new behaviour. If the hardening reveals a design gap, flag it under "Additional findings" in the worker's return summary and bank a `memory/feedback-*.md` entry; do not silently amend the design.
- Edits to `README.md`, `CLAUDE.md`, `AGENTS.md`, `docs/philosophy.md`.
- Edits to schemas (no field additions; the existing `halt_reason` field accepts the new string values).

## Budget

- **Worker wall-clock:** 12 minutes (surgical edits to a single script).
- **Verifier wall-clock:** 6 minutes (diff read plus the structural greps).

## Verifier handoff

When done, the orchestrator runs `bash -n scripts/tick.sh`, the style scan, and a `git diff --stat HEAD scripts/tick.sh` to confirm the change set looks surgical. If any pre-check fails, the worker is re-briefed once with the offending lines. The verifier then runs the structural checks listed in criteria 1 through 7.

## Family-specific notes

- Codex worker: `codex exec --sandbox workspace-write "<prompt>" </dev/null > /tmp/codex-stage-05a.log 2>&1`. Stdin redirect mitigates gotcha 1.
- Claude Sonnet verifier: Task sub-agent, model `sonnet`. May invoke `bash -n` via Bash tool.

## Template defects noticed (filled in during this dogfooding pass)

- No new defects beyond the two noticed at stages 4 and 5b (tier slot, family-specific-notes slot). Not amended yet.
