---
name: autometta-setup
description: Adopt the Autometta dispatch contract (pass 1) and optionally the autonomous tick loop (pass 2) inside another repository. Trigger ONLY when the user explicitly asks to set up Autometta in this repo, using phrases like "set up Autometta here", "adopt the dispatch contract", "use Autometta patterns in this project", "wire the tick loop into this repo", "subscribe this repo to Autometta". Do NOT trigger inside the Autometta repo itself; do not trigger on generic multi-agent work (that is agent-orchestrator).
---

## What this skill does

Walks the operator through adopting Autometta in the current working repository. There are two passes:

- **Pass 1: dispatch contract.** Stage cards, worker prompt template, verifier prompt template, cross-family verifier pattern. A human orchestrator authors a card, dispatches a worker, runs a verifier, commits. No daemon, no cron. This pass is stable and the recommended starting point.
- **Pass 2: autonomous tick loop.** A cron-driven `tick.sh` that drives pass-1 dispatches across one or more subscribed repos. Reads stage cards, spawns workers, runs verifiers, tracks budget and failure counters, halts on cap. This pass requires more setup and trust.

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
        ├── Homebrew-local CLI + local manifest (default for the one-machine tick loop)
        ├── Copy (simplest for one-off pass 1, owns templates locally)
        └── Submodule (portable pinned provenance, more git ceremony)
