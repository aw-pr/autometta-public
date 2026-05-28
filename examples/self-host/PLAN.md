# Self-host execution plan

This is the rolling plan for autometta building itself with itself. Each stage produces an artefact AND adopts it for the next stage. The plan lives in-repo so any agent picking up a fresh session sees the same state. Status is the ground truth; the task list at the harness level shadows this file, not the other way round.

## Status, 2026-05-26

| # | Stage | Status | Commit | Card |
|---|---|---|---|---|
| 0 | Bootstrap dispatch contract templates | done | `011b640` | [`00-bootstrap.md`](./00-bootstrap.md) |
|   | Memory: stage-0 lessons | done | `c162708` | (orchestrator-authored, no card) |
| 1 | Lessons + verification docs | done | `d2e2729` | [`01-lessons-and-verification.md`](./01-lessons-and-verification.md) |
| 2 | Fractals stage cards as examples | done | `b4277dd` | [`02-fractals-examples.md`](./02-fractals-examples.md) |
| 3 | Memory bootstrap from `<ALW>` tags | done | `e6d0d60` | [`03-memory-bootstrap.md`](./03-memory-bootstrap.md) |
| 4 | phat-controller design + schemas | done | `6e7f1a6` | [`04-phat-controller-design.md`](./04-phat-controller-design.md) |
| 5 | phat-controller scaffold (scripts only; kimble-phase-tasks deferred) | done | `c51fb75` | [`05-phat-controller-scaffold.md`](./05-phat-controller-scaffold.md) |
| 5a | phat-controller hardening (yq guard, dirty-tree guard, elapsed-stall) | done | `2ca686f` | [`05a-phat-controller-hardening.md`](./05a-phat-controller-hardening.md) |
| 5b | phat-controller init (check-deps, init-host, subscribe-repo, setup.md) | done | `adc75d4` | [`05b-phat-controller-init.md`](./05b-phat-controller-init.md) |
| 6 (dry) | Self-host dry run: caught 8 issues end-to-end before any spend; pass-1 contract proven, pass-2 loop has design gaps | done | `8de6a54`, `29390ad`, `3c0a20d`, `90e9572`, `ee5a9f6`, `cbe6e41` | (no card; informal dry run) |
| 5c | phat-controller hardening round 2: verifier prompt template, kill -0 guards, branch save/restore, add-stage helper, --reset-halt | done | `8a3e60c` | [`05c-phat-controller-hardening-2.md`](./05c-phat-controller-hardening-2.md) |
| 5d | autometta-setup skill (sibling to agent-orchestrator) for adopting autometta in other repos | done | `8837a7d` | (no card; small skill authored directly by Opus orchestrator) |
| 6 | Self-host real dispatch test (scripts/health-check.sh) | done | `19bf097` | [`06-real-dispatch-test.md`](./06-real-dispatch-test.md) |
|   | CLI install, manifest adoption, passive observability cockpit | done | `0431a4c`, `4bffcc0`, `31e865e` | (operator-authored improvement pass, no card) |
| 7 | Orchestrator commits worker output on verifier PASS (worker no longer commits; `verifier_failed` status added) | done | `3df462c`, `93e0709`, `bc0650b` | [`07-orchestrator-commits-not-workers.md`](./07-orchestrator-commits-not-workers.md) |
| 8 | `autometta --version` reads pinned VERSION file with `git rev-parse` fallback (no more stale upstream ref) | done | `a6063b5` | [`08-version-string-from-cellar.md`](./08-version-string-from-cellar.md) |
| 9 | Preserve original `halt_reason` and name the cap that fired (stop overwriting on already-halted ticks) | done | `70e4b75` | [`09-budget-cap-halt-misattribution.md`](./09-budget-cap-halt-misattribution.md) |
| 10 | Parse and accumulate worker/verifier token usage into `budget.json` | done | `2fac950` | [`10-token-usage-tracking.md`](./10-token-usage-tracking.md) |
| 11 | Cost dashboard: per-stage token snapshotting in `tick.sh`, aggregator emits `data.json`, static HTML/CSS/JS renderer with four canvases, Chart.js 4.4.0 pinned vendor, `autometta dashboard` subcommand, `docs/dashboard.md` | done | `1096581`, `e63745d`, `60f1226`, `eecb02a`, `2d4747b`, `6f87171` | [`11-cost-dashboard.md`](./11-cost-dashboard.md) |
| 12 | Per-repo macOS LaunchAgent heartbeat replacing global cron while preserving non-macOS cron fallback | done | `d5a13a1` | [`12-launchagent-heartbeat.md`](./12-launchagent-heartbeat.md) |
| 13 | Per-agent liveness registry, heartbeat watchdog, tmux agent ticker (third pane) — catches silent agent deaths | done | `5a62d9c` | [`13-agent-observability.md`](./13-agent-observability.md) |
|   | Polling primitive `scripts/watch-agent.sh` + heartbeat claude-family asymmetry fix + agent-doc sync | done | `b91aa20`, `6cc26e0`, `0dc571b` | (follow-ups to card 13) |
| 14 | Per-family auth route toggle (subscription default, API opt-in) via the canonical `op-fetch` wrapper from the auth-route-security skill; `autometta auth status` / `check` | done | `9cd4f6f` | [`14-auth-route-toggle.md`](./14-auth-route-toggle.md) |
|   | Follow-ups: artefact-check ordering + bash-3.2 regex; installer exec-bit restoration | done | `f6bf91d`, `a1ded4f`, `4d51e77` | (no card; small remediations) |
|   | Auto-ensure `autometta-<repo>` tmux viewer each tick | done | `31e865e` | (no card; small operator improvement) |

