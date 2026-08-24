# The dispatch contract

This is the load-bearing document for Autometta pass 1. It describes the protocol by which an orchestrator dispatches one unit of work to one worker, with one verifier checking the result, and the orchestrator integrating. Everything else in pass 1 (the templates, the examples, the self-host plan) is an instance of this contract.

The contract is family-agnostic. The same shape works for a Claude Code worker, a Codex CLI worker, or any future CLI worker. Where a step is genuinely family-specific, it is called out under a family-specific notes heading rather than hard-coded into the protocol.

## Contract version

**Contract version: 2** (2026-08-24).

A change to the shape of the contract is a versioned decision, so the shape carries a number and a reason. Anything that alters what the roles owe each other, what a stage card must carry, or the set of states a stage can be in, bumps it. Wording, examples and typo fixes do not.

| Version | Date | What changed |
|---|---|---|
| 1 | up to 2026-08-23 | The seven steps, contract tests, the pass-2 stage lifecycle with `pending, in_progress, completed, failed, stalled, verifier_failed`. Unnumbered at the time; recorded here as the shape everything before card 43 was written against. |
| 2 | 2026-08-24 | Adds the terminal `superseded` stage status: a card an operator has decided should not run, which is not a failure. See [Stage statuses](#stage-statuses). |

Version 2 is additive. A `state.yaml` written against version 1 validates and ticks identically under version 2; there is no migration step.

## Why a contract, and not a framework

Frameworks assume the worker is an in-process LLM call. In Autometta the worker is a CLI subprocess and the state lives on the filesystem. A contract that fits this shape needs to be prose plus templates, not code. Every step below maps to a markdown file you can read, edit, and commit; there is no runtime to install, no DSL to learn, and no service to keep alive.

## The seven steps

The protocol runs in this order. Each step has one owner and one deliverable. If a step is skipped, the next step is operating on a weaker contract than it expects.

```
1. Stage card authoring         (orchestrator -> card on disk)
2. Worker prompt assembly       (orchestrator -> prompt that references the card)
3. Worker dispatch and sandbox  (worker -> deliverables inside the sandbox)
4. Acceptance command           (verifier -> pass/fail signal)
5. Verifier handoff             (verifier -> report consumed by orchestrator)
6. Orchestrator integration     (orchestrator -> diff read and reconciled)
7. Commit                       (orchestrator -> audit trail in git)
```

### Step 1: Stage card authoring

The orchestrator authors a stage card from `templates/stage-card.md` and writes it to a path that will survive the dispatch. In Autometta, cards for the self-host plan live in `examples/self-host/`; in your own repo they can live anywhere stable.

The card is the brief. It names the worker, names the verifier, lists inputs, lists deliverables, lists constraints, lists acceptance criteria, lists what is out of scope, and states a wall-clock budget. Anything the worker needs to know that is not in the card is a contract violation.

The card path is the prompt. The worker is told one path; it reads that one file; it acts on it. There is no out-of-band channel.

Before dispatch, the orchestrator runs `templates/orchestrator-checklist.md` against the card. Every item is a load-bearing check; skipping any one is the source of most failed stages.

### Step 2: Worker prompt assembly

The orchestrator assembles a worker prompt from `templates/worker-prompt.md`. The prompt names the stage card path, the worker tier, and any family-specific notes the worker needs (for example, that it should not write outside its sandbox).

The prompt is short and stable. The card carries the variable content; the prompt carries the invariant rules every worker follows on every dispatch.

### Step 3: Worker dispatch and sandbox

The worker is dispatched headless. It reads the card, reads the named inputs, writes the named deliverables, and returns a short summary. It operates inside a sandbox the orchestrator has set for it. The sandbox is the role boundary, not a convenience.

A worker cannot lift its own sandbox. This is the property the rest of the protocol relies on. A worker that could decide for itself whether acceptance has passed is a worker that can hallucinate green; a worker that cannot is a worker whose claim about its own work has to be checked from outside.

### Step 4: Acceptance command

The verifier runs an acceptance command outside the worker's sandbox. The command is stated or directly implied by the card's acceptance criteria. For a docs-only stage this might be a set of structural checks (file exists, no forbidden string, round-trip fidelity); for a code stage it is the project's test command, the build command, or both.

The acceptance command runs in the verifier's environment, not the worker's. A verifier inside the worker's sandbox is a verifier that cannot see what the sandbox prevented.

### Step 5: Verifier handoff

The verifier returns a structured report: which criteria passed, which failed, evidence for each. The report is consumed by the orchestrator; the verifier does not act on its own findings. A failing verifier report is the orchestrator's signal to re-brief, surface to the user, or abandon the stage, depending on the failure budget.

Cross-family verification is the default. Worker in family A, verifier in family B. Two independent training distributions reduce the chance both will hallucinate the same green.

### Step 6: Orchestrator integration

The orchestrator reads the diff in full. Not the summary, not the verifier's report alone, the actual diff. The orchestrator is the only party with full context across the stage; it is the last point at which a divergence between intent and output can be caught.

If the diff is correct and acceptance has passed, the stage is done. If either is in doubt, the orchestrator re-briefs the same tier once; on a second failure, it surfaces to the user.

### Step 7: Commit

The commit is atomic and follows the per-agent author attribution rule laid down in `~/.claude/rules/mcp-hub-dev-rules.md`: committer is the human user; author is the canonical agent identity of the primary worker. A co-author trailer is added when a second agent contributed non-trivially. The stage card is committed alongside the deliverables so the audit trail is in git, not in chat.

A dispatch involves three roles in at least two model families, so the commit records all three. The author is the worker, the coder, which keeps `git shortlog` and `git blame` attributing the code to the model that wrote it, at model-version granularity. The orchestrator and verifier are kept as `Co-Authored-By` trailers for git-native tooling, each carrying its plain canonical identity. On top of that, all three roles are recorded as role-keyed trailers carrying the clean canonical identity, so later analysis can ask which model performs best in each role:

```
Author: GPT-5.6 Sol <gpt-5-6-sol@local>

Co-Authored-By: Claude Opus 5 <claude-opus-5@local>
Co-Authored-By: Claude Sonnet 5 <claude-sonnet-5@local>
Autometta-Orchestrator: Claude Opus 5 <claude-opus-5@local>
Autometta-Worker: GPT-5.6 Sol <gpt-5-6-sol@local>
Autometta-Verifier: Claude Sonnet 5 <claude-sonnet-5@local>
```

A `Co-Authored-By` carries an identity, never a role: an annotated
`Claude Opus 5 (orchestrator)` is a different display name from a plain
`Claude Opus 5`, so the forge lists one model as two people and `git shortlog`
splits it. The role belongs in the `Autometta-*` trailers below, which is what
they are for. The `commit-msg` attribution hook strips a trailing parenthetical
from an `@local` identity, so an older card that still emits one is corrected
rather than honoured.

The orchestrator identity is read from the stage card's `Orchestrator` metadata line (it is fixed at card-authoring time); the worker and verifier come from `state.yaml`. Query one role with `git log --format='%(trailers:key=Autometta-Worker,valueonly)'` (the `Autometta-*` trailers hold the unannotated identity, so they group cleanly), and join against `state/cost-log.jsonl` for cost and token context per role. The autonomous loop emits these automatically (`scripts/tick.sh`); a manual orchestrator commit should pass the same trailer block.

**The orchestrator commits, not the worker.** The worker leaves a dirty working tree as its deliverable; the verifier evaluates that dirty tree and writes its artefact; the orchestrator reads the artefact's `overall` field and acts:

- `overall: PASS` — orchestrator stages the non-state working-tree changes and commits with `--author=<worker-identity>`, role-named `Co-Authored-By` trailers for the orchestrator and verifier, and the `Autometta-Orchestrator` / `Autometta-Worker` / `Autometta-Verifier` role trailers (see the attribution note above). The commit subject is `<stage-id>: <headline>`, where the headline comes from the verifier artefact's `headline` field if present, otherwise from the stage card's title line. The stage moves to `completed`; the commit SHA is recorded in `state/state.yaml`.
- `overall: FAIL` (or a missing / malformed `overall` field, treated as FAIL by the orchestrator) — no commit. The stage moves to `verifier_failed`, `current_stage` is cleared, and the dirty working tree is left intact for the operator to inspect, amend the stage card, and re-run, or revert.
- Backward-compat — if a worker on an older prompt self-committed before the verifier ran, the working tree on a PASS artefact will be clean. The tick logs a deprecated-path warning and marks the stage `completed` without erroring. New stages should rely on the orchestrator commit path so the `Co-Authored-By: <verifier>` trailer appears in `git log`.

**Committed is not integrated.** The commit lands on the stage's run branch, inside its own worktree. Whether it reaches the base branch depends on whether base moved between dispatch and PASS, and during an active session it usually has: any orchestrator commit to base produces it. Both outcomes are written to the stage's `integration` record in `state/state.yaml`.

- `integration.state: merged`. Base had not moved, the run branch was fast-forwarded into it, and the run worktree was removed. Nothing outstanding.
- `integration.state: awaiting`. Base had moved. The run branch is pushed to `origin` (the record's `pushed` field says whether that worked) and it, and its worktree, are left standing for a person to merge. `autometta status` prints an `awaiting integration` line for the stage until the merge happens, and `scripts/reap-worktrees.sh` will not remove the worktree while it stands; once the run branch is contained in base, the next sweep closes the record out and collects the worktree.

Neither path checks a branch out in the shared checkout at `repo_root`. See `docs/phat-controller.md` section (j).

This concentrates the commit decision at the one point where the verifier verdict is known. A worker that self-committed before the verifier ran would land its diff with an unknown verifier identity (the cross-family co-author trailer would be missing on every commit) and would force a `git revert` whenever the verifier later said FAIL. See [[memory/decision-orchestrator-commits-on-verifier-pass]] for the full rationale and rejected alternatives.

## Contract tests: freezing acceptance as executable assertions

A prose acceptance criterion describes intent; a contract test executes it. Where a stage's acceptance can be expressed as code (most code stages, and docs stages with structural checks), the card carries a contract test whose assertions are frozen at card-authoring time. The test is the committed spec: it lands green in the same commit as the deliverable, and it cannot quietly drift from what the card asked for.

This closes the gap a requirements document leaves open. A prose doc and the code diverge over time and nothing catches it; a frozen assertion fails the moment they diverge. The contract test is the executable form of the acceptance criteria, not a second source of truth alongside them.

### Separation of powers

Three roles touch the contract test, and no role both writes the assertions and satisfies them:

- **Orchestrator authors the assertions (step 1).** They are written from the card's intent, before any implementation exists, by the session that already owns the acceptance criteria. The worker does not author its own oracle, so the test cannot be tautological: it asserts what the card intended, not what the code happens to do.
- **Worker satisfies the assertions (step 3), without editing them.** The worker may add fixtures, imports, and scaffolding around the frozen block, but the assertion lines between the markers are read-only to it. A worker that believes an assertion is wrong surfaces a blocker (worker prompt step 6) rather than editing the assertion to suit its implementation.
- **Verifier runs the assertions and guards the freeze (steps 4-5).** The acceptance command is the contract test. The verifier also checks that the frozen block was not weakened: it recomputes the block digest and compares it to the digest the card declares. A changed assertion whose new digest is not recorded in the card is an automatic FAIL, independent of whether the other criteria pass.

This three-way split is stronger than worker-writes-and-verifier-checks, because the party that authors the spec (orchestrator), the party that satisfies it (worker), and the party that polices it (verifier) are three different sessions, in at least two different model families.

### The frozen block

The assertions live between two markers in the test file. The BEGIN marker names the card it belongs to:

```
# AUTOMETTA-CONTRACT-BEGIN card=examples/self-host/NN-foo.md
assert double(2) == 4
# AUTOMETTA-CONTRACT-END
```

The card records the path of the test and the digest of that block, under a dedicated heading:

```
## Contract test
- Test file: `tests/test_foo.py`
- Assertions digest: `sha256:...`
```

The digest is a fingerprint of the exact assertion lines between the markers. Because the card carries the fingerprint, the test and the card cannot move independently: changing an assertion changes the digest, and a changed digest must be re-recorded in the card or the gate rejects the commit. This is what turns "consciously change the card and the test together" from an honoured convention into a mechanical property.

### The gate

`scripts/check-contract-test-gate.sh` is the mechanical enforcement. It runs in two places:

- **At verification (primary).** The verifier runs `check-contract-test-gate.sh` against the working tree as part of acceptance. For every staged contract test it recomputes the assertion-block digest and compares it to the digest declared in the matching card. A mismatch that was not re-recorded in the card in the same change is a FAIL.
- **At commit (backstop).** The orchestrator can chain the same script into pre-commit alongside the publish-guard scan. Because the orchestrator is the only party that commits (step 7), a single mechanical check at commit time covers every stage that lands.

The gate fires only on assertion changes, never on scaffolding. A worker that reshapes a fixture, renames a helper, or moves an import leaves the frozen block untouched, the digest unchanged, and the gate silent. Only a change to the assertions themselves trips it. That precision is the point: a gate that fired on every test edit would be disarmed by habit within a week.

To regenerate the digest after a deliberate assertion change, run `scripts/check-contract-test-gate.sh print <test-file>` and paste the result into the card's `Assertions digest` line, in the same commit as the assertion change. The gate then sees a matching digest and a card that moved with the test, and passes.

### When a contract test is not warranted

Not every stage earns one. A pure-prose stage with no structural acceptance, a throwaway spike, or an exploratory card can state its acceptance in prose alone and leave the card's Contract test section as "None". The cost is real: authoring frozen assertions up front slows card creation, so spend it on durable behaviour, not on stages you expect to discard.

## The five headless gotchas

These are the failure modes documented in the source projects (fractals-from-the-90s, agentic-rag-kimble). Each one has bitten in production at least once. The contract mitigates each at a specific step; do not assume any one of them goes away on its own.

### 1. Stdin hang

A non-interactive CLI worker that reads stdin after consuming its prompt argument will block silently until the wall-clock budget expires. The canonical example is `codex exec`: it consumes the prompt arg, then reads stdin, and if stdin is a terminal it waits forever.

**Mitigated at:** step 3 (worker dispatch). The dispatch wrapper redirects stdin from `/dev/null` for every headless CLI worker. The orchestrator checklist requires this to be confirmed before dispatch.

### 2. Card-sync race

If the worker and verifier read the card from different git worktrees, or one reads while the other writes, they may act on different versions of the contract. The verifier passes a criterion the worker never had; the worker satisfies a criterion the verifier no longer checks.

**Mitigated at:** step 1 (stage card authoring) and step 4 (acceptance). The card is committed (or at minimum flushed to disk and not modified) before the worker is dispatched. The orchestrator checklist requires serialising writes before dispatch. Both worker and verifier read the card from the same committed snapshot.

### 3. Opaque log paths

If the worker writes to a path determined by a harness-generated task ID, neither the verifier nor a watching human can reliably find the output afterwards. Logs disappear into directories with names like `/tmp/<uuid>/`; debugging becomes archaeology.

**Mitigated at:** step 2 (worker prompt) and step 3 (dispatch). The stable log path is stated in the worker prompt and the card; the dispatch wrapper writes to that path explicitly. A path like `/tmp/codex-<stage-id>.log` is predictable; a harness UUID is not.

### 4. Sandbox-as-role-boundary

A worker that can run the full acceptance command inside its sandbox is a worker that can decide its own pass/fail. This is the path to hallucinated green: the worker reports success because nothing in its environment told it otherwise. The sandbox is what makes the worker unable to self-verify, and the protocol depends on this property.

**Mitigated at:** step 3 (sandbox) and step 4 (acceptance). The worker sandbox is set such that the acceptance command cannot pass inside it (read-only commits, blocked network, no side-effect tools). The verifier runs the acceptance command outside the sandbox, where it can observe the side-effects the worker was prevented from faking.

### 5. Prior-gate regression

A stage that satisfies its own acceptance criteria may break the acceptance of an earlier stage. The full acceptance suite covers more than just the current stage's deliverables, and a regression in a prior gate is still a regression.

**Mitigated at:** step 4 (acceptance) and step 6 (integration). The verifier runs the full acceptance suite, not just the current stage's checks. The orchestrator's integration step explicitly looks for regressions in prior gates and treats them as failures of this stage, not as someone else's problem.

## What the contract does not cover

The dispatch contract is for one stage. Anything that spans stages is out of scope for pass 1.

- **Queueing stages.** Pass 1 dispatches one stage at a time, by hand. Pass 2 layers a cron-driven tick on top of the dispatch contract to dispatch the next stage automatically. The loop is built on the contract, not in place of it. See the Future scope section below for the working name of the pass-2 layer.
- **State persistence across stages.** Pass 1 uses git itself: one commit per stage, with the card and the deliverables in the same commit. Pass 2 uses `state/state.yaml` and verifier artefacts under `state/verifiers/`.
- **Budget enforcement beyond wall-clock.** Pass 1 budgets are wall-clock per stage, stated in the card and enforced by the orchestrator. Pass 2 uses `state/budget.json` as a hard stop. Pass 1 has no spend ceiling beyond the orchestrator's judgement.
- **Multi-worker stages.** The contract is for one worker per stage. Parallel workers are an orchestrator-level pattern (see the agent-orchestrator skill) and use the dispatch contract per worker. Coordination between parallel workers (disjoint file sets, integration order) is the orchestrator's responsibility, not the contract's.

## Pass-2 layer

The autonomous loop now exists as `phat-controller`. It is still layered on this contract:

- `autometta tick`: one cron-safe pass-2 tick.
- `state/state.yaml`: per-repo queue state.
- `state/budget.json`: per-repo budget and halt state.
- `schemas/`: JSON schemas for the state and budget files.
- `autometta status` and `autometta attach`: read-only operator views.

### Stage statuses

A stage in `state/state.yaml` carries one of seven statuses. The enum lives in `schemas/state.yaml.json`; this is what each one means to an operator.

| Status | Terminal | Counts as a failure | Meaning |
|---|---|---|---|
| `pending` | no | n/a | Queued. The next tick with capacity dispatches the first one in order. |
| `in_progress` | no | n/a | A worker or verifier owns it. `current_stage` names it. |
| `completed` | yes | no | The verifier passed it and the orchestrator committed. |
| `failed` | yes | yes | The dispatch itself failed: no envelope, an invalid envelope, a dead agent. |
| `stalled` | yes | yes | The stage ran past its wall-clock budget plus grace, or its verifier never produced an artefact within the attempt cap. |
| `verifier_failed` | yes | yes | The verifier artefact reported `overall: FAIL`. A verdict, not a casualty. |
| `superseded` | yes | **no** | An operator decided the card should not run. |

`failed` and `stalled` are infrastructure casualties, which is why `tick.sh --repair` puts them back in the queue and `verifier_failed` and `superseded` are left alone: one is a verdict that needs the card re-briefing, the other is a decision that needs no further work at all.

#### `superseded`: a card that should not run, and that is not a failure

`superseded` says the card has been retired. Later work overtook its acceptance criteria, the thing it asked for was deliberately reverted, or the problem stopped existing. It is terminal, and the tick will not move a stage out of it:

- **Never dispatched.** Dispatch selects on `pending` alone, so a superseded stage sitting ahead of a pending one is stepped over.
- **Never reaped.** A superseded stage that is still `current_stage` is released, not stalled: `current_stage` is cleared, no stall marker is written.
- **Never counted.** `budget_record_failure` ignores it, so it cannot increment `consecutive_failures` and cannot contribute to a failure-cap halt.
- **Never alerted on.** It is absent from the alert-worthy set in `scripts/alert-statuses.sh`, which is the one definition every renderer reads.
- **Not re-queued by accident.** `scripts/requeue-stage.sh` refuses a superseded stage non-zero and names the status; `--force` is required, because re-queueing contradicts a decision someone recorded.

**The reason belongs on the card, not only in the ledger.** The status says a person decided; only the card can say why. A retirement with no recorded reason is indistinguishable next month from a failure someone hid, and the ledger row alone cannot tell those apart.

**Worked example: emergence-lab, 2026-08-23.** Four stages were sitting terminal in that subscriber's ledger and raising an alert on every refresh of every panel:

```
! 05-math-formula-rendering verifier_failed crit 6
! 14-fractal-colour-cycle-pacing verifier_failed crit 4
! 15-boids-density-motion-tuning stalled
! 16-sandpile-larger-slower failed
```

Cards 14, 15 and 16 had been overtaken by later work, and 16's own implementation was deliberately reverted ten days after it landed. None of that is failure, but `failed`, `stalled` and `verifier_failed` were the only terminal statuses available, so the ledger recorded three failures that misstate what happened and `consecutive_failures` counted them against the halt cap. Card 05 is the one to be careful with: card 40's disposition table records it as a genuine failure to leave alone, while the operator later counted it among the retired four. One of those is out of date, and which one is a question for the card, answered on the card, before its status changes.

An alert panel showing four decisions the operator has already made is the cry-wolf failure card 41 fixed for the fleet pane in another form. That is what `superseded` is for.

### Retiring a card in a running subscriber

The procedure below is what an operator runs in a subscriber repo whose loop is live. It changes one field, writes one reason, and confirms the alert has gone. Run it from the subscriber's repo root, one stage at a time.

**1. Write the reason on the card first.** Before any status changes, add a retirement note to the stage card (`docs/stages/<stage-id>.md` in most subscribers) and commit it:

```markdown
## Retired

- **Retired:** 2026-08-24 by <operator>
- **Reason:** superseded by <what overtook it>, which landed in <commit or card>.
- **Not a failure:** the acceptance criteria below were overtaken, not missed.
```

If the ledger and the card disagree about why a stage is terminal, as emergence-lab 05 does, settle that here. A status change made before the reason is written loses the reason.

**2. Stop anything still running for that stage.** If the stage is in flight, its agent and run worktree go first, otherwise the next tick supervises work nobody wants:

```sh
pkill -F state/active-agents/<pid>.json 2>/dev/null || true   # only if one is live
scripts/requeue-stage.sh --worktree-only . <stage-id>
```

**3. Set the status.** One field, via the same yq to jq round-trip the tick uses, so the rest of the file is untouched:

```sh
tmp="$(mktemp)"
yq -o=json '.' state/state.yaml | jq --arg id "<stage-id>" '
  .current_stage = (if .current_stage == $id then null else .current_stage end)
  | (.stages[] | select(.id == $id)).status = "superseded"' | yq -P '.' > "$tmp"
mv "$tmp" state/state.yaml
```

**4. Clear the failure it recorded, if it recorded one.** Retiring a stage that had been counted as a failure is the operator saying that failure is dealt with, exactly as a re-queue is. It does not clear a halt whose spend caps are still blown; that is `autometta tick --reset-halt`'s job and a separate decision:

```sh
jq '.consecutive_failures = 0' state/budget.json > state/budget.json.tmp
mv state/budget.json.tmp state/budget.json
```

**5. Confirm the alert has gone.** The dashboard data is a cache, so refresh it before reading any pane, or the alert appears to persist for another refresh interval:

```sh
scripts/aggregate-dashboard.sh
PHAT_CONTROLLER_FLEET_ONCE=true scripts/attach.sh --fleet-ticker | sed -n '/^ALERTS/,$p'
scripts/agent-ticker.sh . --once | sed -n '/^ALERTS/,/^$/p'
```

The retired stage should appear in neither. Every other alert should still be there: a pane that went quiet altogether means the filter is wrong, not that the fleet is healthy. `scripts/superseded-status-smoke.sh` asserts both directions offline.

Repeat per stage. Four retirements are four runs of this procedure, four reasons written, and one confirmation at the end.

### Canonical `halt_reason` values

When `state/budget.json` is marked `halted: true`, the `halt_reason`
field carries one of the following canonical strings. The set is
closed — every call to `budget_halt` in the loop writes one of these,
and nothing else overwrites a pre-existing reason on subsequent ticks:

- `token-cap` — `tokens_spent >= token_cap_total`.
- `wall-clock-cap` — `wall_clock_elapsed_seconds >= wall_clock_cap_seconds`.
- `tick-cap` — `clock_ticks_used >= clock_tick_cap`. Work ticks only: a
  tick that found nothing to do charges `idle_ticks_used` instead.
- `idle-tick-cap` — `idle_ticks_used >= idle_tick_cap`. Only reachable
  where an operator has set `idle_tick_cap`; it is absent by default.
- `failure-cap` — `consecutive_failures >= consecutive_failure_cap`.
- `yq-missing` — the `yq` binary required to read `state/state.yaml`
  was not on PATH.
- `invalid-stage-id` — `current_stage` (or a referenced stage id) failed
  the id-format validator.

`dirty-working-tree` is retired as of the worktree-per-run backport (see
below): dispatch happens in an ephemeral sibling worktree, never
`repo_root`, so `commit_state_branch` no longer guards on a clean tree
before committing state files. Any budget file with this reason recorded
from before the backport is historical only; `budget_ensure_window`
clears it at the start of the next run window regardless of reason (see
"Budget window auto-reset" below), so it is not sticky.

`budget_check_caps` distinguishes "real cap hit this tick" (return code
1; one of the first four strings is selected via the
`BUDGET_CHECK_LAST_HIT` side channel) from "already halted on a previous
tick" (return code 2; caller must preserve the recorded reason rather
than overwrite it).

**`budget_ensure_window` is the only thing that clears a halt.** Nothing
else in the loop unlatches one, by design: two clearing paths in one file
is how a halt stops meaning anything, and the budget file is the only
safety the design has. An operator clears a halt by editing
`state/budget.json`, or `scripts/requeue-stage.sh` clears a `failure-cap`
halt as part of re-queueing (and refuses, non-zero, if a spend cap is
still blown). A halt whose cause is no longer true is not re-tested
mid-window; it holds until the window rolls.

The rc-2 log line is rate-limited rather than emitted every tick.
`budget_should_log_halt` (`scripts/budget.sh`) allows one line per
`halt_reason` per `PHAT_CONTROLLER_HALT_LOG_INTERVAL` seconds (default
3600), always logs immediately on a change of reason, and stamps
`halt_logged_at` / `halt_logged_reason` in the budget file. It decides
what is written to the log and nothing else — it never clears a halt.

### Worktree-per-run dispatch

Backported from the emergence-viewer stage-44 pilot (`memory/adopters/
emergence-viewer/feedback-worktree-dispatch-thinned-preflight.md`). Each
stage dispatches into an ephemeral sibling worktree (`../<repo>-run-<stage-id>`,
branch `autometta/<stage-id>`) cut from a base branch resolved by
`resolve_base_branch` in `tick.sh` (the subscriber/manifest `base_branch`
field if set, else the repo's current branch at dispatch time). The stage's
`base_branch` is persisted to `state/state.yaml` at dispatch so a later PASS
can detect whether the base moved in the meantime.

`repo_root`'s `state/` directory stays the single source of truth for
`state.yaml`, `budget.json`, logs, handoff envelopes, and verifier
artefacts — the worktree gets a symlink (`state -> ../<repo>/state`) rather
than its own copy, so a worker or verifier writing to a `state/...`-relative
path (as the worker/verifier prompt templates already instruct) lands in
the shared location without any template change.

On PASS, `tick.sh` commits the worker's non-state changes on the run branch
inside the worktree, then fast-forwards the base branch to it if the base
hasn't moved; if the base has moved, it pushes the run branch to `origin`
instead and appends a note to `HANDOFF.md`, leaving branch and worktree
standing for manual integration. On FAIL, both are always left standing for
operator review — `scripts/requeue-stage.sh` / the `autometta-requeue`
skill remove them before a re-dispatch.

### Budget window auto-reset

`budget_ensure_window` (in `scripts/budget.sh`) runs at the start of
`_process_repo_locked`, before `budget_check_caps`. It compares
`state/budget.json`'s `window_started_at` (a UTC calendar date) to today;
on a mismatch, a *halted or at-cap* budget has every counter — including
`consecutive_failures` — zeroed, `halted`/`halt_reason`/`halted_at`
cleared, and caps left untouched, with a log line recording the reset. A
healthy budget crossing the same boundary is only re-stamped, not zeroed,
so an in-progress run spanning midnight UTC is unaffected. Within a
window this is a no-op: a halt or cap hit (including `failure-cap`) still
holds, and `consecutive_failures` keeps accumulating and can still halt
the loop mid-window.

### Which token cap binds: host default, repo override, drain

The daily token cap is a host decision. It is written once by
`scripts/init-host.sh` into `~/.phat-controller/config.yaml` as
`token_cap_total`, and every subscribed repo inherits it. A repo sets its own
`token_cap_total` in `state/budget.json` only where it genuinely differs.

`budget_effective_token_cap` (in `scripts/budget.sh`) is the single place that
answers the question, and every token comparison in that file goes through it.
First hit wins:

| Order | Source | Where |
|---|---|---|
| 1 | An active drain | `~/.phat-controller/drain.json`, while unexpired |
| 2 | The repo's own cap | `state/budget.json` `token_cap_total`, when present |
| 3 | The host default | `token_cap_total:` in the controller `config.yaml` |
| 4 | The floor | `AUTOMETTA_TOKEN_CAP_FLOOR`, 20,000,000 by default |

Rule 4 is why the resting state is never unlimited. A repo with no cap of its
own, on a host whose config predates this, is still capped; the floor is small
enough to be noticed rather than large enough to be harmless.
`budget_cap_source` names the winning rule for the log and the dashboard, and
`AUTOMETTA_HOST_TOKEN_CAP` overrides the config file for one invocation.

The spread this replaced was accumulated history, not policy: five subscribers
carried 3,000,000 / 8,000,000 / 100,000,000 / 150,000,000 between them and
nothing recorded why any of them held its number.

### Drain mode: the deliberate overnight run

A daily cap catches a runaway. An overnight drain is the opposite intent:
spend the provider window down on purpose and stop when the *provider* stops,
around 01:00. The two used to be the same number. On 2026-08-23
emergence-lab spent 104,942,068 against its 100,000,000 cap during a
deliberate drain: the gate refused a verifier dispatch at 00:01 with a
finished worker sitting on a passing envelope, re-halted through two attempts
to clear it, and released only when the midnight window reset zeroed the
counter at 01:01. The cap was doing its job; the number did not describe the
intent.

A drain is host-level, per run, and self-expiring:

```sh
autometta drain start --cap 400000000 --hours 8 --reason "weekly window drain"
autometta drain start --lift --hours 6          # up to AUTOMETTA_DRAIN_LIFT_CAP
autometta drain start --cap 400000000 --repo /path/to/repo   # repeatable; default is all
autometta drain status
autometta drain end
```

- **Explicit.** `--cap N` or `--lift` is required; a drain with no stated cap
  is not a decision. `--lift` resolves to `AUTOMETTA_DRAIN_LIFT_CAP`
  (1,000,000,000), an integer rather than a null, because every cap comparison
  is a numeric test and `tokens_spent >= null` is not a safety.
- **Visible.** `tick.sh` logs `drain active for <repo>: token cap N until
  <time>` on every tick a drain is in force. A cap that moved silently is
  indistinguishable from a cap that was never there.
- **Self-expiring.** `expires_at` is enforced on read: the first caller past it
  moves `drain.json` to `drain.expired.json` and the resting cap applies again.
  Default 8 hours, maximum 12 (`AUTOMETTA_DRAIN_MAX_SECONDS`). There is no path
  where a drain keeps binding past its own clock.
- **Non-destructive.** No repo's `budget.json` is edited, so there is nothing
  to remember to put back.
- **Not a halt clearer.** A halt already latched survives the drain with its
  original `halt_reason`. Raising a cap is not a licence to unlatch a halt that
  was correctly taken; that stays `tick.sh --reset-halt`.

`scripts/cap-resolution-smoke.sh` asserts all of the above offline, including
the expiry and the refusal from the incident.

### Token accounting

`state/budget.json` carries `tokens_spent` and an optional `token_cap_total`. The
loop increments `tokens_spent` after each worker and verifier phase by
parsing the captured CLI log; `token-cap` then becomes an enforceable
halt reason rather than a decorative field.

- **Who increments.** `tick.sh` is the sole writer. The spawn scripts
  (`spawn-worker.sh`, `spawn-verifier.sh`) source `budget.sh` but cannot
  account in-band because they background the worker / verifier process
  and exit immediately so the cron tick is not blocked by a 30-minute
  run.
- **When.** Post-exit, on the same tick that reaps the phase:
  - Worker phase — when `worker_pid` was recorded on a previous tick but
    `kill -0` now fails. Accounting fires once, then `worker_pid` is
    cleared in `state.yaml` so subsequent ticks (still waiting on the
    verifier) do not double-count.
  - Verifier phase — when the verifier artefact is present at
    `state/verifiers/<stage-id>.json`. Accounting fires immediately
    before `_process_verifier_artefact`, which clears `current_stage`
    on exit. If a prior verifier crashed without writing an artefact and
    is being re-dispatched, its log is accounted for and `verifier_pid`
    is cleared before the fresh dispatch.
- **From what.** `budget_parse_tokens_from_log` (in `scripts/budget.sh`)
  scans the captured stdout/stderr log for either family format:
  - Codex two-line: a line that is exactly `tokens used`, followed by a
    line whose first token is a digit run (commas tolerated).
  - Claude inline: any line containing `Total tokens:` followed by a
    digit run (commas and spaces tolerated).
  When both appear in one log — for example a worker that retried — the
  **last match wins**. Earlier numbers are treated as cumulative
  subtotals or aborted-attempt counts; only the final figure is the
  authoritative usage. The parser is pure awk, bash 3.2-compatible, no
  python / node dependency.
- **Failure mode.** A missing log, a log with no token line, or a
  non-numeric capture is **non-fatal**: the parser logs a warning to
  stderr and returns without mutating `tokens_spent`. The phase is
  treated as having spent zero, which is a known undercount; the
  `wall-clock-cap` and `tick-cap` paths still provide a backstop.
- **Cap enforcement is automatic.** The next `budget_check_caps` after
  the increment will surface the `token-cap` halt reason if
  `tokens_spent >= budget_effective_token_cap`. No new gate is added.

## Which autometta runs: root resolution

There are two autometta trees on a working machine: the Homebrew install under
`Cellar/autometta/<sha>/libexec`, and the git checkout it was packaged from.
Every invocation picks one. Until card 42 each entry point picked for itself,
and on 2026-08-23 that produced two wrong answers in a single day: a committed
fix was live for the fleet tick while the installed build still held the old
file, and `autometta --version` reported whichever root the caller happened to
land on, so it could not be used to settle the question either.

### The rule

One rule, in `scripts/resolve-root.sh`, and nowhere else. Two functions, for
two different questions.

`autometta_resolve_root` answers "whose `scripts/` will this dispatch run?".
First hit wins:

| Precedence | Source | Typical setter |
|---|---|---|
| 1 | `AUTOMETTA_ROOT` in the environment | an operator, or the fleet LaunchAgent |
| 2 | `autometta_root:` in `$PHAT_CONTROLLER_HOME/config.yaml` | `scripts/init-host.sh`, at host bootstrap |
| 3 | the tree the running command is part of | nothing; it is the floor |

Rules 1 and 2 are honoured only when they name a directory that actually holds
a `scripts/` directory. A stale config entry pointing at a moved or deleted
checkout falls through to the floor instead of yielding a root with no code in
it. Rule 3 is always available, so resolution terminates without ever needing a
hardcoded home-directory path.

`autometta_self_root` answers a different question: "which tree am I part of?".
Packaging and host bootstrap act on themselves, so `install-homebrew-local.sh`
and `init-host.sh` use this one. An installer that honoured `AUTOMETTA_ROOT`
would package a tree it was never pointed at.

Every entry point that needs a root sources `resolve-root.sh` and calls one of
the two. None of them restates the rule inline, so there is exactly one place
to change it and exactly one place to read it.

| Uses `autometta_resolve_root` (the effective root) | Why |
|---|---|
| `bin/autometta` | dispatches every subcommand into the resolved tree's `scripts/` |
| `scripts/attach.sh` | the tmux panes run autometta scripts, and a viewer watching a different tree than the tick executes is the split itself |
| `scripts/subscribe-repo.sh` | records `autometta_root:` in the subscriber manifest, which is the tree that will run that repo's dispatches. It used to carry its own copy of the config-then-self precedence |

| Uses `autometta_self_root` (the tree it is part of) | Why |
|---|---|
| `scripts/install-homebrew-local.sh` | packages the checkout it lives in |
| `scripts/init-host.sh` | writes its own path into the controller config |
| `scripts/install-launchagent.sh` | reads its own plist template; which root the installed tick then runs is the plist's `AUTOMETTA_ROOT`, an operator decision |
| `scripts/dashboard.sh` | copies dashboard sources out of its own tree |
| `scripts/auth.sh`, `scripts/spawn-worker.sh`, `scripts/spawn-verifier.sh`, `scripts/spawn-verifier-panel.sh` | `op-refs.sh` sits beside them |
| `scripts/retro-grade.sh` | cd's into its own tree and sources that tree's `op-refs.sh` |
| `scripts/check-deps.sh` | answers whether the tree it was launched from is complete, so pointing it elsewhere would defeat the check |
| the `*-smoke.sh` harnesses | a smoke test exercises the tree it ships in |

Scripts that compute a `repo_root` for their own fixtures
(`validate-handoff-envelope.sh`, `validate-verifier-artefacts.sh`,
`sdk-cache-smoke.sh`, `idle-tick-smoke.sh`, `superseded-status-smoke.sh`) are
not resolving a dispatch root and are left alone.

Checkout detection compares physical paths on both sides. `git rev-parse
--show-toplevel` reports a physical path, so a root reached through a symlinked
parent (on macOS `/tmp` is `/private/tmp`) would otherwise compare unequal to
its own toplevel, be called "not a checkout", and have its uncommitted edits go
unreported. That is the same class of silent wrong answer as the original split.

`scripts/autometta-vendor-check.sh` keeps its own `${AUTOMETTA_ROOT:-~/repos/autometta}`
lookup on purpose. It runs inside a *subscriber* repo, where `scripts/resolve-root.sh`
does not exist, and it is locating the canonical upstream checkout rather than
resolving its own root.

### Telling the truth about it

`autometta --version` now names the root, the rule that chose it, the sha, and
whether the working tree is dirty:

```
autometta 384c394
  root:   ~/repos/autometta
  origin: controller config ~/.phat-controller/config.yaml
  sha:    384c394 (git checkout)
  state:  DIRTY 1 tracked file(s) modified under scripts/
            scripts/tick.sh
  warning: uncommitted edits in this root run on the next tick.
```

Dirty means tracked files under `scripts/` differing from `HEAD`, staged or
not. Untracked files are excluded: a scratch file in `scripts/` is not code a
dispatch runs, whereas an edited tracked script is. A root that is not a git
checkout reports its `VERSION` stamp and `state: installed build, immutable`.

Detection is deliberately exact about what counts as a checkout: `git -C` searches
upward, and the Homebrew prefix is itself a git repository, so a naive rev-parse
inside `libexec` reports Homebrew's HEAD and calls the installed build a clean
checkout. The root must be the top level of the working tree, not merely inside one.

### The dirty-checkout exposure

With the checkout as the resolved root, the working tree is production. Any
half-finished edit to a tracked file under `scripts/` is load-bearing for every
subscribed repo at the next tick, with no commit, no review and no verifier
between the edit and the fleet. That is the sharper half of the split, and it is
why the dirty state is on the face of `--version` rather than something an
operator has to think to check.

The fleet LaunchAgent currently sets `AUTOMETTA_ROOT` to the checkout, which is
rule 1, so this exposure is live. Moving the tick onto the installed build is an
operator decision, not a code change: it means deleting that key from
`com.autometta.tick.fleet.plist` and accepting that a fix is live only after a
reinstall. Nothing in the repo repoints a running fleet.

### Checking the split

`scripts/check-installed-build.sh` compares the two trees file by file and then
states, from the LaunchAgent's own environment rather than from assumption,
which root the fleet tick will run. Exit 0 when they agree, 1 on drift naming
each differing file, 2 when either side is missing. It is also
`autometta check-build`, and `scripts/health-check.sh` runs it on every doctor
pass so the split is surfaced without anyone having to remember to ask. The
doctor reports it but does not fail on it: drift is an ordinary operator state,
and clearing it replaces files a running tick is executing, so it should be
cleared when no dispatch is in flight.

## Reading order for a new operator

1. This document.
2. `templates/stage-card.md`: the template you fill in to dispatch.
3. `templates/worker-prompt.md`: the invariant rules the worker reads.
4. `templates/orchestrator-checklist.md`: run through this before every dispatch.
5. `docs/lessons.md` (stage 1): the gotchas in more detail, with incident notes from the source projects.
6. `docs/verification.md` (stage 1): the gate model, in more detail than the acceptance section here.
7. `docs/setup.md`, `docs/deployment.md`, and `docs/observability.md`: pass-2 operator flow.
8. `examples/self-host/`: real stage cards used to build Autometta itself.
