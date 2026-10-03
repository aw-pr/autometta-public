# Stage card 142: dependency readiness has evidence

## Metadata

- **Authored:** 2026-10-03
- **Orchestrator:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Worker:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Verifier:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Base branch:** dev
- **Run branch:** autometta/142-dependency-readiness-has-evidence
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Dispatch:** serial
- **Pairing rationale:** Opus handles the Git-evidence and compatibility design; Terra independently exercises the frozen inspector contract.

## Objective

Provide a read-only dependency inspector before graph scheduling is enabled.
It explains why each stage can or cannot consume its prerequisites, using
actual Git ancestry. A completed verifier verdict alone is insufficient.

## Inputs (read these in your own context)

- `scripts/tick.sh`: `select_next_dispatchable_stage`,
  `pipeline_tail_gate_met`, `integration_record`, `consume_verifier_artefact`.
- `scripts/dependency-graph-smoke.sh`: `inspect` mode, frozen by the orchestrator.
- `schemas/state.yaml.json`: stage, commit and integration fields.
- `docs/tick-loop.md`, `docs/dispatch-contract.md`, `docs/philosophy.md`.

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/dependency-graph.sh`, a read-only executable with this interface:
   `bash scripts/dependency-graph.sh <repo-root> <state-file> <base-branch>`.
   Read the supplied YAML/JSON state and resolve evidence in the supplied Git
   repository, even when called from another directory. Reuse existing Git,
   yq and state conventions; an internal Python standard-library helper is
   allowed if needed, without a new package dependency.
2. A deterministic JSON report on stdout with this public shape:
   `{"valid":true,"errors":[],"stages":[{"id":"03-join","graph_member":true,"dependency_ready":false,"blocked_by":[{"id":"02-parent","reason":"awaiting-integration"}]}]}`.
   Keep stages in queue order and blockers in declared prerequisite order.
   `dependency_ready` concerns dependencies only, not the stage's own status,
   quota, budget, network or legacy dispatch gate. An unrelated node with no
   dependencies has `dependency_ready: true`. `graph_member` is true for any
   stage declaring `depends_on` and either endpoint of its edges, including
   roots with no such field. A malformed declaration still blocks its owner.
   Exit 0 for a valid graph, even when blocked; exit 2 with `valid:false` and
   actionable `errors` for invalid structure. Missing input/base or unreadable
   Git evidence must fail closed with diagnostics, never claim readiness.
3. `docs/dependency-graph.md`, the contract for the inspector and planned
   three-card rollout. Clearly label dispatch and the public CLI as unavailable
   until 143 and 144 land. Distinguish this scheduling DAG from the existing
   fact-ledger topic in `docs/graph-engineering.md`.

## Constraints

- Inspect `depends_on` only as proposed input data in this card. Do not extend
  queue admission, the production state schema, tick selection or concurrency
  yet. Temporary fixtures may contain the future field. No runtime state writes.
- Each declared prerequisite is satisfied only when its record is `completed`,
  integration is not `awaiting`, and its landed tip is an ancestor of the supplied
  base branch. Use `integration.rebased_tip` when non-empty, otherwise `commit`,
  otherwise `integration.head`. A non-empty invalid preferred tip must not fall
  back to an older tip. Test ancestry with Git, never by comparing branch names.
- A legacy completed record without integration metadata can satisfy a new
  dependency if its commit is provably on that base. A completed no-change stage
  with no recorded commit evidence remains blocked; do not invent an exception.
- Stable blocker reasons: `not-completed`, `awaiting-integration`,
  `missing-commit`, `commit-not-on-base`. Invalid graphs use `invalid-graph`
  for affected readiness and name the bad IDs/edges in `errors`.
- Validate non-empty unique arrays of full stage IDs, existing new prerequisite
  IDs, unique stage IDs, self-dependencies and cycles. Include existing
  `stage_completed` edges when detecting cycles involving new dependencies.
  An absent legacy gate target alone retains its historical pending semantics.
  An invalid graph blocks graph members, while unrelated legacy nodes may still
  be evaluated. Do not let a cycle be silently interpreted as an empty ready set.
- No model calls, auth reads, services, databases, daemons, retries or deployment.
  Neither scripts nor docs change the cross-family role boundary.
- The entire frozen test body is orchestrator-owned, including its fixtures.
  Do not alter it or its digest. A defect in the oracle requires a re-brief.

## Acceptance criteria

1. The opposite-family verifier runs `bash scripts/dependency-graph-smoke.sh inspect`.
   Every case passes: AND join, failed and unfinished parents, awaiting merge,
   stale merged metadata, rebased tip, explicit target base, missing evidence,
   invalid input, mixed legacy/new cycles and independent nodes.
2. Run the same frozen `inspect` mode against the dispatch base using
   `AUTOMETTA_GRAPH_TEST_ROOT=<detached-base-checkout>` and retain the before/after
   outputs. The baseline lacks the inspector; the worker implementation passes.
   Never copy a candidate implementation into the baseline checkout.
3. Independently inspect a real scratch Git branch that has passed verification
   but is absent from the target base. Show both its blocker report and the
   `git merge-base --is-ancestor` result. Repeat after landing the actual commit.
4. Check the diff: no queue/schema/tick changes, no state or refs written by
   inspection, and no new dependency/runtime service. Run `bash -n` on every
   changed shell file and compile any added Python source without executing it.
5. Run `bash scripts/check-contract-test-gate.sh --worktree` before staging.
   Exit 2 means no relevant changed tests/cards, not a pass: also recompute the
   frozen digest with the `print` command and compare it to all three cards.

## Out of scope

Dispatch admission, concurrent graph execution, automatic repair edges, dynamic
LLM-authored graphs, cross-repository dependencies, changes to the fact ledger.

## Contract test

- **Test file:** scripts/dependency-graph-smoke.sh
- **Assertions digest:** `sha256:f540c3557c277689089b7ee01e2baada0731df83fe88fb906b241a4588209098`

The orchestrator froze one shared oracle for cards 142-144 before dispatch.
Its marker names 142; every card records the same digest. Run only this card's
specified modes until 144 runs them all. All assertion and fixture code inside
the block is immutable to workers. A re-brief must update all three digest lines.

## Budget

- **Worker wall-clock:** 30 minutes
- **Verifier wall-clock:** 20 minutes
- **Spend basis:** see the dated 142-144 batch in `stage-cards/PLAN.md`.
  Shared planning allowance 18M tokens, subject to live admission; no cap change
  or drain is authorised by this card. A retry requires a fresh spend estimate.

## Dispatch envelope

Write `state/envelopes/142-dependency-readiness-has-evidence.json` using
`schemas/envelope.json`. List changed deliverables, exact commands,
before/after results, inherited failures and unresolved criteria. The verifier
writes `state/verifiers/142-dependency-readiness-has-evidence.json` under the
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
