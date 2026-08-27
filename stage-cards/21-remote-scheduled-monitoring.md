# Stage card 21-remote-scheduled-monitoring: Hosted scheduled agents for repo health monitoring (PR-only output, no dispatch authority)

## Metadata

- **Authored:** 2026-05-27
- **Orchestrator:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Worker:** Codex GPT-5.3 <codex-gpt-5-3@local>
- **Verifier:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Pairing rationale:** Cross-family. Codex writes the routine specs and PR shape; Claude verifies the routines respect the "no state mutation" constraint and never touch `state.yaml` or trigger ticks.
- **Type:** Implementation, but the implementation is small. Most of the surface is contract: what hosted agents may and may not do.

## Surfacing concern

The autometta loop is local-machine. It does not see whether the public mirror is healthy, whether `brew install` from a fresh machine works, whether upstream skills (`auth-route-security`, `agent-orchestrator`) have moved in incompatible ways, or whether scheduled routines elsewhere are silently failing. Hosted scheduled agents (the `schedule` skill / Claude Code routines) can poll these surfaces cheaply and surface only the interesting deltas. The hard constraint: they must never *act* on the loop — only file PRs or issues on the private remote.

## Objective

Define three scheduled routines (one per health surface), wire them via the `schedule` skill, and codify the "monitoring agents file PRs, they do not dispatch" contract in `docs/remote-monitoring.md`. PRs land on `origin/dev` with a `monitoring:` label; the operator decides whether to merge.

## Inputs

- `docs/PUBLISH-WORKFLOW.md` — what the public mirror is and how it's pushed.
- `scripts/install-homebrew-local.sh` — the brew install path one routine will smoke-test.
- `skills/agent-orchestrator/SKILL.md` — to see what upstream change would matter.
- `.github/workflows/*.yaml` if present, otherwise the absence is the answer (no CI today).
- The user's `schedule` skill (built into Claude Code).

## Deliverables

1. `docs/remote-monitoring.md` — the contract. What hosted agents may read; that they must never write to `state.yaml`, `state/`, or run `autometta tick`; that their output is always a draft PR or an issue on `origin/dev`; their cadence.
2. `scripts/monitoring/check-public-mirror.sh` — the script the "public mirror health" routine runs. Compares `origin/publish` HEAD to `public/main` HEAD, fails if they diverge unexpectedly.
3. `scripts/monitoring/check-brew-install.sh` — the script the "brew install fresh-machine" routine runs in a clean tmpdir. Confirms `scripts/install-homebrew-local.sh` succeeds end-to-end.
4. `scripts/monitoring/check-upstream-skills.sh` — the script the "upstream skill drift" routine runs. Compares `mtime` / hash of the `agent-orchestrator` skill in this repo vs `~/.claude/skills/agent-orchestrator/` (which is a symlink, so the comparison is degenerate locally — hosted, this becomes a real check against a fixed-revision snapshot).
5. `docs/scheduled-routines.md` — operator runbook. How to register each routine via `/schedule`, what cadence, how to interpret the PRs they file.
6. `memory/decision-remote-monitoring.md` — decision memo. Why hosted (cron-style schedule beyond the laptop's reach), why PR-only (no dispatch authority), why three routines for v1 (each is a separately-failing surface).
7. `.github/PULL_REQUEST_TEMPLATE/monitoring.md` (or equivalent) — minimal PR template the routines use, so the operator can triage in a glance.

## Constraints

- Routines have read-only access to the repo via `gh` / git over HTTPS. They do not have credentials for `op`, `op-fetch`, or 1Password — local-only credentials.
- Routines must never invoke `autometta tick`, modify `state.yaml`, or write under `state/`. Enforced by contract (and by routine prompts), not by sandboxing.
- Each routine's output is at most one PR per run. Repeated identical findings update the existing PR rather than spawning new ones.
- A failed routine (script exit non-zero or model error) files a GitHub issue with the `monitoring:` label, not a PR.
- No new dependencies in the local repo beyond bash and `gh` (already required).
- Routines do not auto-merge.

## Acceptance criteria

1. `scripts/monitoring/check-public-mirror.sh` exits 0 when `origin/publish` and `public/main` match, non-zero with a clear message when they diverge. Tested by faking a divergence (e.g. `git update-ref refs/remotes/public/main HEAD~1`) and restoring after.
2. `scripts/monitoring/check-brew-install.sh` runs the brew install into a temp Cellar, confirms `autometta --version` matches the current HEAD short SHA, and cleans up after. Exit 0 on pass.
3. `scripts/monitoring/check-upstream-skills.sh` runs locally and reports the symlink degeneracy as a notice (not a fail) so the routine knows the check is hosted-only meaningful.
4. `docs/remote-monitoring.md` enumerates the four hard constraints from this card's Constraints section.
5. `docs/scheduled-routines.md` includes the exact `/schedule` invocation lines for each of the three routines, including cadence (mirror: every 6h; brew: daily; skills: weekly).
6. The PR template under `.github/` includes a "no state mutation occurred" checkbox the operator ticks before merging.
7. `memory/decision-remote-monitoring.md` links to `[[decision-publish-workflow]]` if present, otherwise to `[[decision-handoff-envelope]]`.
8. None of the three scripts read or write under `state/` (grep guard in CI is not in scope; manual inspection is enough).

## Out of scope

- Setting up the actual scheduled routines (the operator runs `/schedule` themselves; the card produces the scripts and runbook).
- A monitoring dashboard. PRs on `origin/dev` are the dashboard.
- Cross-repo monitoring (monitoring routines for `emergence-lab`, `fractals-from-the-90s`). Add per-repo cards later if needed.
- Routines that take corrective action. v1 is read-only.

## Budget

- **Worker wall-clock:** 60 minutes.
- **Verifier wall-clock:** 25 minutes.

## Verifier handoff

Worker writes the deliverables, runs each of the three scripts and pastes exit code + output in completion message. Worker writes `state/handoffs/21-remote-scheduled-monitoring.json`. Verifier reads the card and deliverables, greps the three scripts for any reference to `state/` or `tick.sh` (must find none other than the documented runbook examples), and writes `state/verifiers/21-remote-scheduled-monitoring.json`.

## Family-specific notes

- **Codex (worker):** stdin redirect on any subprocess. Sandbox `workspace-write` is sufficient; the brew install smoke test runs into a temp prefix and does not need elevated permissions.
- **Claude (verifier):** standard cross-family verification.
