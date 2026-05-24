<!--
Stage card 05b: phat-controller init scripts. Authored by copying templates/stage-card.md and filling in placeholders. -->

# Stage card 05b: phat-controller init scripts

## Metadata

- **Authored:** 2026-05-22
- **Orchestrator:** Claude Opus 4.7 (main session)
- **Worker:** Codex GPT-5.3 (`codex exec --sandbox workspace-write`, stdin from /dev/null)
- **Verifier:** Claude Sonnet 4.6 (Task sub-agent)
- **Pairing rationale:** Worker stays as Codex because shell-script implementation is its strongest tier and stage 5 demonstrated the discipline (style-clean first pass, self-correction mid-write, ~6 min wall-clock). The cross-family verification belief still holds via the Sonnet verifier; the same-family-worker constraint is only required for the verifier side per `memory/project-cross-family-verification-validated.md`. The pairing is pragmatic, not symmetric.

## Objective

Produce the init scripts that make autometta actually usable on a fresh machine and in a fresh subscribed repo. Stage 5 wrote the runtime scripts; stage 5b makes the runtime invokable. Both stages together (plus stage 5a hardening) are the prerequisite for stage 6.

Publish-guard initialisation is explicitly out of scope; the user has an existing `repo-publish-guard-init` skill that handles it.

## Inputs (read these in your own context)

- `docs/phat-controller.md`
- `schemas/state.yaml.json`
- `schemas/budget.json`
- `scripts/tick.sh` (consumes the state files this stage initialises)
- `scripts/budget.sh` (consumes budget.json)
- `memory/decision-state-dir-per-repo.md`
- `memory/decision-phat-controller-no-daemon-subscriber-registry.md`
- `memory/decision-tick-implementation-parameters.md`
- `templates/stage-card.md`

Do not read anything else; keep your context lean.

## Deliverables

All paths relative to repo root. All four files must be created.

1. `scripts/check-deps.sh`: dependency probe. Verifies presence of: `bash` 4+, `jq`, `git`, `codex`, `claude`, `python3`. Verifies optional: `yq` (warn, do not fail, if absent). Emits one line per dependency in `PASS|MISSING|WARN <name> [reason]` format. Exits non-zero if any required dependency is missing. Invoked by `tick.sh` at startup (stage 5a will wire that call); also invocable standalone for diagnostic. No side effects beyond stdout.
2. `scripts/init-host.sh`: one-time per machine setup. Idempotent (safe to re-run). Creates `${PHAT_CONTROLLER_HOME:-$HOME/.phat-controller}` with mode `700`. Inside it creates `subscribers/`, `log/`, and writes `config.yaml` and `subscribers/template.yaml` from inline heredocs (small files; do not pull from anywhere). On re-run: detects existing dir, prints what is already in place, does not overwrite existing config or subscriber files, only creates anything missing. Exits 0 in both first-run and re-run cases. Calls `check-deps.sh` first and aborts with a clear message if a required dependency is missing.
3. `scripts/subscribe-repo.sh`: register one repo as a subscriber. Takes one positional argument: `<repo-path>` (absolute or relative; resolved to absolute via `realpath`). Idempotent. Actions: (a) verify `${repo-path}/.git` exists; (b) ensure `${PHAT_CONTROLLER_HOME}` is initialised (call `init-host.sh` if not, or warn and exit 1 if the user wants explicit control; choose the simpler path: warn and exit 1, instructing the user to run `init-host.sh` first); (c) create `${repo-path}/state/` with `verifiers/` and `logs/` subdirectories; (d) write initial `state/state.yaml` and `state/budget.json` using defaults that validate against the schemas (token_cap_total: 1000000, wall_clock_cap_seconds: 3600, clock_tick_cap: 100, consecutive_failure_cap: 3); (e) append `state/logs/` to the repo's `.gitignore` if not already present; (f) drop `${PHAT_CONTROLLER_HOME}/subscribers/<repo-slug>.yaml` (slug derived from basename of repo-path) listing `repo_path`, `weight: 100`, `enabled: true`. On re-run with an already-subscribed repo: detect, print state, do not overwrite, exit 0. Defaults are conservative; stage 5a or operator can tune later.
4. `docs/setup.md`: operator-facing setup guide. Sections: (i) prerequisites (the dependency list, with install hints for macOS Homebrew where appropriate), (ii) one-time machine setup (`scripts/init-host.sh`), (iii) per-repo subscription (`scripts/subscribe-repo.sh <path>`), (iv) cron scheduling (a sample `crontab` line and a note that launchd is the macOS-native alternative; do not install either, just document), (v) verifying the install (sample commands to confirm everything is in place), (vi) reference to the existing `repo-publish-guard-init` skill as a separate operator step not covered here, (vii) uninstall: how to remove a subscriber file and how to clean up `~/.phat-controller/`.

## Constraints