## Stage 6 readiness

Stage 5a closed all three production-blocking issues from stage 5: yq presence guard with halt_reason `yq-missing`, dirty-working-tree guard with halt_reason `dirty-working-tree` and a `state/`-exclusion pathspec, elapsed-time stall detection that parses the worker wall-clock budget from the stage card and applies 50% grace.

Stage 5b shipped the init story: dependency probing, the one-time machine setup of `~/.phat-controller/`, per-repo registration with idempotent state file creation, and `docs/setup.md` as the operator guide. The current operator surface is the `autometta` CLI, installed locally from the Autometta checkout.

What the user needs to do before triggering stage 6:

1. Run `scripts/install-homebrew-local.sh` from this checkout.
2. Run `autometta check-deps` to confirm the dependency set is present on the host (`bash` 3.2+, `jq`, `git`, `codex`, `claude`, `python3`, `yq`, and `agent-whoami`).
3. Run `autometta init "$PWD"` from the repo root to register this repo as a subscriber.
4. Review and commit `.gitignore`, `state/state.yaml`, and `state/budget.json` before the first tick.
5. Install a cron entry per the sample in `docs/setup.md` section 4 (or use launchd on macOS).
6. Author the first real stage card the loop should pick up (the loop reads stage cards out of the subscribed repo; cards under `examples/self-host/` are historical and complete, so a new card in another location is needed for the loop to have work to do).
7. Run the existing `repo-publish-guard-init` skill on autometta if public publication is on the horizon (see `docs/setup.md` section 6).

One known portability note for Linux (not a defect on the macOS target): host mode detection has a BSD/GNU branch, but Homebrew-local packaging remains macOS-first.

## Decisions banked in `memory/`

Each stage's surprises are committed as decision or feedback entries so the next stage starts from current knowledge. See `memory/INDEX.md` for the live index. Highlights:

- Cross-family verification caught real defects on stages 0 and 2. It is the default; same-family verification needs an explicit rationale.
- Sub-agent wall-clock budgets in the dispatch brief are advisory; the harness does not enforce them. Tighten scope per worker.
- Style constraints (em dashes, AI-tell vocabulary) need a deterministic pre-verifier scan; same-family writers are blind to their own usage.
- Acceptance criteria that check "no files outside the deliverables dir" must explicitly exempt the stage card itself; the card is the orchestrator's audit-trail artefact and lives outside by design.

## Remediation lined up for stage 4 onward

