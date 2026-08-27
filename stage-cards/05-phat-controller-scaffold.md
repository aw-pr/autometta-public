<!--
Stage card 05: phat-controller scaffold. Authored by copying templates/stage-card.md and filling in placeholders. -->

# Stage card 05: phat-controller scaffold (scripts)

## Metadata

- **Authored:** 2026-05-21
- **Orchestrator:** Claude Opus 4.7 (main session)
- **Worker:** Codex GPT-5.3 (`codex exec --sandbox workspace-write`, stdin from /dev/null)
- **Verifier:** Claude Sonnet 4.6 (Task sub-agent)
- **Pairing rationale:** Pairing rotates from stage 4 (Opus worker / Codex verifier). Codex worker is the right tier for shell-script implementation work (T2 specified, with `docs/phat-controller.md` as the brief). Sonnet verifier cross-checks via structural and `bash -n` validation.

## Objective

Produce the four shell scripts that implement the phat-controller pass-2 layer as designed in `docs/phat-controller.md`. Scripts only; `examples/kimble-phase-tasks/` is descoped from this stage and deferred to a future stage.

The scripts are not executed in this stage. Stage 6 (deferred to the user) runs them. Stage 5 is implementation + static validation only.

## Inputs (read these in your own context)

- `docs/phat-controller.md`
- `schemas/state.yaml.json`
- `schemas/budget.json`
- `docs/dispatch-contract.md`
- `memory/INDEX.md` and the seven `memory/decision-*.md` entries it points to
- `templates/worker-prompt.md`
- `templates/stage-card.md`

Do not read anything else; keep your context lean.

## Deliverables

All paths relative to repo root. All four scripts must be created.

