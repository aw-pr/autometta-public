---
name: autometta-setup
description: Adopt the Autometta dispatch contract (pass 1) and optionally the phat-controller autonomous loop (pass 2) inside another repository. Trigger ONLY when the user explicitly asks to set up Autometta in this repo, using phrases like "set up Autometta here", "adopt the dispatch contract", "use Autometta patterns in this project", "wire phat-controller into this repo", "subscribe this repo to Autometta". Do NOT trigger inside the Autometta repo itself; do not trigger on generic multi-agent work (that is agent-orchestrator).
---

## What this skill does

Walks the operator through adopting Autometta in the current working repository. There are two passes:

- **Pass 1: dispatch contract.** Stage cards, worker prompt template, verifier prompt template, cross-family verifier pattern. A human orchestrator authors a card, dispatches a worker, runs a verifier, commits. No daemon, no cron. This pass is stable and the recommended starting point.
- **Pass 2: phat-controller autonomous loop.** A cron-driven `tick.sh` that drives pass-1 dispatches across one or more subscribed repos. Reads stage cards, spawns workers, runs verifiers, tracks budget and failure counters, halts on cap. This pass requires more setup and trust.

Adopt pass 1 first. Add pass 2 only after at least one pass-1 cycle has run cleanly in the target repo.

## When NOT to use

- The current repo is Autometta itself. Skill is for *adopters*, not the source repo.
- The user wants a generic orchestrator pattern; use `agent-orchestrator` instead.
- The user wants to set up publish guards; use `repo-publish-guard-init` or `repo-publish-guard-retrofit` instead.
- The user is asking about commit attribution or cross-family verification as abstract concepts. Point them at the source docs in Autometta (`docs/dispatch-contract.md`, `docs/lessons.md`, `docs/verification.md`) without running the setup flow.

## Decision tree

```
Are you adopting Autometta in another repo?
├── No  -> wrong skill, stop here
└── Yes
    ├── Do you want an unattended cron loop, or human-driven dispatch?
    │   ├── Human-driven (recommended first)
    │   │   -> Pass 1 only. Skip to "Pass 1 adoption" below.
    │   └── Unattended cron loop
    │       -> Pass 1 + Pass 2. Do pass 1 first, validate one cycle, then pass 2.
    └── Deployment choice:
        ├── Homebrew-local CLI + local manifest (default for one-machine phat-controller)
        ├── Copy (simplest for one-off pass 1, owns templates locally)
        └── Submodule (portable pinned provenance, more git ceremony)
```

For a first adoption: **pass 1 only, copy the stage card and prompt templates.** For pass 2, prefer the `autometta` CLI installed from the canonical checkout plus the gitignored `.autometta.local.yaml` manifest. Use a submodule only when the adopter repo must be portable and pinned.

## Pass 1 adoption

### Step 1. Vendor the templates

Three template files travel together: the worker prompt, the verifier prompt, and the orchestrator checklist. From the Autometta repo root, copy:

- `templates/worker-prompt.md`
- `templates/verifier-prompt.md`
- `templates/orchestrator-checklist.md`
- `templates/stage-card.md`

into `templates/` inside the target repo.

```sh
# from the target repo root
mkdir -p templates
cp ~/repos/autometta/templates/{worker-prompt,verifier-prompt,orchestrator-checklist,stage-card}.md templates/
```

Adjust the source path if Autometta lives somewhere else on the machine.

### Step 2. Vendor the dispatch docs (optional but recommended)

The dispatch contract itself plus the lessons doc are useful in-repo as orchestrator context:

```sh
mkdir -p docs
cp ~/repos/autometta/docs/{dispatch-contract,lessons,verification}.md docs/
```

If the target repo already has a `docs/` directory with conflicting filenames, place these under `docs/autometta/` instead.

### Step 3. Author the first stage card

Copy `templates/stage-card.md` to a per-repo location and fill it in. Convention used in Autometta is `examples/self-host/<stage-id>.md`; in an adopter repo the natural location is wherever the project tracks its work plans. For first-card guidance:

- Keep deliverables small and concrete (one file or two files maximum).
- Acceptance criteria must be greppable. The verifier is not creative.
- Stage card itself is exempt from "no files outside deliverables" criteria; the card lives outside the deliverable set by design (banked in `memory/feedback-acceptance-criterion-stage-card-exemption.md` in Autometta).

### Step 4. Dispatch the first worker

A human orchestrator (Claude Code session opened in the target repo) reads the orchestrator-checklist and:

1. **Pre-flight: confirm a clean working tree.** `git status -s` should show no unrelated modifications. Acceptance criteria of the form "no files outside the deliverables set are modified" treat the operator's full working tree as the worker's; any pre-existing dirty file lands as a false-positive FAIL. Stash, revert, or commit on a different branch before dispatch. If a gitignored file is still tracked (the classic `.DS_Store` case), `git rm --cached <file>` and commit.
2. Picks a worker tier and family. For shell-script or template work, cross-family is the default (Codex worker if orchestrator is Claude). For prose-heavy content, same-family is fine but cross-family verification still applies.
3. Renders the worker prompt by filling placeholders in `templates/worker-prompt.md`.
4. Dispatches the worker. With Autometta's `spawn-worker.sh` available (pass 2 vendored), this is one command. Without it, the orchestrator constructs the dispatch directly:
   - Codex: `codex exec --sandbox workspace-write "<prompt>" </dev/null > /tmp/<stage-id>-worker.log 2>&1 &`
   - Claude: `claude -p "<prompt>" </dev/null > /tmp/<stage-id>-worker.log 2>&1 &`
