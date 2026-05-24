# Autometta handoff: 2026-05-22

Historical handoff note. For current operator setup, prefer `README.md`,
`docs/setup.md`, `docs/deployment.md`, and `examples/self-host/PLAN.md`.

A fresh orchestrator session picking up where this one left off should read this file first, then `examples/self-host/PLAN.md`, then the relevant memory entries listed below.

This session opened the repo with `aecfbe5` (Tony's initial scaffold), ran stages 0 through 5b end-to-end, did a stage 6 dry run that surfaced eight findings, fixed five of them in place, authored stage 5c to close the remaining three, and landed a working publish-guard.

## State of the repo at handoff

- **Branch:** `dev`, 24+ commits ahead of `origin/dev`. Nothing pushed.
- **Working tree:** clean.
- **Publish guard:** armed. Verified to fire on both pre-commit (planted path leak) and pre-push (non-public branch to public remote). Vendored at `scripts/publish-guard/`; reproducibility shim works on a fresh clone via `bash scripts/publish-guard/install-guards.sh`.
- **phat-controller infrastructure:** initialised. `~/.phat-controller/` exists with `subscribers/autometta.yaml` registered. `state/state.yaml` and `state/budget.json` exist but are gitignored (per the leak resolution).
- **Halted state:** `state/budget.json` shows `halted: true, halt_reason: "budget cap exhausted"` from the dry run. Cleared manually during validation but may need re-clearing depending on what's happened since. After stage 5c lands, `tick.sh --reset-halt` is the right way to clear it.
- **GitHub remote rename:** pending operator action on GitHub. Local project name is `Autometta`; the remote will be `aw-pr/autometta` once renamed. Update `GUARD_PUBLIC_URL_MATCH` in `.publish-guard.local` after the GitHub rename lands.

## What ran in this session

Twenty-five commits since the initial scaffold. Authors split across three agent identities:

```
git log --format='%h %an %ar | %s' aecfbe5..HEAD
```

(Run this to see the full chain.)

Headline groups:

- **Stages 0 to 3:** dispatch contract templates, lessons + verification doc, fractals examples, memory bootstrap from `<ALW>` tags in philosophy.md. Each stage authored card, dispatched worker, cross-family verifier, committed atomically.
- **Stages 4 to 5b:** phat-controller design + JSON schemas, the four runtime scripts (tick, spawn-worker, spawn-verifier, budget), the three init scripts (check-deps, init-host, subscribe-repo) and docs/setup.md.
- **Path cleanup:** stripped baked-in absolute paths from stage cards, updated templates and orchestrator-checklist to prevent recurrence.
- **Rename:** autometa to Autometta. 20+ files sed'd, mcp-hub symlink re-linked, README placeholder added for Tony's preamble.
- **Publish-guard arming:** the warning that fired on every commit since repo init is now gone.
- **Stage 6 dry run:** infrastructure proven end-to-end on real disk; eight findings banked.

## The eight stage-6 findings

| # | Finding | Status |
|---|---|---|
| 1 | `check-deps.sh` over-strict on bash 4+ | fixed |
| 2 | subscriber yaml quote-stripping | fixed |
| 3 | `template.yaml` iterated as a subscriber | fixed |
| 4 | yq required, not optional | fixed per operator decision |
| 5 | `state.yaml` `repo:` field leaks home path | fixed per operator decision |
| 6 | tick switches operator's working-dir branch | banked, addressed by 5c |
| 7 | verifier prompt is one sentence | banked, addressed by 5c |
| 8 | tick stacks verifier processes during long workers | banked, addressed by 5c |

## Memory entries (18 total at handoff)

See `memory/INDEX.md` for the live list. New since stage 0:

**Lessons (feedback):**
- `feedback-subagent-budget-enforcement` - Task-tool budgets are advisory; tighten scope
- `feedback-style-constraints-pre-check` - em-dash and AI-tell scans must precede the verifier
- `feedback-acceptance-criterion-stage-card-exemption` - stage cards live outside deliverables dir by design
- `feedback-verifier-prompt-mirrors-stage-card` - verifier prompt must reflect the stage card's permissions, not a frozen file list
- `feedback-stage-5-silent-failure-risks` - yq abort, dirty-tree discard, no elapsed stall (all closed by 5a)
- `feedback-stage-card-paths-relative` - no absolute paths in stage cards (template + checklist now enforce)
- `feedback-init-script-macos-specific` - `stat -f` needs uname branch for Linux
- `feedback-stage-6-runtime-bugs` - the four findings from the dry-run first fire
- `feedback-state-yaml-leaks-home-path` - design-vs-policy conflict; state/ gitignored
- `feedback-tick-switches-working-dir-branch` - interactive footgun
- `feedback-verifier-dispatch-impoverished` - one-sentence prompt blocks real dispatch
- `feedback-tick-respawns-verifier-while-worker-running` - no kill -0 guard

**Decisions (project):**
- `project-cross-family-verification-validated` - load-bearing belief confirmed on stage 0
- `decision-loop-name-phat-controller` - pass-2 layer name
- `decision-single-tick-multi-repo-subscribe` - one cron tick serves N repos
- `decision-identity-via-orchestrator-skill` - model-tier resolution at dispatch time
- `decision-verifier-handoff-naming` - `state/verifiers/<stage-id>.json`
- `decision-failure-budget-clock-tick` - primary safety is the clock tick count
- `decision-state-dir-per-repo` - `state/` directory layout
- `decision-phat-controller-no-daemon-subscriber-registry` - singleton home dir
- `decision-tick-implementation-parameters` - branch name, repair entry, config path, grace factor

## What's pending

| Item | Where | Notes |
|---|---|---|
| Stage 5c hardening | `examples/self-host/05c-phat-controller-hardening-2.md` | Card authored, not yet dispatched. Closes the three remaining design gaps plus two helpers (`add-stage.sh`, `tick.sh --reset-halt`). |
| Stage 5d setup skill | `memory/decision-skills-layout-autometta-setup.md` | Decision banked; skill not yet authored. New skill at `autometta/skills/autometta-setup/` for adopting Autometta in another repo. Sibling to agent-orchestrator. Not blocking 5c or stage 6. |
| Stage 6 real dispatch test | (no card yet) | Awaits 5c. Estimated cost ~$0.50-$2 per cycle on a trivial card. |
| README preamble | `README.md` | Placeholder exists at `## About the name`; Tony to write. |
| GitHub remote rename | external | Rename to `aw-pr/autometta` on GitHub. Then update `.publish-guard.local` `GUARD_PUBLIC_URL_MATCH`. |
| origin/dev push | external | 24+ commits local-only. Push when ready. |

## Two work streams open in parallel

You can split the work because pass 1 (dispatch contract) and pass 2 (phat-controller loop) are independent.

**Pass 1 ready right now:** the dispatch contract has been exercised 8 times in this session for stages 0 through 5b. Templates + verifier pattern + cross-family pairing all work. Any other repo (including `fractals-from-the-90s`) can adopt pass 1 today by either:

- Copying `templates/stage-card.md`, `templates/worker-prompt.md`, and `templates/orchestrator-checklist.md` into the target repo; OR
- Referencing them from Autometta as read-only artefacts.

A human orchestrator (in a Claude Code session opened in the target repo) can then author a stage card, dispatch a Codex or Claude worker, run a cross-family verifier, and commit. The dogfooding discipline from stages 4 onwards (copy template + fill in placeholders) is the recommended pattern.

**Pass 2 (phat-controller autonomous loop) on hold:** until 5c lands and is validated, the loop will produce noise on the verifier side and may stack processes. Do not subscribe other repos to phat-controller yet.

## Recommended sequencing for the next session

1. (Optional, in parallel) Open a new Claude Code session in `~/repos/fractals-from-the-90s`. Have that session adopt pass 1 patterns and start authoring fractals stage cards. Two parallel streams: one driving fractals work via the pass-1 contract, one continuing Autometta hardening via stage 5c.

2. In this Autometta repo:
   - Confirm working tree is on `dev` and clean.
   - Confirm `bash -n` on all `scripts/*.sh` is clean.
   - Dispatch stage 5c: read `examples/self-host/05c-phat-controller-hardening-2.md`, follow the orchestrator-checklist, fire a Codex worker, run a Sonnet verifier. Commit atomically per the dispatch contract.

3. After 5c lands and verifies clean:
   - Decide on the real dispatch test. Options: trivial test card against Autometta itself, or wait for a real backlog from fractals work to feed in.

4. Whenever ready: GitHub rename + push.

## Where to look if something seems off

| Symptom | First place to read |
|---|---|
| Setup or operator question | `docs/setup.md` |
| What a tick does | `docs/phat-controller.md` |
| The pass-1 protocol | `docs/dispatch-contract.md` |
| Gotchas surfaced in prior projects | `docs/lessons.md` |
| What stage is where | `examples/self-host/PLAN.md` |
| Why something was decided | `memory/INDEX.md` and its decision-*.md entries |
| Why something is the way it is | `memory/INDEX.md` and its feedback-*.md entries |
| What was tried as a stage | `examples/self-host/00-bootstrap.md` through `05c-phat-controller-hardening-2.md` |

## One thing the next session must do

Read `examples/self-host/PLAN.md` first. Its status table is the ground truth for "what is done, what is pending, what is paused, and why". If it conflicts with this handoff doc, trust the PLAN.

This handoff doc itself does not get updated as work progresses; the PLAN does.
