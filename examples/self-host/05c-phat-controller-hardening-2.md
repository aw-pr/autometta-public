<!--
Stage card 05c: phat-controller hardening pass 2. Authored by copying templates/stage-card.md. Closes the three banked gaps from the stage-6 dry run plus two missing helpers. -->

# Stage card 05c: phat-controller hardening (round 2)

## Metadata

- **Authored:** 2026-05-22
- **Orchestrator:** Claude Opus 4.7 (main session) at authoring time; intended for re-dispatch by whichever orchestrator session picks this up next (handoff aware)
- **Worker:** Codex GPT-5.3 (`codex exec --sandbox workspace-write`, stdin from /dev/null)
- **Verifier:** Claude Sonnet 4.6 (Task sub-agent)
- **Pairing rationale:** Codex worker for shell-script + template work (same pattern as 5a and 5b, both clean). Cross-family Sonnet verifier per `memory/project-cross-family-verification-validated.md`.

## Objective

Close the three production-blocking gaps the stage-6 dry run banked plus two operator-ergonomics helpers identified during the same run. After this stage lands, the phat-controller loop should be ready for a real worker dispatch test on a tiny stage card.

## Inputs (read these in your own context)

- `scripts/tick.sh`
- `scripts/spawn-worker.sh`
- `scripts/spawn-verifier.sh`
- `scripts/budget.sh`
- `scripts/subscribe-repo.sh`
- `templates/worker-prompt.md`
- `docs/phat-controller.md`
- `memory/feedback-tick-switches-working-dir-branch.md`
- `memory/feedback-verifier-dispatch-impoverished.md`
- `memory/feedback-tick-respawns-verifier-while-worker-running.md`
- `memory/feedback-state-yaml-leaks-home-path.md` (for the reset-halt note)
- `memory/decision-tick-implementation-parameters.md`

Do not read anything else.

## Deliverables

All paths relative to repo root.

1. `templates/verifier-prompt.md`: new template, sibling to `templates/worker-prompt.md`. Family-neutral. Same `<<placeholder>>` style. Must include slots for `<<stage-id>>`, `<<stage-card-path>>`, `<<artefact-path>>`, `<<verifier-tier>>`, `<<orchestrator-identity>>`, and `<<family-specific-notes-or-none>>`. Must instruct the verifier to: (a) read the stage card in full, (b) check each acceptance criterion independently, (c) write a JSON report to the artefact path with the shape sketched in `docs/phat-controller.md` section (d) (fields: `stage_id`, `verifier_identity`, `verifier_invocation`, `ran_at`, `criteria[]` with `id`/`name`/`verdict`/`evidence`, `additional_findings`, `overall`), (d) be concrete with file:line citations, (e) make no judgement on contract semantics beyond what the criteria literally state.

2. `scripts/spawn-verifier.sh`: rewrite to render `templates/verifier-prompt.md` (mirroring how `spawn-worker.sh::render_prompt` renders `templates/worker-prompt.md`), with the placeholder substitutions, then dispatch with the rendered prompt. Same family-detection logic, same headless dispatch with `</dev/null` and the explicit log path. Keep the existing PID tracking and `update_verifier_state` behaviour.

3. `scripts/tick.sh` change A: process-alive guards. Before re-dispatching the verifier (the `else` branch on the in_progress path) check whether the worker is still alive: `if [[ -n "${worker_pid:-}" ]] && kill -0 "$worker_pid" 2>/dev/null` then log and skip dispatch (the worker is still producing its deliverables). Similarly, read the `verifier_pid` from state.yaml and skip dispatch if a verifier is already alive. The stall detection from 5a continues to fire on elapsed-time grace, so a stuck worker still gets reaped.

4. `scripts/tick.sh` change B: branch save/restore. In `commit_state_branch`, capture the original branch with `git rev-parse --abbrev-ref HEAD` before any checkout, and restore it before the function returns. Use a `trap ... RETURN` if convenient. Goal: after `tick.sh` exits, the operator's working tree is on whatever branch it was on at entry. Cron behaviour unchanged (cron runs in its own subprocess; the restore is a no-op there). Document in a comment that operators firing tick.sh interactively should expect their branch unchanged.

5. `scripts/tick.sh` change C: `--reset-halt` flag. Add a new flag alongside the existing `--repair` flag. When `--reset-halt` is passed, the script iterates subscribers, clears `halted: false`, `halt_reason: null`, `halted_at: null` in each subscriber's `budget.json`, logs what was reset, and exits 0 without dispatching anything. Useful after the operator addresses the cause of a halt and wants to resume without hand-editing JSON.

6. `scripts/add-stage.sh`: new helper. Signature: `scripts/add-stage.sh <repo-root> <stage-card-path>`. Reads the card to extract `stage-id` (basename without `.md`) and the `Worker:` / `Verifier:` identity lines. Splices a new entry into `<repo-root>/state/state.yaml`'s `stages[]` array via `yq`, with `status: pending`, the parsed worker and verifier identities, and all other optional fields null/absent. Idempotent: if a stage with the same id is already in the array, log "exists" and exit 0 without modifying.

## Constraints

