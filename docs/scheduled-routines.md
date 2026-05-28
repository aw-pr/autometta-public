# Scheduled monitoring routines

Operator runbook for the three repo-health monitoring routines. Register each via `/schedule` in a Claude Code session open to the autometta repo. Before registering, read `docs/remote-monitoring.md` for the hard constraints every routine must respect.

## Prerequisites

- `gh` authenticated to `origin` (the private remote at `tw-one/autometta`).
- The repo is visible to the hosted routine via `gh` / git HTTPS.
- For the brew check: Homebrew installed in the hosted environment, or accepted as a local-only smoke test.

## Routine 1: public mirror health (every 6 hours)

Checks that `origin/publish` and `public/main` are not diverged.

```
/schedule "Every 6 hours, run scripts/monitoring/check-public-mirror.sh from the autometta repo root. If it exits 0, do nothing. If it exits non-zero, open a PR on origin/dev with the label 'monitoring:' and title 'monitoring: public mirror divergence detected', body containing the script output. If an open PR with that title already exists, update its body instead of opening a new one. Never merge the PR. Never touch state/, state.yaml, or run autometta tick."
```

Cadence: `0 */6 * * *` (every 6 hours).

Expected outputs:
- `OK: mirror in sync` — no action.
- `OK: public/main is N commits behind origin/publish` — no action (normal lag).
- `ERROR: divergence detected` — PR filed on `origin/dev`.

## Routine 2: brew install smoke test (daily)

Checks that `scripts/install-homebrew-local.sh` succeeds and that `autometta --version` matches HEAD.

```
/schedule "Once daily, run scripts/monitoring/check-brew-install.sh from the autometta repo root. If it exits 0, do nothing. If it exits non-zero, open a PR on origin/dev with the label 'monitoring:' and title 'monitoring: brew install smoke test failed', body containing the script output. If an open PR with that title already exists, update its body instead of opening a new one. Never merge the PR. Never touch state/, state.yaml, or run autometta tick."
```

Cadence: `0 6 * * *` (daily at 06:00 UTC).

Expected outputs:
- `PASS: brew install smoke test complete` — no action.
- `ERROR: version mismatch` or `ERROR: brew not on PATH` — PR filed on `origin/dev`.

## Routine 3: upstream skill drift (weekly)

Checks that the `agent-orchestrator` skill in the repo matches the copy loaded into the Claude Code harness.

```
/schedule "Once weekly on Monday, run scripts/monitoring/check-upstream-skills.sh from the autometta repo root. If it exits 0, do nothing (including if the output contains NOTICE — a symlink degeneracy is expected locally). If it exits non-zero, open a PR on origin/dev with the label 'monitoring:' and title 'monitoring: agent-orchestrator skill drift detected', body containing the script output. If an open PR with that title already exists, update its body instead of opening a new one. Never merge the PR. Never touch state/, state.yaml, or run autometta tick."
```

Cadence: `0 8 * * 1` (Mondays at 08:00 UTC).

Expected outputs:
- `OK: agent-orchestrator skill is in sync` — no action.
- `NOTICE: ... symlink ...` — no action (local degeneracy is expected).
- `DRIFT: ...` + `ERROR: N drift(s) detected` — PR filed on `origin/dev`.

## Triage

All monitoring PRs carry the `monitoring:` label. Filter by that label in GitHub to see active findings. The PR body includes the full script output and the "no state mutation occurred" operator checkbox. Tick the checkbox before merging (or closing as expected behaviour).

If a monitoring routine itself fails (script error, model error), it files a GitHub issue rather than a PR. Issues follow the same label convention.

## Deregistering

```
/schedule list
/schedule delete <routine-id>
```

Deregister a routine before removing or renaming its script. A stale routine that cannot find its script will file an error issue on every run.
