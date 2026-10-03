# Stage card 144: the operator can inspect the dependency graph

## Metadata

- **Authored:** 2026-10-03
- **Orchestrator:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Worker:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Verifier:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Base branch:** dev
- **Run branch:** autometta/144-the-operator-can-inspect-the-dependency-graph
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Dispatch:** serial
- **Gate:** stage-completed: 143-stage-cards-declare-all-their-prerequisites
- **Pairing rationale:** Opus finishes the operator surface and diagnoses integration gaps; Terra verifies the full offline lifecycle against real tick functions.

## Objective

Expose the graph and its blockers through a read-only operator command, and
prove graph dispatch survives a restarted tick without duplicate workers or
bypassing the existing admission gates.

## Inputs (read these in your own context)

- `stage-cards/142-dependency-readiness-has-evidence.md` and
  `stage-cards/143-stage-cards-declare-all-their-prerequisites.md`.
- `scripts/dependency-graph.sh`, `scripts/dependency-graph-smoke.sh`.
- `bin/autometta`, `scripts/resolve-root.sh`, `scripts/status.sh`.
- `scripts/tick.sh`, `scripts/landing-dispatch-smoke.sh`,
  `scripts/landing-rebase-smoke.sh`, `scripts/vendor-set.sh`.
- `docs/dependency-graph.md`, `docs/runbook.md`, `README.md`.

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `bin/autometta` adds `autometta graph --repo <path> [--json]`, using the existing
   root resolver and actual configured base-branch resolution. Default the repo
   to the current directory. Add help text and route to the inspector rather
   than duplicating its dependency rules. A small formatting script is allowed.
2. JSON output is the exact 142 report, with matching exit codes. Human output
   shows stage IDs, prerequisite edges and named blockers, and explicitly labels
   readiness as dependency readiness rather than permission to dispatch. It
   distinguishes ordinary waiting from invalid graphs. The command reads no
   credentials and changes no state, budget, counters, refs or worktrees.
3. `docs/dependency-graph.md` becomes an executable operator guide with a small
   fork/join example, topological queue commands, serial execution, target-base
   evidence, failure/blocker meaning and how to inspect a stopped run. Distinguish
   failed work from a quota/budget halt; neither is automatically cleared.
   Explain that a graph is executed by the existing tick, and that this is a
   coding-stage DAG, not a new agent family or generic workflow engine.
4. `README.md` and `docs/runbook.md` link the command and migration guidance.
   State that legacy gates keep their existing status-only meaning. Document
   a separate future install/refresh step, because editing the checkout does
   not update an installed Homebrew CLI. No install or fleet refresh in this card.
5. Correct any integration defect exposed by the frozen `lifecycle` mode within
   `scripts/tick.sh`, the inspector or the CLI. Keep the patch narrow; do not
   change the oracle to accommodate implementation behaviour.

## Constraints

- The fixture may stub provider executables, admission outcomes and controller
  bookkeeping. It must execute the production selector, state transitions,
  worktree creation and `_process_repo_locked` path in separate shell processes.
  Do not stub readiness or write the expected child status from the smoke.
- All tests stay offline in temporary repositories with isolated controller
  homes. Never register a fixture in the live subscriber registry, call the
  real provider CLIs or fire the installed fleet tick.
- Only dependencies are reported as ready. Quota, budget, network and explicit
  pauses remain separate admission conditions checked at dispatch time.
- Keep model families interchangeable at the worker seat; independent
  cross-family verification and frozen acceptance remain compulsory.
- Freeze ownership and serial landing rules from 142 and 143 continue to apply.

## Acceptance criteria

1. The opposite-family verifier runs `bash scripts/dependency-graph-smoke.sh all`.
   All modes pass, including separate-process restart, exactly one worker spawn,
   blocked budget/quota/network admission, unrelated work after a failed parent,
   CLI/inspector parity and read-only inspection. The alive worker is a fixture
   PID; no model process is started.
2. Run `bash scripts/dependency-graph-smoke.sh lifecycle` against a detached
   dispatch-base checkout using `AUTOMETTA_GRAPH_TEST_ROOT`. Record which tests
   already pass after 143 and the missing public-command failure. Candidate
   must pass all; do not claim the earlier lifecycle passes as new work.
3. Independently replay a join with parents on two scratch branches. A PASS
   still awaiting integration does not release the join; after both are landed,
   it dispatches once. Restart the tick process and show the persisted PID and
   unchanged spawn count. Existing global stops must still win over readiness.
4. Run `bash scripts/landing-dispatch-smoke.sh` and
   `bash scripts/landing-rebase-smoke.sh` on base and candidate. Record exact
   inherited failures separately; any new failure fails this card. Existing
   cross-family verifier handling and landing must remain intact.
5. From a directory outside the fixture repository, invoke the checkout CLI
   with `AUTOMETTA_ROOT` explicitly set to the candidate checkout. Compare its
   JSON to direct inspection and show unchanged state/budget bytes and Git refs.
   Inspect command errors for missing repo/state/base as well as invalid graph.
6. Run `bash -n bin/autometta` plus every changed shell file, recompute the shared
   frozen digest, and run `bash scripts/check-contract-test-gate.sh --worktree`.
   An unchanged-test exit 2 requires the explicit digest check, as in 142.

## Out of scope

TUI/dashboard geometry changes, new graph rendering packages, concurrency wider
than the existing legacy pipeline, automatic repair, provider changes,
Homebrew installation, live admission, queue dispatch and public publication.

## Contract test

- **Test file:** scripts/dependency-graph-smoke.sh
- **Assertions digest:** `sha256:f540c3557c277689089b7ee01e2baada0731df83fe88fb906b241a4588209098`

The orchestrator froze one shared oracle for cards 142-144 before dispatch.
Its marker names 142; every card records the same digest. Run only this card's
specified modes until 144 runs them all. All assertion and fixture code inside
the block is immutable to workers. A re-brief must update all three digest lines.

## Budget

- **Worker wall-clock:** 30 minutes
- **Verifier wall-clock:** 25 minutes
- **Spend basis:** see the dated 142-144 batch in `stage-cards/PLAN.md`.
  Shared planning allowance 18M tokens, subject to live admission; no cap change
  or drain is authorised by this card. A retry requires a fresh spend estimate.

## Dispatch envelope

Write `state/envelopes/144-the-operator-can-inspect-the-dependency-graph.json` using
`schemas/envelope.json`. List changed deliverables, exact commands,
before/after results, inherited failures and unresolved criteria. The verifier
writes `state/verifiers/144-the-operator-can-inspect-the-dependency-graph.json` under the
existing verifier contract, giving a criterion-by-criterion verdict. Do not
self-verify or land your own branch. After independent PASS, the orchestrator
lands this stage before its successor is admitted; if integration is awaiting,
stop this batch before queueing its successor even though the legacy gate says
completed. No headless conflict resolution.

## Family-specific notes

The implementation is family-neutral. Use the declared Opus/Terra pair through
normal auth-route and quota admission. If the operator swaps the worker family,
swap the verifier to the other family and update metadata and rationale before
queueing. Do not use an ambiguous `Opus or Terra` identity in a dispatched card.