5. Waits for the worker to exit (monitor the log; track PID).
6. Runs the pre-verifier gate: `bash -n` on any modified shell scripts, em-dash and AI-tell scan, idempotency-pattern grep where relevant.
7. Dispatches the verifier with `templates/verifier-prompt.md`. Cross-family by default (banked in `memory/project-cross-family-verification-validated.md`).
8. Commits atomically per the dev rules (`~/.claude/rules/mcp-hub-dev-rules.md` or the equivalent in this repo's CLAUDE.md): committer is the human user, author is the agent that primary-authored the diff, co-author trailer for assisting agents.

### Step 5. Bank surprises in the Autometta repo (not the adopter)

Every stage's surprises (good and bad) get banked as `feedback-*.md`, `decision-*.md`, or `project-*.md` entries in the **Autometta** repo, not in the adopter. This is deliberate: it keeps all dispatch-contract learnings in one place so the upstream patterns can evolve from real cross-repo data.

Location convention:

- **Self-host findings** (lessons from Autometta running on itself) live flat at `autometta/memory/<type>-<slug>.md`.
- **Adopter findings** (lessons from any repo that adopted the contract, including fractals) live at `autometta/memory/adopters/<adopter-repo-name>/<type>-<slug>.md`.

This split lets future analysis ask "what tripped up adopters specifically?" with a single `find autometta/memory/adopters -name 'feedback-*'`.

**Analysis-friendly frontmatter.** Adopter feedback entries should add a `metadata.run` block with structured fields so later batch analysis can correlate categories with cost, agent family, stage, and back-port target. See `skills/autometta-setup/REFERENCE.md` for the field set and a worked example.

The next orchestrator session reads from current knowledge, not lore. Autometta's own flat `memory/` directory is the worked example for the self-host case; `memory/adopters/fractals-from-the-90s/feedback-working-tree-precondition.md` is the worked example for the adopter case.

That is pass 1, end to end. The first cycle takes longer than steady-state because the templates are unfamiliar.

## Pass 2 adoption (optional, after one clean pass-1 cycle)

Pass 2 adds the phat-controller autonomous loop. Install the `autometta` CLI from the canonical checkout, register the repo as a subscriber, install a cron entry, and keep the adopter's `.autometta.local.yaml` manifest gitignored. The full operator guide lives at `docs/setup.md` in Autometta; reference it directly rather than duplicating here.

Headline checklist (refer to `docs/setup.md` in Autometta for details):

1. Confirm dependencies: `bash` 3.2+, `jq`, `git`, `codex`, `claude`, `python3`, `yq`, and `agent-whoami`. `autometta check-deps` does this in one shot.
2. Run `scripts/install-homebrew-local.sh` from the Autometta checkout.
3. Run `autometta init <target-repo-root>` to create host state if needed and register the repo.
4. Confirm the target repo has a gitignored `.autometta.local.yaml` manifest.
5. Review and commit `.gitignore`, `state/state.yaml`, and `state/budget.json` before the first tick.
6. Install a cron or launchd entry per `docs/setup.md` section 4.
7. Confirm the loop ticks cleanly by firing `autometta tick` once manually before handing it to cron.

If `state/budget.json` halts mid-run, `autometta tick --reset-halt` clears it. To add a new stage to the loop, `autometta add-stage <repo-root> <stage-card-path>` is the idempotent helper.

**Strong recommendation:** add `state/` to `.gitignore` in the target repo. The directory holds runtime state, logs, and verifier artefacts, none of which belong in version control. Autometta's resolution of this is banked at `memory/feedback-state-yaml-leaks-home-path.md`.

## Chain to publish-guard

If the target repo will eventually be open-sourced, chain `repo-publish-guard-init` (for a brand new repo) or `repo-publish-guard-retrofit` (for an in-progress one) after pass 1 vendoring is complete. Autometta itself is set up this way; see `runs/build-log/pass-29-publish-workflow.md` in the agentic-rag-kimble project for the cross-reference pattern.

## Common gotchas

- **Worker stdin must be `</dev/null`.** Both `codex exec` and `claude -p` will block on stdin if invoked without it; the spawn-worker script always redirects from /dev/null and headless dispatches outside that script must do the same. Banked at `memory/feedback-stage-6-runtime-bugs.md`.
- **State directory must be gitignored.** `state/budget.json`, `state/state.yaml`, `state/logs/`, and `state/verifiers/` all hold runtime data. Autometta gitignores `state/` and `state/logs/` for redundancy.
- **Cross-family verification is the default.** Same-family verifiers miss style violations and contract-semantic blind spots that the other family catches. Banked at `memory/project-cross-family-verification-validated.md`.
- **Stage card exemption.** Acceptance criteria that check "no files outside deliverables" must explicitly exempt the stage card itself. Always banked once and re-bitten if you forget.

## Identity attribution at commit time

The committer is always the human user. The *author* identifies the agent that primary-authored the diff:

```sh
git commit --author="Claude Opus 4.8 <claude-opus-4-8@local>" -m "<message>"
git commit --author="Codex GPT-5.3 <codex-gpt-5-3@local>" -m "<message>"
```

For multi-agent contributions, append a trailer:

```
Co-Authored-By: Claude Sonnet 4.6 <claude-sonnet-4-6@local>
```

The canonical agent table lives in `~/.claude/rules/mcp-hub-dev-rules.md`. Adopter repos should reference this rule file rather than duplicate the table.

## Worked example

`REFERENCE.md` carries the worked example: adopting Autometta in the `fractals-from-the-90s` repo. Read it on demand; it is not loaded into the active session by default.
