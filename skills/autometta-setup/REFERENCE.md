# autometta-setup reference material

Worked example and extended troubleshooting. Read on demand.

## Worked example: adopting Autometta in `fractals-from-the-90s`

The target repo is a fractals rendering project with two active branches (`feature/render-phase1`, `feature/ui-track`) and a divergent `main`. The operator wants to use the Autometta dispatch contract for stage cards going forward.

### Pre-flight

```sh
cd ~/repos/fractals-from-the-90s
git status                                  # confirm clean tree
git rev-parse --abbrev-ref HEAD             # note current branch for restore later
ls templates/ 2>/dev/null || echo "no existing templates dir"
ls docs/ 2>/dev/null
```

If `templates/` already exists with non-autometta content, place the Autometta templates under `templates/autometta/` instead.

### Pass-1 copy mode

```sh
mkdir -p templates docs/autometta
cp ~/repos/autometta/templates/{worker-prompt,verifier-prompt,orchestrator-checklist,stage-card}.md templates/
cp ~/repos/autometta/docs/{dispatch-contract,lessons,verification}.md docs/autometta/
```

Commit as a single atomic change with the orchestrator's author identity, message body: "adopt Autometta dispatch contract (pass 1)". No code paths affected yet; this is a pure docs+templates landing.

### First stage card

Fractals tracks its work plans under `docs/cards/` historically (check the actual layout). Pick a small first card. Suggested first card: "extract the render-loop FFT pre-pass into its own function, no behaviour change". One file modified, three acceptance criteria:

1. `git diff --stat` shows exactly one file changed.
2. `make build` (or whatever the repo's build command is) returns 0.
3. The new function is named `precompute_fft_window` and lives at the same indentation depth as the loop it was extracted from.

This is a refactor card. Cross-family verification is the default. Pair: Codex worker (refactor work) with Claude Sonnet verifier (greppable criteria). Same pattern as Autometta stage 5c.

### Dispatch (without phat-controller scripts vendored)

The orchestrator (Claude Code session opened in `fractals-from-the-90s`) reads `templates/worker-prompt.md`, substitutes placeholders, and dispatches:

```sh
prompt="$(sed \
  -e "s|<<worker-tier>>|Codex GPT-5.3|g" \
  -e "s|<<project-name>>|fractals-from-the-90s|g" \
  -e "s|<<orchestrator-identity>>|claude-code-session|g" \
  -e "s|<<stage-card-path>>|docs/cards/refactor-fft-precompute.md|g" \
  -e "s|<<family-specific-notes-or-none>>|None|g" \
  templates/worker-prompt.md)"

codex exec --sandbox workspace-write "$prompt" </dev/null > /tmp/refactor-fft-worker.log 2>&1 &
worker_pid=$!
echo "worker PID: $worker_pid"
```

Monitor the log. When the worker exits, run the pre-verifier gate (`bash -n` if shell-script work, em-dash scan, AI-tell scan). Then dispatch the verifier as a Claude Code Task sub-agent with the rendered `templates/verifier-prompt.md`.

### Commit attribution

Two commits, atomic:

```sh
git add <worker deliverables>
git commit --author="Codex GPT-5.3 <codex-gpt-5-3@local>" -m "refactor: extract precompute_fft_window from render loop"

git add <orchestrator metadata like a PLAN file>
git commit --author="Claude Opus 4.7 <claude-opus-4-7@local>" -m "plan: refactor-fft-precompute landed at <sha>"
```

If a verifier artefact is committed (depends on whether the repo tracks `state/`), use Sonnet's author string for that commit.

### When to adopt pass 2

After three to five clean pass-1 cycles in the target repo. Pass 2 adds a cron tick that runs unattended; the operator needs confidence in pass 1 behaviour first. If the repo is single-developer and the operator is fine kicking off cards manually, pass 1 is the steady state; there is no requirement to adopt pass 2.

For pass 2, prefer the installed CLI rather than copied scripts:

```sh
scripts/install-homebrew-local.sh        # from the Autometta checkout
autometta init /path/to/target-repo
git -C /path/to/target-repo add .gitignore state/state.yaml state/budget.json
git -C /path/to/target-repo commit -m "Initialise Autometta"
autometta status
autometta attach /path/to/target-repo --dry-run
```

Use a Git submodule only when the adopter repo needs a pinned Autometta revision in its own history.

## Troubleshooting

### The worker exits in seconds with an empty log

Almost always a stdin issue: the worker was waiting for input and was killed by an upstream timeout or signal. Confirm the dispatch line includes `</dev/null`.

### The worker writes files outside the deliverables set

Re-brief once with explicit "files outside the deliverables set are FAIL" language. If it happens twice on the same card, the card is under-specified; add explicit `Out of scope` bullets enumerating directories the worker must not touch.

### The verifier returns PASS but the work is wrong

Two failure modes:

1. The acceptance criteria are not greppable. The verifier checked surface signatures and missed semantic violations. Rewrite the criteria to be checkable by deterministic tools (grep, `bash -n`, `make`).
2. The verifier was same-family with the worker. Switch to cross-family.

### `state/` logs keep appearing in `git status`

The repo should track `state/state.yaml` and `state/budget.json`, but not `state/logs/`. `autometta init` adds the expected `.gitignore` entry. If logs are already committed, do `git rm -r --cached state/logs/` then commit.

### `tick.sh` switches the operator's working branch mid-session

Pre-5c behaviour. Stage 5c added save/restore via captured HEAD plus EXIT trap in `commit_state_branch`. Using `autometta tick` from the current install includes the fix.

## Banking adopter feedback in Autometta (analysis-friendly format)

Adopter findings live at `autometta/memory/adopters/<adopter-repo-name>/<type>-<slug>.md`. The body follows the same shape as flat self-host entries (Why / How to apply / cross-references). The frontmatter adds a `metadata.run` block so batch analysis can group findings by category, cost, family pairing, and back-port target.

Recommended frontmatter shape:

```yaml
---
name: feedback-<short-slug>
description: <one-line summary>
metadata:
  type: feedback                       # or decision, project
  run:
    repo: <adopter-repo-name>
    stage_id: <stage-id-from-the-card>
    outcome: pass_first_try | pass_after_rebrief | fail | near_miss
    category: card-flaw | worker-failure | verifier-flaw | infra-bug | other
    severity: low | medium | high
    worker_family: claude | codex | other
    verifier_family: claude | codex | other
    cost_extra: <plain-language note, e.g. "one-extra-verifier-run">
    back_port_target:
      - <path or skill section to update upstream>
    surfaced_on: YYYY-MM-DD
---
```

Field discipline:

- **outcome** distinguishes a clean pass from a pass that needed a re-brief or a re-verifier dispatch. The cost difference is real.
- **category** is the one you grep for when you ask "did we have N card-flaw findings this month?". Keep the enum tight; if you need a new value, change the field-set documentation in this REFERENCE.
- **back_port_target** is what makes the bank actionable. Every adopter finding should point at the upstream artefact (template, checklist, skill section) that needs to change. Findings with no back_port_target are usually adopter-local and belong in the adopter's own repo, not here.

Worked example: see `autometta/memory/adopters/fractals-from-the-90s/feedback-working-tree-precondition.md`. That entry was banked after stage 01 in fractals surfaced a card-flaw category at medium severity, with a back-port target on both `templates/orchestrator-checklist.md` and this skill's Step 4.

For aggregate analysis later, the structured frontmatter parses cleanly with `yq` or a small Python script over `find autometta/memory/adopters -name '*.md'`.

## Heuristics

- **Start with one tiny card.** First cycle is about learning the protocol, not making progress. Sub-30-line diff is ideal.
- **Cross-family is the default, not the exception.** Skip it only with a written rationale in the stage card's "Pairing rationale" line.
- **Bank every surprise.** A `feedback-*.md` or `decision-*.md` entry per cycle is the price of admission for the next session starting from current knowledge.
- **State directory is runtime, not history.** If you find yourself wanting to commit a state file, the design is leaking; bank the leak.
