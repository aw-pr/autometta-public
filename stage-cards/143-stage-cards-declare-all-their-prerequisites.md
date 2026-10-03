# Stage card 143: stage cards declare all their prerequisites

## Metadata

- **Authored:** 2026-10-03
- **Orchestrator:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Base branch:** dev
- **Run branch:** autometta/143-stage-cards-declare-all-their-prerequisites
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Dispatch:** serial
- **Gate:** stage-completed: 142-dependency-readiness-has-evidence
- **Pairing rationale:** Terra implements the bounded parser, schema and scheduler integration; Opus verifies the admission and serial-execution boundaries.

## Objective

Allow a stage card to name every prerequisite. Dispatch it only after all named
results are available on its starting branch. Keep graph work serial, preserve
legacy gates, and continue to eligible independent work when a parent is blocked.

## Inputs (read these in your own context)

- `stage-cards/142-dependency-readiness-has-evidence.md`, `docs/dependency-graph.md`.
- `scripts/dependency-graph.sh`, `scripts/dependency-graph-smoke.sh`.
- `scripts/add-stage.sh`, `schemas/state.yaml.json`, `templates/stage-card.md`.
- `scripts/tick.sh`: selector, pending dispatch, pipeline formation and gate checks.
- `scripts/gate-smoke.sh`, `scripts/pipeline-pair-smoke.sh`.

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/add-stage.sh` accepts one new metadata line:
   `- **Depends on:** 21-backend, 22-frontend`.
   Parse full IDs into `depends_on: [21-backend, 22-frontend]`, preserving their
   declared order. Before writing, use 142's validator on the prospective queue.
   Require referenced stages to exist already, so queueing is topological.
   Empty, duplicate, self, malformed, missing and cyclic prerequisites are
   refused with the offending card/IDs and no change to queue bytes. Reject
   duplicate metadata lines, combination with any `Gate`, and combination with
   `Path claims`; new dependency cards must declare `Dispatch: serial`.
2. `schemas/state.yaml.json` declares optional `depends_on` as a non-empty unique
   array of full stage IDs. Keep `additionalProperties: false`, schema version
   and old records unchanged. Structural checks beyond JSON Schema belong to
   the shared inspector, not a second graph implementation.
3. `scripts/tick.sh` uses the inspector for new graph readiness and honours it
   through `dispatch_pending_stage_if_available` and the post-landing dispatch
   route. Resolve the actual intended base using existing base-branch policy
   before inspecting prerequisites. Extend the selector compatibly to
   `select_next_dispatchable_stage <state-file> [repo-root] [base-branch]`;
   existing one-argument callers keep working. Select the first eligible pending
   stage in stable queue order. An unmet dependency changes no stage status,
   attempts or failure counters; log the exact parent and reason. Re-evaluate
   at each fire, so later integration can release the child without requeueing.
4. `scripts/tick.sh` refuses a pipeline pair if either head or tail is a member
   of a new dependency graph, even when claims are disjoint, headroom is ample
   and `pair_on: off`. Parent roots are members too. Preserve existing legacy
   pair behaviour for unrelated work. This version does not create a multi-node
   scheduler or change the one-active-stage graph limit.
5. `templates/stage-card.md` and `docs/dependency-graph.md` document the new field,
   queue order, commit evidence and legacy compatibility; 144's operator CLI
   remains labelled as pending. Update `docs/tick-loop.md` at the relevant gate
   and pipeline sections.

## Constraints

- Preserve `stage-completed` and `queue-empty` semantics for existing cards.
  In particular a legacy completion gate still tests its recorded status only;
  explain its weaker guarantee rather than silently migrating it. The new field
  is the explicit opt-in to landed-code semantics.
- Never accept queue syntax before the tick can enforce it in the same commit.
  No live state migrations. Invalid imported graph state blocks graph dispatch,
  logs an actionable diagnosis and leaves independent legacy work eligible.
- Dependency readiness is necessary but not sufficient: existing global halt,
  quota/freshness, budget, network, role and acceptance gates still apply.
  Do not turn a graph blocker into a global halt or automatically reset one.
- Keep the tick's existing lock and atomic state writer. Inspection must not
  publish readiness state that can go stale between fires. Do not duplicate
  142's graph logic in the normal selector and the pipeline path.
- No retry policy, attempt reset, budget lift, API fallback or paid call.
- The frozen shared oracle is unchanged, including helper and fixture code.

## Acceptance criteria

1. The opposite-family verifier runs both
   `bash scripts/dependency-graph-smoke.sh inspect` and
   `bash scripts/dependency-graph-smoke.sh dispatch`. All tests pass. The latter
   exercises real queue parsing, JSON Schema, the production selector and the
   real pipeline pair dispatcher, with a positive legacy-pipeline control.
2. Preserve before/after evidence by running the same `dispatch` mode against a
   detached dispatch-base checkout via `AUTOMETTA_GRAPH_TEST_ROOT`. Baseline
   admission ignores the new line; candidate admission stores and enforces it.
   A syntax-only or inspector-only pass cannot satisfy this criterion.
3. In a scratch repository, queue parents first and a child second through
   `scripts/add-stage.sh`, then run the actual pending-dispatch route with
   stubbed provider executables. The child stays pending until every required
   tip is on its intended base. Repeat with a failed parent and an independent
   stage. Keep the evidence; do not manually assign the expected child result.
4. Compare `bash scripts/gate-smoke.sh` and
   `bash scripts/pipeline-pair-smoke.sh` on the dispatch base and candidate in
   isolated fixtures. Existing failures are recorded by exact assertion and
   output; any additional failure is a regression and fails this card. The
   graph contract itself has no baseline exemption.
5. `bash -n scripts/add-stage.sh scripts/tick.sh scripts/dependency-graph.sh`
   passes. Recompute the shared frozen digest and run
   `bash scripts/check-contract-test-gate.sh --worktree`; handle exit 2 as
   described in 142, never as proof of the frozen assertions.

## Out of scope

General parallel scheduling, schema migration of historical stages, automatic
repair/retry graphs, changing `completed` globally, GUI or dashboard redesign,
and deployment to the installed CLI or subscribers.

## Contract test

- **Test file:** scripts/dependency-graph-smoke.sh
- **Assertions digest:** `sha256:f540c3557c277689089b7ee01e2baada0731df83fe88fb906b241a4588209098`

The orchestrator froze one shared oracle for cards 142-144 before dispatch.
Its marker names 142; every card records the same digest. Run only this card's
specified modes until 144 runs them all. All assertion and fixture code inside
the block is immutable to workers. A re-brief must update all three digest lines.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 25 minutes
- **Spend basis:** see the dated 142-144 batch in `stage-cards/PLAN.md`.
  Shared planning allowance 18M tokens, subject to live admission; no cap change
  or drain is authorised by this card. A retry requires a fresh spend estimate.

## Dispatch envelope

Write `state/envelopes/143-stage-cards-declare-all-their-prerequisites.json` using
`schemas/envelope.json`. List changed deliverables, exact commands,
before/after results, inherited failures and unresolved criteria. The verifier
writes `state/verifiers/143-stage-cards-declare-all-their-prerequisites.json` under the
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