```

For a first adoption: **pass 1 only, copy the stage card and prompt templates.** For pass 2, prefer the `autometta` CLI installed from the canonical checkout plus the gitignored `.autometta.local.yaml` manifest. Use a submodule only when the adopter repo must be portable and pinned.

## Pass 1 adoption

### Step 1. Vendor the templates and the gate

The dispatch-contract files travel together: the worker prompt, the verifier prompt, the orchestrator checklist, the stage card template, the contract-test gate, and the vendor freshness check. From the Autometta repo root, copy:

- `templates/worker-prompt.md`
- `templates/verifier-prompt.md`
- `templates/orchestrator-checklist.md`
- `templates/stage-card.md`
- `scripts/check-contract-test-gate.sh` — enforces the frozen contract-test assertions that the verifier prompt and the stage-card template refer to. Vendor it whenever you vendor the templates, or those references dangle (the verifier is told to run a script that is not there).
- `scripts/autometta-vendor-check.sh` — reports when any vendored file has drifted from upstream.

Do not copy those files by hand, and do not write the stamp by hand. One command vendors the set and writes the provenance stamp:

```sh
autometta refresh-repo <target-repo-path> --adopt
```

`--adopt` is for a repo that has never held the contract. After that, the same command without the flag is how the repo takes every later release. The file list it works from lives in one place upstream (`scripts/vendor-set.sh`); a hand-typed copy of it in this skill would be a fourth list to keep in step with the other three, which is the drift the single definition exists to end.

Review the result and commit it in the target repo. The refresh leaves its changes unstaged deliberately: Autometta pushes files, and the commit is yours to make. Commit `.autometta-vendor` alongside the vendored files; it is provenance, not runtime state, so it belongs in version control.

### Step 1a. A subscriber is refreshed, never hand-edited

Once a repo holds the contract, treat the vendored files as read-only downstream. Work on them happens in Autometta and arrives by a push:

```sh
autometta refresh-repo <repo-path> --dry-run   # what would change here
autometta refresh-repo <repo-path>             # take the release
autometta refresh-all-repos --dry-run          # what would change fleet-wide
autometta refresh-all-repos                    # push to every enabled subscriber
```

The one edit you *are* meant to make downstream is filling a template's `<<placeholder>>` slots. That is the template working as designed, and a refresh preserves such a file byte for byte, reporting it as `FILLED` rather than overwriting it. Any other local edit reads as `DRIFT`, and a refresh replaces it: an edit made downstream reaches nobody, so it is lost work by construction. Change it in Autometta and push it out.

A refresh also refuses to write into a repo with uncommitted changes on a vendored path, naming the path, and skips a repo with a stage in flight. Neither is an error to work around; both mean "not now".

Full surface, including the stamp format and what each refusal looks like, is in `docs/dispatch-contract.md` under "Pushing a release to the subscribers".

### Step 1b. Check vendored freshness later

After any `git pull` of the Autometta source, or as a pre-flight before an orchestrator session, confirm the vendored copies are still current:

```sh
AUTOMETTA_ROOT=~/repos/autometta scripts/autometta-vendor-check.sh
```

It takes the file set from upstream's single definition, content-hashes each file against the canonical checkout, and exits non-zero if any have drifted or gone missing, naming them. A file differing only in filled placeholders reads as `FILLED`, not drift. To clear real drift, run `autometta refresh-repo .`, which also rewrites the stamp to the new source SHA. (If you adopted by git submodule instead of copy, `git submodule status` already reports the pinned SHA and `git submodule update --remote` updates it; the stamp, this check and the refresh commands are for copy adoption.)

You rarely need to remember to run it. The tick loop compares each subscriber's stamp against the Autometta root it is running from and logs one warning per repo per pass when a repo is behind, naming both SHAs and the command to fix it. It is a warning only: the stage still dispatches, because taking a release is your decision.

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

1. **Pre-flight: cut a run worktree.** Dispatch never happens in the shared checkout. Declare `Base branch` and `Run branch` (`autometta/<stage-id>`) on the card, then `git worktree add ../<repo>-run-<stage-id> -b autometta/<stage-id> <base-branch>` (removing any worktree/branch left by a prior attempt first). The worker and verifier work only there, so the operator's working tree — dirty or clean — is never a dispatch precondition. See `templates/orchestrator-checklist.md` ("Worktree dispatch pre-flight").
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

Pass 2 adds the autonomous tick loop. Install the `autometta` CLI from the canonical checkout, register the repo as a subscriber, install a cron entry, and keep the adopter's `.autometta.local.yaml` manifest gitignored. The full operator guide lives at `docs/setup.md` in Autometta; reference it directly rather than duplicating here.

Headline checklist (refer to `docs/setup.md` in Autometta for details):

1. Confirm dependencies: `bash` 3.2+, `jq`, `git`, `codex`, `claude`, `python3`, `yq`, and `agent-whoami`. `autometta check-deps` does this in one shot.
2. Run `scripts/install-homebrew-local.sh` from the Autometta checkout.
3. Run `autometta init <target-repo-root>` to create host state if needed and register the repo.
4. Confirm the target repo has a gitignored `.autometta.local.yaml` manifest.
5. Review and commit `.gitignore`, `state/state.yaml`, and `state/budget.json` before the first tick. Leave `token_cap_total` out of `budget.json` unless this repo genuinely differs from the host default; see "Budget policy" below.
6. Install a cron or launchd entry per `docs/setup.md` section 4.
7. Confirm the loop ticks cleanly by firing `autometta tick` once manually before handing it to cron.

If `state/budget.json` halts mid-run, `autometta tick --reset-halt` clears it. To add a new stage to the loop, `autometta add-stage <repo-root> <stage-card-path>` is the idempotent helper.

### Verification tier choice

Every subscribed repo picks a verification tier per family in
`.autometta.local.yaml` (`auth.<family>.mode`), and the choice should start
from measurement, not folklore: Autometta's own "Billing routes" table in
`README.md` (backed by `docs/verifier-bake-off.md`) is the current
recommendation, and it applies unchanged to an adopter repo. Point a new
subscriber at that table rather than restating the numbers here: they will
drift out of step with the bake-off's own re-runs if duplicated. The
one-line version: `auth.codex.mode: local` (`gpt-oss:120b`) is the
measurement-backed free default for mechanical-acceptance stages; keep a
frontier verifier (`api` or `subscription`) for judgement-heavy criteria; the
cloud free tier (Groq, OpenRouter) is measured but not yet a selectable
dispatch mode, only reachable via `scripts/verifier-bake-off.sh` directly.

### Optional: configure the phat-controller job (and ask for spend authority)

The tick loop dispatches and verifies. It does not decide that a verifier FAIL is a card defect, preserve work stranded by an agent that died mid-write, merge an integration, clear a stale pause, or keep the queue fed. phat-controller does, and it is worth adding only once the loop itself ticks cleanly. Full design: `docs/tick-loop.md` section (k).

It is an agent seeded at configure time, so configuring the job means rendering its seed, and rendering the seed means answering one question you cannot skip.

**Ask the operator, in the conversation, before running anything:**

> What may this controller spend on this run? Give me a level in your own words, and optionally a hard token ceiling and a time the authority expires.

**Do not offer a default and do not pick one for them.** The right level varies by run, by hour and by day: an overnight window drain and a Tuesday-afternoon smoke run want different numbers, and a default would be wrong most of the time it was used, in the expensive direction. If the operator will not answer, stop and say the job cannot be configured yet. The tooling agrees with you: `render-controller-seed.sh` with no `--spend-authority` writes nothing and exits 2, and `install-launchagent-phat-controller.sh` refuses to install a schedule with no seed.

Then, with the answer in hand:

```sh
autometta install-launchagent-phat-controller <target-repo-root> \
  --spend-authority 'Up to 40M tokens overnight on the Claude subscription. The codex api route stays off tonight.' \
  --token-ceiling 40000000 \
  --expires 2026-08-25T07:00:00Z