Identified during the stage-3 pause: we have been using the seven-step *protocol* but not the *template files themselves*. Stages 1 to 3 wrote their cards freehand matching the template's shape, rather than copying `templates/stage-card.md` and filling in placeholders.

From stage 4 onwards:

1. Start each card by copying `templates/stage-card.md` to the new `examples/self-host/NN-*.md` path and filling in every `<<placeholder>>`.
2. Assemble the worker prompt by filling in `templates/worker-prompt.md` to a `/tmp/autometta-stage-NN-worker-prompt.txt` file before dispatch.
3. Walk through `templates/orchestrator-checklist.md` literally before dispatch; tick the items in the stage card's metadata or in a pre-dispatch note.

If any placeholder feels awkward to fill in, treat that as a template defect and amend the template under that stage's commit (with an explicit note in the stage card and the commit message).

## Autonomy contract for unattended runs

When the orchestrator (Claude Opus 4.7 main session) is left running without a human in the loop, the following rules apply.

**Will do unattended:**

- Author stage cards, dispatch workers, run verifiers, integrate, commit to the local `dev` branch.
- Bank lessons into `memory/` whenever a stage surprises the orchestrator in a way future sessions need to know.
- Apply orchestrator overrides per dispatch-contract step 6 when a verifier flags a defect that is in the criterion text rather than the worker output; document the override in the commit message AND in a memory entry.

**Will not do unattended (surface and stop):**

- `git push` to any remote.
- Modify `README.md`, `CLAUDE.md`, `AGENTS.md`, `docs/philosophy.md`, or `~/.claude/CLAUDE.md`. These are load-bearing identity files. Edits need explicit user instruction.
- Execute code that the loop just produced. Stage 6 is deferred to the user for this reason; the orchestrator will not invoke `autometta tick` on its own backlog without explicit permission.
- Install new dependencies, add new MCP servers, or modify `~/.claude/settings.json`.
- Burn through more than two re-brief cycles on a single stage. After the second failure on the same stage, the orchestrator stops, writes a `STALLED` note into the relevant memory entry, and updates this table to `stalled` status.

**Token and wall-clock budget for the overnight run:**

- Soft cap per stage: 20 minutes wall-clock, 100k tokens worker plus 100k tokens verifier.
- Hard cap across the run: stop after stage 5 completes (or stalls), do not begin stage 6. Stage 6 needs explicit user instruction.

## What "done" looks like for the overnight run

A successful overnight run produces, by morning:

- Commits for stages 4 and 5 on `dev`.
- A populated `docs/phat-controller.md` design doc.
- `schemas/state.yaml.json` and `schemas/budget.json`.
- A working scaffold in `scripts/` with the four scripts named above.
- An updated `examples/kimble-phase-tasks/` directory (analogous to `examples/fractals-stage-cards/`).
- Possibly: amendments to `templates/*.md` if any placeholder was found awkward during dogfooding.
- Possibly: additional `memory/` entries banking new lessons.

If the run stalls or surfaces, this file is updated with the actual status, the stall reason, and a one-line next-action note. Read this file first in the morning.

## Pass 3 — cloud + SDK roadmap (queued 2026-05-27)

Pass 3 takes autometta from "local cron + filesystem + git" toward selective use of the Claude Agent SDK and hosted cloud surfaces, without breaking the load-bearing beliefs in `docs/philosophy.md`. Tier 0 is complete. Tier 1 is next.

### Tier 0 — keeps every invariant, just better tooling

| # | Stage | Status | Commit | Card |
|---|---|---|---|---|
| 15a | SDK verifier probe (minimal `verify.py` against one stage) | done | `b53d87a` | [`15a-sdk-verifier-probe.md`](./15a-sdk-verifier-probe.md) |
| 15b | Verifier rubric JSON Schema + validator script | done | `d3e35e1` | [`15b-sdk-verifier-rubric-contract.md`](./15b-sdk-verifier-rubric-contract.md) |
| 15c | SDK route in `spawn-verifier.sh` with CLI fallback | done | `7f10a70` | [`15c-sdk-verifier-integration.md`](./15c-sdk-verifier-integration.md) |
| 16 | Anthropic prompt caching on SDK verifier route | done | `b4ab7b8` | [`16-sdk-verifier-prompt-cache.md`](./16-sdk-verifier-prompt-cache.md) |
| 17 | Structured worker handoff envelope as sole completion signal | done | `fd0a6d1` | [`17-structured-worker-handoff-envelope.md`](./17-structured-worker-handoff-envelope.md) |