1. `scripts/budget.sh`: helper that reads and updates `state/budget.json` atomically. Functions provided (as bash functions sourced by the others): `budget_check_caps <repo-root>` (exits non-zero if any cap is exhausted), `budget_increment_tick <repo-root>` (increments `clock_ticks_used`, writes via temp+rename), `budget_record_failure <repo-root>` (increments `consecutive_failures`), `budget_reset_failures <repo-root>` (sets `consecutive_failures` to 0), `budget_halt <repo-root> <reason>` (sets `halted: true`, `halt_reason`, `halted_at`). All reads and writes via `jq`. Must validate against `schemas/budget.json` after every write (use `python3 -c "import json,sys; json.load(open(sys.argv[1]))"` or similar for a JSON well-formed check; full JSON Schema validation may be deferred to a stage-5 helper or assumed if `jsonschema` CLI is present).
2. `scripts/spawn-worker.sh`: helper invoked by `tick.sh` to dispatch one worker per a named stage card. Reads the card path, the worker identity (from the card's metadata), and the family. Builds the worker prompt by filling in `templates/worker-prompt.md`. Dispatches the worker headless (e.g. `codex exec --sandbox workspace-write` for Codex; `claude -p` for Claude Code). Writes the worker's PID to `state/state.yaml` (via a small helper that wraps the yaml write; you may shell out to `yq` if available, or write a minimal yaml-line replacement using `sed` for the specific fields). Logs to `state/logs/<stage-id>-worker.log`. Returns the PID on success; non-zero on dispatch failure.
3. `scripts/spawn-verifier.sh`: same shape as `spawn-worker.sh`, dispatches the verifier. Verifier sandbox is read-only (`codex exec --sandbox read-only` or equivalent). Writes the verifier's PID and output path (`state/verifiers/<stage-id>.json`) to `state.yaml`. Logs to `state/logs/<stage-id>-verifier.log`.
4. `scripts/tick.sh`: the cron entry point. Iterates over `${PHAT_CONTROLLER_HOME:-$HOME/.phat-controller}/subscribers/*.yaml`, sorted by `weight` field. For each enabled subscriber: cds to its `repo_path`, runs the one-transition logic from `docs/phat-controller.md` section (a). The transition logic must: (i) call `budget.sh budget_check_caps`; (ii) read `state/state.yaml`; (iii) if a stage is `in_progress`, check whether its worker has produced its expected output and either dispatch the verifier or mark stalled; (iv) if no stage is `in_progress`, claim the next `pending` stage and call `spawn-worker.sh`; (v) write back to `state/state.yaml` atomically; (vi) commit on the `phat-controller/state` branch. Supports a `--repair` flag that runs reconciliation without dispatching.

## Constraints

- **Language:** Bash. First line of every script is `#!/usr/bin/env bash`. Second line is `set -euo pipefail`. Third line is `IFS=$'\n\t'`. No exceptions.
- **No external dependencies beyond:** `bash` 4+, `jq`, `git`, `codex`, `claude`, `python3` (for JSON well-formedness if needed). `yq` may be used if present but the scripts must degrade gracefully (detect-and-warn, don't crash) if it is not. No Docker, no new package managers.
- **Style:** British English in comments, no em dashes anywhere in any script. No AI-tell vocabulary in comments (`delve`, `leverage`, `seamless`, `robust`, `comprehensive`, `tapestry`, `elegant`).
- **No execution.** The scripts must not be invoked as part of this stage. They are inspected statically.
- **Headless gotcha 1 mitigation:** every CLI dispatch within the scripts (codex, claude, etc.) must redirect stdin from `/dev/null` and use the family's non-interactive flag set.
- **Headless gotcha 3 mitigation:** log paths are stated explicitly; do not rely on harness-generated paths.
- **Stage card exemption:** the stage card at `examples/self-host/05-phat-controller-scaffold.md` is the orchestrator's audit-trail artefact and exempt from the "no files outside deliverables" criterion. The same exemption applies to any new `memory/decision-*.md` file banked under the anchored-decisions rule for this stage, and to `examples/self-host/PLAN.md` updates that record stage progress.

## Acceptance criteria

The verifier checks each independently.

1. **Four files exist** at the named paths and are non-empty.
2. **Shebang and bash safety on each script:** line 1 is `#!/usr/bin/env bash`; line 2 is `set -euo pipefail`; line 3 is `IFS=$'\n\t'`. Verifier checks the first three lines of each file.
3. **`bash -n` clean:** every script parses without error under `bash -n <path>`. The verifier runs `bash -n` on each.
4. **Required functions / entry points present.** `scripts/budget.sh` defines functions named `budget_check_caps`, `budget_increment_tick`, `budget_record_failure`, `budget_reset_failures`, `budget_halt`. `scripts/spawn-worker.sh` and `scripts/spawn-verifier.sh` are invocable as `./script <stage-card-path> <repo-root>`. `scripts/tick.sh` is invocable as `./tick.sh` with no arguments (reads from `$PHAT_CONTROLLER_HOME`). The verifier checks via `grep` for function definitions and the `--repair` flag handling in tick.sh.
5. **Stdin redirect in every CLI dispatch:** every invocation of `codex` or `claude` or similar inside the scripts is followed by `</dev/null` (or precedes it via shell variable construction). The verifier greps for any `codex exec` or `claude -p` not adjacent to a `</dev/null`.
6. **Style audit:** `grep -c '-' scripts/*.sh` returns 0. Banned-vocabulary scan returns no matches.
7. **No files outside the deliverables set are modified by the worker.** Deliverables set: the four scripts. The stage card, any new memory entries banked, and `examples/self-host/PLAN.md` are all exempt per the constraints section above.

## Out of scope

- Execution. Nothing in this stage runs the scripts.
- `examples/kimble-phase-tasks/` (descoped, deferred).
- Edits to `README.md`, `CLAUDE.md`, `AGENTS.md`, `docs/philosophy.md`, `~/.claude/*`.
- Edits to `docs/phat-controller.md`, the schemas, or any other already-committed pass-2 artefact.
- Implementing full JSON Schema validation in bash; well-formedness checks are sufficient.
- Implementing the `--repair` reconciliation logic in full; an entry point stub that logs "repair not yet implemented, no-op" is acceptable. The commitment is the entry point.

## Budget

- **Worker wall-clock:** 18 minutes (four scripts, mostly mechanical, single Codex worker writing them sequentially).
- **Verifier wall-clock:** 8 minutes (`bash -n` plus grep checks).

## Verifier handoff

When all four scripts are written, the orchestrator runs the pre-verifier gate: `bash -n scripts/*.sh`, style scan, and stdin-redirect grep. If any pre-check fails, the worker is re-briefed once with the offending lines. The verifier then runs the structural checks listed in criteria 4, 5, 7 plus a fresh `bash -n` to confirm.

## Family-specific notes

- Codex worker: `codex exec --sandbox workspace-write "<prompt>" </dev/null > /tmp/codex-stage-05.log 2>&1`. Sandbox is workspace-write because the worker needs to create new files under `scripts/`. Stdin redirect mitigates gotcha 1.
- Claude Sonnet verifier: Task sub-agent, model `sonnet`. The verifier may invoke `bash -n` via the Bash tool to actually parse the scripts. This is structural validation, not execution.