- **Language for shell scripts:** Bash. First three lines exactly: `#!/usr/bin/env bash`, `set -euo pipefail`, `IFS=$'\n\t'`. Same shebang+safety as stage 5.
- **No external dependencies beyond stage 5's list.** `bash` 4+, `jq`, `git`, `codex`, `claude`, `python3` (required); `yq` (optional). `realpath` is on macOS via coreutils Homebrew; if absent, fall back to `python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))"`.
- **Style:** British English. No em dashes. No AI-tell vocabulary (`delve`, `leverage`, `seamless`, `robust`, `comprehensive`, `tapestry`, `elegant`).
- **No execution.** Do not run `init-host.sh` or `subscribe-repo.sh` as part of this stage. Static validation only.
- **Idempotency is hard-required.** Both `init-host.sh` and `subscribe-repo.sh` must be safe to re-run without producing duplicate state, overwritten configs, or duplicated `.gitignore` lines.
- **Initial state files validate against the schemas.** The `state.yaml` and `budget.json` that `subscribe-repo.sh` writes must conform to `schemas/state.yaml.json` and `schemas/budget.json`. The worker should mentally cross-check (or write a `python3 -c` jsonschema check) before declaring done.
- **No code in `docs/setup.md`.** Prose plus fenced shell-command blocks. The blocks are runnable commands the operator will type; they are not executable code in the script sense.
- **Stage card exemption.** The stage card at `examples/self-host/05b-phat-controller-init.md` is exempt from criterion 7. The same exemption applies to any new `memory/decision-*.md` banked under the anchored-decisions rule, to `examples/self-host/PLAN.md` updates, and to `.gitignore` if the worker discovers it needs an update for repo-side runtime artefacts (e.g. adding `state/logs/` to the autometta repo's own `.gitignore`).

## Acceptance criteria

The verifier checks each independently.

1. **Four files exist** at the named paths and are non-empty.
2. **Shell scripts shebang + safety:** lines 1-3 of each shell script are exactly `#!/usr/bin/env bash`, `set -euo pipefail`, `IFS=$'\n\t'`. `docs/setup.md` is markdown; this criterion does not apply to it.
3. **`bash -n` clean on every shell script.**
4. **Idempotency claim (static).** Both `init-host.sh` and `subscribe-repo.sh` contain explicit existence checks before mutating state. The verifier greps for `[[ -d` or `[[ -f` or `mkdir -p` (the safe variants) and confirms no unconditional overwrite of files inside `${PHAT_CONTROLLER_HOME}` or the subscribed repo's `state/`.
5. **check-deps.sh probes the full required set.** The verifier greps for the names: `bash`, `jq`, `git`, `codex`, `claude`, `python3`. All six must appear in the script. `yq` must also appear, marked optional.
6. **Style audit:** `grep -c '-' scripts/check-deps.sh scripts/init-host.sh scripts/subscribe-repo.sh docs/setup.md` returns 0 for all four files. Banned-vocabulary scan returns no matches.
7. **No files outside the deliverables set are modified by the worker** (stage card, new memory entries banked under the anchored-decisions rule, `examples/self-host/PLAN.md`, and `.gitignore` updates are all exempt per the constraints section above).

## Out of scope

- Execution of any init script.
- Stage 5a hardening (separate stage, separate card).
- Publish-guard setup (the user runs the existing `repo-publish-guard-init` skill).
- Cron / launchd installation. `docs/setup.md` documents the recipe but the scripts do not install scheduled jobs.
- Multi-machine federation, web UI, or any pass-2 future-scope item.
- Stage 6 (the live run).

## Budget

- **Worker wall-clock:** 15 minutes. Four files including one prose doc. Should comfortably fit.
- **Verifier wall-clock:** 7 minutes. Structural checks plus a fresh `bash -n` per script plus a careful read of `setup.md`.

## Verifier handoff

When all four files are written, the orchestrator runs the pre-verifier gate: `bash -n` on each shell script, style scan across all four files, idempotency-pattern grep, dependency-name presence grep. If any pre-check fails, the worker is re-briefed once with the offending lines pasted in. The verifier then runs the structural checks listed in criteria 4 through 7 plus a fresh `bash -n` to confirm.

The verifier should also do a qualitative read of `docs/setup.md` to confirm the seven sections (i) through (vii) are present, even though no acceptance criterion explicitly checks section completeness for the prose doc; flag any missing section under "Additional findings" rather than as a criterion failure.

## Family-specific notes

- Codex worker: `codex exec --sandbox workspace-write "<prompt>" </dev/null > /tmp/codex-stage-05b.log 2>&1`. Workspace-write because the worker needs to create new files under `scripts/` and `docs/`. Stdin redirect mitigates gotcha 1.
- Claude Sonnet verifier: Task sub-agent, model `sonnet`. The verifier may invoke `bash -n` via the Bash tool to actually parse the scripts. This is structural validation, not execution.

## Template defects noticed (filled in during this dogfooding pass)

- The template's "Family-specific notes" placeholder still collapses harness mechanics with family-specific lessons. Same observation as stage 4. Not amended yet; deferred to a future template-amendment stage.
- The "Verifier handoff" section in the template assumes the worker returns a summary on completion. For a Codex worker invocation via `codex exec`, the "summary" is the tail of the log file. The template wording reads naturally enough that no amendment is needed yet.
- No other defects noticed.