```

The prose answer goes into the seed, which the agent reads. The ceiling and expiry are mirrored into the mandate manifest, which is where a script is allowed to read a threshold from. Both are optional; the prose is not.

Check the result with `autometta phat-controller --print-seed` and read it back to the operator: it also carries the prohibitions, this machine's paths, each family's auth route, the repo's branch policy and its own gotchas, and any of those being wrong is worth catching before the first unattended pass rather than after it. The seed is operator-owned afterwards; re-rendering needs `--force`.

### Budget policy: the daily cap is a host decision

Most adopters should not choose a token cap at all. `autometta init-host` asks for one daily `token_cap_total` and writes it to `~/.autometta/config.yaml`; every subscribed repo inherits it. That is the intended resting state.

- **What the daily cap is for.** Catching a runaway, not budgeting a project. It is the number that stops a loop which has started spending without producing, and nothing about a healthy run should ever approach it.
- **Why it is a host decision.** The machine has one provider window and the caps compete for it, so a number chosen per repo is a number chosen without seeing the others. Autometta's own fleet ended up carrying 3,000,000 / 8,000,000 / 100,000,000 / 150,000,000 across five subscribers, and nothing recorded why any of them held. That spread was accumulated history, not policy.
- **When a repo should override.** Only where it genuinely differs, and say so in the commit that sets it: a repo doing deliberately cheap doc work, or one whose stages are known to be far larger than the fleet average. Setting `token_cap_total` in `state/budget.json` wins over the host default.
- **A missing cap inherits, it does not free.** Resolution runs drain, then repo, then host default, then a floor of 20,000,000. There is no unlimited resting state.

**A drain is not a raised cap.** Deliberately spending the provider window down overnight is a different intent from catching a runaway, and it gets its own mode rather than a bigger number in `budget.json`:

```sh
autometta drain start --cap 400000000 --hours 8 --reason "weekly window drain"
autometta drain status
autometta drain end
```

It is host-level and per run, it says so in the tick log for every tick it is in force, it edits no repo's `budget.json`, and it expires by itself (8 hours by default, 12 maximum). A drain that outlives the night it was opened for would just be an unlimited cap with extra steps. It does not unlatch a halt already taken; that stays `autometta tick --reset-halt`.

Full resolution order and the incident behind it: `docs/dispatch-contract.md`, section "Which token cap binds".

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
git commit --author="$(agent-whoami)" -m "<message>"
```

For multi-agent contributions, append a trailer:

```
Co-Authored-By: Claude Sonnet 4.6 <claude-sonnet-4-6@local>
```

The canonical agent table lives in `~/.claude/rules/mcp-hub-dev-rules.md`. Adopter repos should reference this rule file rather than duplicate the table.

## Worked example

`REFERENCE.md` carries the worked example: adopting Autometta in the `fractals-from-the-90s` repo. Read it on demand; it is not loaded into the active session by default.
