<!--
Stage card 06: first real dispatch test. Trivial deliverable, real spend. Validates pass-1 end to end after stage 5c hardening. Pre-flight per the new templates/orchestrator-checklist.md Section 0. -->

# Stage card 06-real-dispatch-test: scripts/health-check.sh

## Metadata

- **Authored:** 2026-05-22
- **Orchestrator:** Claude Opus 4.7 (autometta session)
- **Worker:** Codex GPT-5.3 (`codex exec --sandbox workspace-write`)
- **Verifier:** Claude Sonnet 4.6 (Task sub-agent)
- **Pairing rationale:** Same shell-script + Codex worker / Sonnet verifier pattern that landed 5a, 5b, and 5c cleanly. Cross-family per `memory/project-cross-family-verification-validated.md`. This card is deliberately small: the goal is to validate the full loop with real spend, not to ship a load-bearing artefact.

## Objective

Add a small `scripts/health-check.sh` helper that runs `bash -n` across every shell script under `scripts/` and reports the result. This is the kind of pre-flight an operator would run before dispatching a worker. Exit 0 on all-clean, exit 1 on first failure with a line identifying the offending script.

## Inputs (read these in your own context)

- `scripts/tick.sh`
- `scripts/check-deps.sh`
- `docs/setup.md`

Read these for shell-script style and existing helper conventions. Do not read anything else.

## Deliverables

All paths relative to repo root.

1. `scripts/health-check.sh`: new file. Iterates `scripts/*.sh` (excluding itself), runs `bash -n` on each, prints `ok: <path>` on success and `fail: <path>` plus the bash error on failure. Exits 0 only if every script passes. Exits 1 on first failure. First three lines are exactly `#!/usr/bin/env bash`, `set -euo pipefail`, `IFS=$'\n\t'` matching the rest of the script suite.

## Constraints

- **Shell discipline:** first three lines exactly as named above. `bash -n` clean on the new script. Use `printf`, not `echo -e`. No bash 4-isms (`bash 3.2+` compatibility per `scripts/check-deps.sh`).
- **No external dependencies.** Existing dep set only (`bash`, `git`). No `jq`, `yq`, `python3` in this script.
- **Style:** British English in comments, no em dashes, no AI-tell vocabulary (`delve`, `tapestry`, `robust`, `leverage`, `seamless`, `comprehensive`, `holistic`, `cutting-edge`, `streamline`, `crucial`).
- **Idempotency:** running the script twice in a row produces identical output. No side effects (no file writes, no temp files, no state mutation).
- **Self-exclusion:** the script must not run `bash -n` on itself in a way that creates a circular dependency on its own readiness. Either skip the script's own path during iteration or rely on the fact that bash already parsed it to start.
- **No execution.** Static validation only. The worker writes the script and verifies its own `bash -n` cleanness; nothing in this stage runs the script end to end on the repo.
- **Stage card exemption.** This card at `examples/self-host/06-real-dispatch-test.md` is exempt from criterion 6. `examples/self-host/PLAN.md` updates are exempt.

## Acceptance criteria

The verifier checks each independently.

1. **File exists** at `scripts/health-check.sh` and is non-empty.
2. **First three lines** are exactly `#!/usr/bin/env bash`, `set -euo pipefail`, `IFS=$'\n\t'`.
3. **`bash -n scripts/health-check.sh`** returns 0.
4. **Iterates `scripts/*.sh`**: greppable evidence that the script iterates the scripts directory (e.g. `for f in scripts/*.sh`, `find scripts -maxdepth 1 -name '*.sh'`, or equivalent).
5. **Calls `bash -n`** somewhere in the script body. Single grep for `bash -n` returns at least one hit.
6. **No files outside the deliverables set are modified.** Exemptions: this stage card itself; `examples/self-host/PLAN.md` (orchestrator metadata).
7. **Style audit:** `grep -c '-' scripts/health-check.sh` returns 0. Case-insensitive grep for the banned vocabulary list returns 0.
8. **No external dependencies** in the script body. `grep -E 'jq|yq|python3' scripts/health-check.sh` returns 0.

## Out of scope

- Execution of `scripts/health-check.sh` against the repo. Static checks only.
- Edits to any existing script under `scripts/`.
- A `docs/` entry describing the new helper. The script's behaviour should be self-evident from a `--help` or a header comment.
- A test suite. The script is a one-off helper; the dispatch contract itself is the test.

## Budget

- **Worker wall-clock:** 8 minutes (one small script, no edits to existing files).
- **Verifier wall-clock:** 4 minutes (eight greppable criteria).

## Verifier handoff

When `scripts/health-check.sh` is written, the orchestrator runs the pre-verifier gate: `bash -n` on the new script, em-dash + AI-tell scan, dependency grep, and section-by-section greppability of each criterion. If any pre-check fails the worker is re-briefed once. The verifier then writes a JSON report to `state/verifiers/06-real-dispatch-test.json` checking each acceptance criterion independently.

## Family-specific notes

- Codex worker: `codex exec --sandbox workspace-write "<prompt>" </dev/null > /tmp/06-real-dispatch-test-worker.log 2>&1 &`. Stdin redirect mitigates the stdin gotcha.
- Claude Sonnet verifier: Task sub-agent, model sonnet. May invoke `bash -n` via the Bash tool.

## Notes for next session

This card's purpose is loop validation, not feature work. After it lands, the next operator decision is whether to wire phat-controller's `tick.sh` into a cron entry (per `docs/setup.md` section 4) to start running cards autonomously, or to continue with human-driven pass-1 dispatch on a per-card basis. The hardening from 5c should make either route safe.