- **Shell discipline:** every script's first three lines remain exactly `#!/usr/bin/env bash`, `set -euo pipefail`, `IFS=$'\n\t'`. `bash -n` clean on every script after edits.
- **Surgical edits to existing scripts.** The three changes to `tick.sh` are additive plus the small guard insertions; do not refactor `process_repo` wholesale. The rewrite of `spawn-verifier.sh` keeps the same external interface (`<stage-card-path> <repo-root>`, returns PID on stdout, writes state.yaml).
- **Style:** British English in comments, no em dashes, no AI-tell vocabulary.
- **Idempotency hard-required.** `--reset-halt` is idempotent (no-op on a non-halted budget). `add-stage.sh` is idempotent (no duplicate stages). `commit_state_branch` re-runs cleanly.
- **No execution.** Static validation only this stage. The dispatch test that uses the new behaviour comes after, as a separate operator decision.
- **No new external dependencies.** Existing dep set (`bash 3.2+`, `jq`, `git`, `codex`, `claude`, `python3`, `yq`).
- **Stage card exemption.** This card at `examples/self-host/05c-phat-controller-hardening-2.md` is exempt from criterion 10. New memory entries banked under the anchored-decisions rule are exempt. `examples/self-host/PLAN.md` updates are exempt.

## Acceptance criteria

The verifier checks each independently.

1. **All deliverable files exist** and are non-empty. `templates/verifier-prompt.md` and `scripts/add-stage.sh` are new files; the other three deliverables are edits to existing scripts.
2. **`bash -n` clean on all modified shell scripts** (`scripts/spawn-verifier.sh`, `scripts/tick.sh`, `scripts/add-stage.sh`).
3. **`templates/verifier-prompt.md` content check.** Verifier greps for every placeholder named in deliverable 1 (`<<stage-id>>`, `<<stage-card-path>>`, `<<artefact-path>>`, `<<verifier-tier>>`, `<<orchestrator-identity>>`, `<<family-specific-notes-or-none>>`), and confirms the body includes the JSON shape reference (mentions `stage_id`, `criteria`, `overall`).
4. **`spawn-verifier.sh` renders the template.** Verifier greps for a `render_prompt` (or similarly named) function that reads `templates/verifier-prompt.md` and applies sed substitutions, and confirms the old inline one-sentence prompt is gone.
5. **`tick.sh` process-alive guards present.** Verifier greps for `kill -0` with a `worker_pid` check and a `verifier_pid` check, both before the verifier dispatch call.
6. **`tick.sh` branch save/restore present.** Verifier greps for `git rev-parse --abbrev-ref HEAD` capture and a matching `git checkout` restore in `commit_state_branch`, or for a `trap ... RETURN` doing the same.
7. **`tick.sh --reset-halt` works statically.** Verifier greps for the flag handler and confirms it does NOT dispatch any worker or verifier (no calls to `spawn-worker.sh` / `spawn-verifier.sh` in the reset-halt branch).
8. **`add-stage.sh` interface check.** Verifier confirms positional-arg parsing (`<repo-root> <stage-card-path>`), `yq -i` splice into `.stages` array, and an existence check for idempotency.
9. **Style audit:** `grep -c '-' <all modified files>` returns 0. Banned-vocabulary scan returns no matches.
10. **No files outside the deliverables set are modified** (exemptions per the constraints section above).

## Out of scope

- Execution of any script.
- Real worker dispatch test (separate decision after this lands).
- Edits to `README.md`, `CLAUDE.md`, `AGENTS.md`, `docs/philosophy.md`, `docs/phat-controller.md`, schemas, or any pre-existing memory entry.
- The macOS-specific `stat -f` in `init-host.sh` (separate concern, banked at `memory/feedback-init-script-macos-specific.md`; not blocking).
- Worktree-based isolation as an alternative to branch save/restore (banked as a future option; not chosen for this stage to keep diff size manageable).
- A formal `schemas/verifier-artefact.json`. The shape in `docs/phat-controller.md` section (d) is informal; the verifier-prompt template carries the contract in prose.

## Budget

- **Worker wall-clock:** 18 minutes (one new template, one new helper script, edits to two existing scripts; manageable).
- **Verifier wall-clock:** 8 minutes (structural greps plus `bash -n` on each modified script).

## Verifier handoff

When all deliverables are written, the orchestrator runs the pre-verifier gate: `bash -n` on every modified script, style scan, idempotency-pattern grep, and the process-alive grep. If any pre-check fails, the worker is re-briefed once. The verifier then runs the structural checks listed in the acceptance criteria.

## Family-specific notes

- Codex worker: `codex exec --sandbox workspace-write "<prompt>" </dev/null > /tmp/codex-stage-05c.log 2>&1`. Stdin redirect mitigates gotcha 1.
- Claude Sonnet verifier: Task sub-agent, model `sonnet`. May invoke `bash -n` via Bash tool.

## Template defects noticed (filled in during this dogfooding pass)

- No new defects beyond previously banked. The card slot for "this is a follow-up hardening pass" reads naturally enough; no template amendment needed.

## Notes for the next orchestrator session (handoff context)

This card was authored in the same Claude Code session that ran the stage-6 dry run. The dry run completed, banked eight findings, fixed five in-script and decided two via operator question. The remaining three (branch switch, verifier prompt impoverished, verifier respawn during running worker) are addressed by this card, alongside two helpers (`add-stage.sh`, `--reset-halt`). Before dispatching this card:

1. Confirm `~/.phat-controller/` exists and `subscribers/autometta.yaml` is present (from the dry run).
2. Confirm `state/budget.json` shows `halted: true / halt_reason: budget cap exhausted` from the dry run. After 5c lands, the new `--reset-halt` is the right way to clear it.
3. Confirm `bash -n` passes on all current scripts: `scripts/tick.sh`, `scripts/spawn-worker.sh`, `scripts/spawn-verifier.sh`, `scripts/budget.sh`, `scripts/subscribe-repo.sh`, `scripts/init-host.sh`, `scripts/check-deps.sh`.
4. The orchestrator's working tree should be on `dev`. If it has drifted to `phat-controller/state` (a known footgun), `git checkout dev` first.

After 5c lands and verifies clean, the real dispatch test is the next decision. Estimated cost: ~$0.50-$2 in model spend per worker+verifier cycle on a trivial card.
