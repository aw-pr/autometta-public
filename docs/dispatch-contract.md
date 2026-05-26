# The dispatch contract

This is the load-bearing document for Autometta pass 1. It describes the protocol by which an orchestrator dispatches one unit of work to one worker, with one verifier checking the result, and the orchestrator integrating. Everything else in pass 1 (the templates, the examples, the self-host plan) is an instance of this contract.

The contract is family-agnostic. The same shape works for a Claude Code worker, a Codex CLI worker, or any future CLI worker. Where a step is genuinely family-specific, it is called out under a family-specific notes heading rather than hard-coded into the protocol.

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

**The orchestrator commits, not the worker.** The worker leaves a dirty working tree as its deliverable; the verifier evaluates that dirty tree and writes its artefact; the orchestrator reads the artefact's `overall` field and acts:

- `overall: PASS` — orchestrator stages the non-state working-tree changes and commits with `--author=<worker-identity>` and a `Co-Authored-By: <verifier-identity>` trailer. The commit subject is `<stage-id>: <headline>`, where the headline comes from the verifier artefact's `headline` field if present, otherwise from the stage card's title line. The stage moves to `completed`; the commit SHA is recorded in `state/state.yaml`.
- `overall: FAIL` (or a missing / malformed `overall` field, treated as FAIL by the orchestrator) — no commit. The stage moves to `verifier_failed`, `current_stage` is cleared, and the dirty working tree is left intact for the operator to inspect, amend the stage card, and re-run, or revert.
- Backward-compat — if a worker on an older prompt self-committed before the verifier ran, the working tree on a PASS artefact will be clean. The tick logs a deprecated-path warning and marks the stage `completed` without erroring. New stages should rely on the orchestrator commit path so the `Co-Authored-By: <verifier>` trailer appears in `git log`.

This concentrates the commit decision at the one point where the verifier verdict is known. A worker that self-committed before the verifier ran would land its diff with an unknown verifier identity (the cross-family co-author trailer would be missing on every commit) and would force a `git revert` whenever the verifier later said FAIL. See [[memory/decision-orchestrator-commits-on-verifier-pass]] for the full rationale and rejected alternatives.

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

### Canonical `halt_reason` values

When `state/budget.json` is marked `halted: true`, the `halt_reason`
field carries one of the following canonical strings. The set is
closed — every call to `budget_halt` in the loop writes one of these,
and nothing else overwrites a pre-existing reason on subsequent ticks:

- `token-cap` — `tokens_spent >= token_cap_total`.
- `wall-clock-cap` — `wall_clock_elapsed_seconds >= wall_clock_cap_seconds`.
- `tick-cap` — `clock_ticks_used >= clock_tick_cap`.
- `failure-cap` — `consecutive_failures >= consecutive_failure_cap`.
- `dirty-working-tree` — the repo working tree was not clean when the
  tick attempted to advance state.
- `yq-missing` — the `yq` binary required to read `state/state.yaml`
  was not on PATH.
- `invalid-stage-id` — `current_stage` (or a referenced stage id) failed
  the id-format validator.

`budget_check_caps` distinguishes "real cap hit this tick" (return code
1; one of the first four strings is selected via the
`BUDGET_CHECK_LAST_HIT` side channel) from "already halted on a previous
tick" (return code 2; caller must preserve the recorded reason rather
than overwrite it).

### Token accounting

`state/budget.json` carries `tokens_spent` and `token_cap_total`. The
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
  `tokens_spent >= token_cap_total`. No new gate is added.

## Reading order for a new operator

1. This document.
2. `templates/stage-card.md`: the template you fill in to dispatch.
3. `templates/worker-prompt.md`: the invariant rules the worker reads.
4. `templates/orchestrator-checklist.md`: run through this before every dispatch.
5. `docs/lessons.md` (stage 1): the gotchas in more detail, with incident notes from the source projects.
6. `docs/verification.md` (stage 1): the gate model, in more detail than the acceptance section here.
7. `docs/setup.md`, `docs/deployment.md`, and `docs/observability.md`: pass-2 operator flow.
8. `examples/self-host/`: real stage cards used to build Autometta itself.
