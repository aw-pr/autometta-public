# Remote monitoring

Hosted scheduled agents that watch surfaces the local autometta loop cannot see: the public mirror, the brew install pipeline, and upstream skill drift.

## What monitoring agents may do

- Read the repo via `gh` / git over HTTPS.
- Run the monitoring scripts in `scripts/monitoring/`.
- File a single PR (or update an existing one) on `origin/dev` with the `monitoring:` label when a check fails.
- File a GitHub issue with the `monitoring:` label if the script itself errors or the model call fails.

## Hard constraints

These four constraints are not advisory. They apply to every monitoring routine without exception.

1. **Read-only repo access.** Routines have no credentials for `op`, `op-fetch`, or 1Password. They access the repo exclusively via `gh` and public git over HTTPS. No local-machine secrets, no token injection.

2. **No tick invocation.** Routines must never call `autometta tick`, `scripts/tick.sh`, or any other command that advances the loop state. Monitoring is advisory; it does not drive the loop.

3. **No state mutation.** Routines must never write to `state/`, `state.yaml`, or any verifier artefact. The loop's runtime state is off-limits.

4. **One PR per run, not one per finding.** If a routine finds a problem, it opens a single PR on `origin/dev` with the `monitoring:` label. If a PR for the same check already exists and is open, the routine updates it rather than opening a second one. The operator decides whether to merge. Routines never auto-merge.

## Surfaces and scripts

| Surface | Script | Cadence |
|---|---|---|
| Public mirror health | `scripts/monitoring/check-public-mirror.sh` | Every 6 hours |
| Brew install pipeline | `scripts/monitoring/check-brew-install.sh` | Daily |
| Upstream skill drift | `scripts/monitoring/check-upstream-skills.sh` | Weekly |

### Public mirror health

Compares `origin/publish` HEAD to `public/main` HEAD. A clean lag (public/main is an ancestor of origin/publish) is normal and exits 0. A divergence (public/main has commits not reachable from origin/publish) exits 1 and triggers a PR. The script fetches both remotes before comparing; a stale local ref is not evidence of divergence.

### Brew install pipeline

Runs `scripts/install-homebrew-local.sh` and asserts that `autometta --version` reports the same short SHA as `git rev-parse --short HEAD`. Cleans up the versioned archive that accumulates in the tap dir on each run. This check requires Homebrew; it exits with a clear error in environments where brew is absent rather than a false pass.

### Upstream skill drift

Compares `skills/agent-orchestrator/SKILL.md` and `REFERENCE.md` in the repo against the copy at `~/.claude/skills/agent-orchestrator/`. On a local machine the harness path is typically a symlink back to the repo, so the check is degenerate and reports a NOTICE rather than OK. In a hosted environment with its own harness copy the check is real. The script never fails on a symlink; it exits 0 with a NOTICE in that case.

## Output and triage

A monitoring PR includes:
- The script name and exit code.
- Stdout from the script (truncated to 1000 characters if large).
- The operator "no state mutation occurred" checkbox.

An issue (on script error or model failure) includes:
- The script that failed.
- The error text.
- A note that the loop state was not touched.

The operator's only required action is to read, decide, and close or merge. Nothing in the loop depends on monitoring PRs being merged.