### Tier 1 — extends the contract, doesn't break it

| # | Stage | Status | Card |
|---|---|---|---|
| 18 | Optional N=3 panel verifier with quorum voting | queued, blocked by 15c + 17 | [`18-panel-verifier.md`](./18-panel-verifier.md) |
| 19 | Weekly batch retro-grade via Anthropic Batch API | queued, blocked by 15b + 17 | [`19-batch-retro-grade.md`](./19-batch-retro-grade.md) |
| 20 | Design: autometta-sweep skill (parallel design exploration) | queued — design-only | [`20-sweep-skill-design.md`](./20-sweep-skill-design.md) |

### Tier 2 — bends an invariant deliberately

| # | Stage | Status | Card |
|---|---|---|---|
| 21 | Hosted scheduled monitoring routines (PR-only output) | queued | [`21-remote-scheduled-monitoring.md`](./21-remote-scheduled-monitoring.md) |
| 22 | Design: MCP-served stage cards | queued — design-only | [`22-mcp-served-cards-design.md`](./22-mcp-served-cards-design.md) |
| 23 | Experiment: long-lived SDK session as alternative controller (with postmortem) | queued — bounded experiment | [`23-sdk-controller-experiment.md`](./23-sdk-controller-experiment.md) |

### Tier 3 — research bets, only after Tier 1 lands

| # | Stage | Status | Card |
|---|---|---|---|
| 24 | Design: cross-repo memory federation | queued — design-only | [`24-memory-federation-design.md`](./24-memory-federation-design.md) |
| 25 | Cost-aware router (card-declared complexity tier) | queued, blocked by 17 + 18 | [`25-cost-aware-router.md`](./25-cost-aware-router.md) |
| 26 | Design: recorded-replay verification | queued — design-only | [`26-replay-verification-design.md`](./26-replay-verification-design.md) |

### Tier 4 — SDK transport granularity + cloud (queued 2026-05-28)

| # | Stage | Status | Card |
|---|---|---|---|
| 28 | Per-role, per-family SDK transport matrix: OpenAI verifier route + orchestrator-SDK design | queued, blocked by 15c + 16; orchestrator portion gated on 23 | [`28-per-role-family-sdk-transport.md`](./28-per-role-family-sdk-transport.md) |
| 27 | Design: cloud-hosted orchestration as a future phase | queued — design-only, future phase, gated on 23 verdict | [`27-cloud-orchestration-phase.md`](./27-cloud-orchestration-phase.md) |

### Operator notes (pass 3)

- Tier 0 (15a–17) completed 2026-05-28. `state.yaml` updated; `current_stage` is now `18-panel-verifier`.
- The autometta repo has `.autometta.local.yaml` pinning `codex: api`; sibling `~/.codex-api-only` CODEX_HOME is configured. `autometta auth check codex` reports PASS.
- Each design card (20, 22, 24, 26) emits a prose decision rather than code. Verdicts feed future implementation cards.
- Cards 18, 19, 25 each depend on Tier 0 (now done); queue them in tier order in `state.yaml` before dispatching.
- Tier 4 (28 + 27) was added 2026-05-28 from a scoping conversation. Card 28 completes the `<role>.<family>.transport` matrix: the Claude verifier SDK route shipped in 15c/16, so the concrete new work is the OpenAI verifier route; the orchestrator-role transport is design-only here and its production path waits on the card-23 verdict. Card 27 parks cloud-hosted orchestration as an explicit future phase, not pass 3, since it pressure-tests the single-machine beliefs in `docs/philosophy.md`.
