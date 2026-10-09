# Stage dependency graph

> **Status (card 144).** Queue admission, tick dispatch and the read-only
> `autometta graph` operator command are all live in this checkout. An
> installed Homebrew CLI only gains `autometta graph` after a separate
> install or refresh step; see [Getting the command](#getting-the-command).

## What this is, and what it is not

A stage may name the earlier stages whose landed results it builds on. Those
declarations form a scheduling DAG over coding stages: an edge
`03-join -> 02-parent` means "03-join may start only once 02-parent's commit
is on the branch 03-join will be cut from". It decides *when a card may run*.

It is unrelated to the fact ledger discussed in
[graph-engineering.md](graph-engineering.md) (`memory/facts.jsonl`). That
ledger records what the project has learned as subject-predicate-object
facts with provenance. It answers "what is true"; this graph answers "what
must land first". Neither reads nor writes the other, and nothing in the
dependency work changes the ledger.

It is not a workflow engine and not a new agent role. The existing tick still
runs one transition per fire, the dispatch contract and the cross-family
verifier boundary are unchanged, and graph members stay serial.

## Operator guide

### Getting the command

```sh
autometta graph [--repo <repo-path>] [--json]
```

`--repo` defaults to the current directory. The command lives in this
checkout; editing or pulling the checkout does not update an installed
Homebrew CLI, which runs its own copy of `scripts/`. Until the install is
refreshed, run the checkout launcher directly:

```sh
AUTOMETTA_ROOT=<autometta-checkout> <autometta-checkout>/bin/autometta graph --repo <repo-path>
```

Refreshing the installed CLI is a separate, deliberate step
(`scripts/install-homebrew-local.sh`, then `autometta --version` against the
checkout's `git rev-parse --short HEAD`, as in [setup](setup.md)). Do it when
you choose to move the fleet onto this build, not as a side effect of reading
this guide.

### A fork/join example

Four cards: a schema change, two pieces of work built on it, and a join that
needs both.

```text
20-schema ──┬──> 21-backend ──┬──> 23-wire-up
            └──> 22-frontend ─┘
```

The edges are declared on the consumer, in each card's metadata:

```md
# 21-backend.md and 22-frontend.md
- **Depends on:** 20-schema
- **Dispatch:** serial

# 23-wire-up.md
- **Depends on:** 21-backend, 22-frontend
- **Dispatch:** serial
```

`20-schema` declares nothing; it is a graph root because others name it.

### Queue in topological order

A prerequisite must already be queued, so add parents before children.
Admission refuses a card whose prerequisites are missing and leaves the queue
untouched.

```sh
autometta add-stage <repo-path> stage-cards/20-schema.md
autometta add-stage <repo-path> stage-cards/21-backend.md
autometta add-stage <repo-path> stage-cards/22-frontend.md
autometta add-stage <repo-path> stage-cards/23-wire-up.md
autometta graph --repo <repo-path>
```

### How the tick executes it

The graph is executed by the existing tick, nothing else. Each fire the tick
resolves the repo's base branch, asks the inspector, and dispatches the first
pending card in queue order whose dependencies are landed and whose own gates
and admission checks pass. Graph members are serial: one active stage, no
pipeline pairing. For the example above:

1. `20-schema` dispatches, is verified and lands on base.
2. `21-backend` and `22-frontend` are both dependency ready. `21-backend` runs
   first because it is first in queue order; `22-frontend` waits for the slot,
   not for a dependency.
3. `23-wire-up` stays pending until both commits are ancestors of base. A PASS
   that is still `awaiting-integration` does not release it.

A restarted or repeated tick re-reads persisted state: a stage already
`in_progress` with a recorded worker PID is not dispatched again.

This is a DAG of coding stages inside one repository. It is not a new agent
family, not a role, and not a generic workflow engine: every node is an
ordinary stage card with one worker and one cross-family verifier, under the
same dispatch contract as any other card.

### Reading the output

```text
base:  dev (tick base-branch policy, registry manifest ...)
graph: valid

Readiness below is dependency readiness only, not permission to dispatch.
...
21-backend   completed   dependencies landed
               depends on: 20-schema
22-frontend  completed   dependencies landed
               depends on: 20-schema
23-wire-up   pending     waiting on dependencies
               depends on: 21-backend, 22-frontend
               waiting: 22-frontend awaiting-integration
```

- `graph: valid` with `waiting:` lines is ordinary waiting. Nothing is wrong;
  the named parent has not landed yet. The command exits 0.
- `graph: INVALID` lists each structural error, marks affected stages
  `INVALID GRAPH` with `invalid:` lines, and exits 2. No graph member
  dispatches until the queue is corrected; independent stages still can.
- `not in graph` stages ignore dependencies entirely. A `legacy gate:` line
  is shown for information and keeps its status-only meaning.
- `--json` prints the inspector report described [below](#report-shape),
  byte for byte, with the same exit codes. Exit 1 means no inspection was
  possible (missing repo, state file or base branch); treat it as "nothing is
  ready".

Readiness is necessary, never sufficient. Quota, budget, network preflight,
explicit pauses and drains, and the stage's own status are checked by the
tick at dispatch time and are not reported here.

### Checking target-base evidence yourself

The base is the one the tick would use: the registry manifest's
`base_branch`, else `.autometta.local.yaml`, else the checked-out branch. To
confirm a parent by hand, test its landed tip with Git, never by branch name:

```sh
tip="$(yq -r '.stages[] | select(.id == "22-frontend")
  | (.integration.rebased_tip // .commit // .integration.head // "")' <repo-path>/state/state.yaml)"
git -C <repo-path> merge-base --is-ancestor "$tip" dev && echo landed || echo "not on dev"
```

### Inspecting a stopped run

When the queue stops moving, read before changing anything:

```sh
autometta status
autometta graph --repo <repo-path>
yq '.stages[] | [.id, .status, .integration.state // ""] | @tsv' <repo-path>/state/state.yaml
jq '{halted, halt_reason}' <repo-path>/state/budget.json
grep 'dependency unmet' "$(ls -t ~/.autometta/log/tick-*.log | head -1)"
```

Two very different causes look alike from a distance:

| Symptom | Cause | What the graph shows | What clears it |
| --- | --- | --- | --- |
| Child pending, independent work still running | A parent failed (`failed`, `verifier_failed`, `stalled`) | `waiting: <parent> not-completed` | Re-queue the parent through `autometta-requeue` after fixing its card. Never cleared automatically. |
| Child pending after a parent PASS | The parent is `awaiting-integration` or `commit-not-on-base` | `waiting: <parent> awaiting-integration` | Integrate the parent (`autometta phat-controller merge-awaiting`). |
| Nothing dispatches at all | A budget halt, quota hold, network failure, pause or drain | Readiness may read `dependencies landed` | The stated cause; a halt needs `autometta tick --reset-halt` by a person once it is safe. Never cleared automatically. |

A failed parent blocks only its descendants and does not halt the repo. A
budget or quota stop holds everything, including stages whose dependencies
are ready; readiness never overrides it. Neither condition resets attempts,
counters or caps on its own.

### Migrating from legacy gates

Existing `Gate: stage-completed` cards are not migrated and keep their
status-only meaning: they pass when the parent record reads `completed`, even
if its commit never reached base. To require landed code, write new cards
with `Depends on` instead. A card cannot carry both.

## Queueing a dependency card

Use one metadata line with full stage IDs in the order they are declared:

```md
- **Depends on:** 21-backend, 22-frontend
- **Dispatch:** serial
```

The referenced cards must already be in the queue. Queue admission constructs
the prospective queue and asks the inspector to validate it before it writes
anything, so missing IDs, self references, duplicates and cycles are rejected
without changing the queue. A dependency card cannot also use `Gate` or `Path
claims`; it is serial even where its files would otherwise be disjoint.

At every tick the selector resolves the intended base using the normal
base-branch policy, then asks the inspector again. It selects the first pending
card whose dependencies and any legacy gate are satisfied, stepping over a
blocked child to independent work later in queue order. An unlanded, failed or
awaiting parent changes neither the child status nor its counters. After a
parent lands, the next tick rechecks actual Git ancestry, so no requeue is
needed. Pipeline pairing is refused for either endpoint of a dependency graph,
including a root named only by another card.

`stage_completed` and `queue_empty` retain their legacy, status-only meaning.
In particular, a legacy completion gate can pass when the recorded parent is
`completed` but its commit is not on the child base. That weaker guarantee is
intentional for compatibility. Use `Depends on` when landed-code evidence is
required.

## The inspector

```sh
bash scripts/dependency-graph.sh <repo-root> <state-file> <base-branch>
```

It reads the state file (YAML or JSON, through `yq`), resolves every piece of
evidence in the named repository with Git, and prints one JSON report on
stdout. Relative arguments resolve against the caller's directory, so it can
be run from anywhere. It is read-only: it writes no state, budget or counter,
moves no ref, creates no worktree, takes no optional Git lock
(`GIT_OPTIONAL_LOCKS=0`), and makes no model, credential or network call.

### Report shape

```json
{"valid":true,"errors":[],"stages":[{"id":"03-join","graph_member":true,"dependency_ready":false,"blocked_by":[{"id":"02-parent","reason":"awaiting-integration"}]}]}
```

- `stages` lists every queued stage in queue order, whatever its status.
- `blocked_by` lists unmet prerequisites in the order the stage declared them.
- `dependency_ready` is about dependencies only. It says nothing about the
  stage's own status, quota, budget, network preflight or legacy `gate`. A
  completed stage can read `true`; a pending stage with no dependencies always
  reads `true`. It is never permission to dispatch on its own.
- `graph_member` is true for a stage that declares `depends_on` (even a
  malformed declaration) and for every stage named as a prerequisite,
  including roots that declare nothing themselves. Legacy gate edges do not
  make a stage a member.
- `errors` is empty when `valid` is true. Otherwise it carries one actionable
  line per structural fault, naming the stage IDs and edges involved.
- The output is compact, key order is fixed, and the same state and
  repository always produce the same bytes.

### Exit codes

| Exit | Meaning | stdout |
| --- | --- | --- |
| 0 | The graph is valid. Stages may still be blocked. | report, `valid:true` |
| 2 | The graph is structurally invalid. | report, `valid:false` |
| 1 | Inspection was impossible: wrong arguments, a missing or unparseable state file, a missing tool, a repository that is not Git, a base branch that does not exist, or Git failing while testing ancestry. | nothing |

Exit 1 prints its diagnostic on stderr and no report, so a caller cannot read
readiness out of a failed inspection. A caller must treat any exit other than
0 or 2 as "nothing is ready".

## When a prerequisite is satisfied

A declared prerequisite is satisfied only when all three hold:

1. Its record has `status: completed`.
2. Its `integration.state` is not `awaiting`.
3. Its landed tip is an ancestor of the supplied base branch, tested with
   `git merge-base --is-ancestor <tip> <base>`.

A verifier PASS on its own is not enough. Between PASS and landing the commit
can sit on a run branch only (`integration.state: awaiting`), and a record can
say `merged` about a base that has since been reset or about a different base
altogether. Only Git ancestry on the requested base is evidence.

The landed tip is the first non-empty value of:

1. `integration.rebased_tip`: the commit that actually landed after a
   mechanical rebase.
2. `commit`: the stage's atomic commit.
3. `integration.head`: the run branch tip when the record was written.

The first non-empty value is the only one tested. If it is malformed, or names
no commit in this repository, the prerequisite is blocked as `missing-commit`
with a stderr diagnostic; the inspector does not fall back to an older tip
that might happen to be on base. A tip must be a hexadecimal object ID that
resolves to a commit with that prefix, so a branch named like a SHA can never
stand in for one, and branch names are never compared.

The base is resolved as `refs/heads/<base>`, then `refs/remotes/<base>`, and
evidence is checked against that ref, never against the checked-out `HEAD`.

### Legacy and no-change records

A record completed before integration metadata existed has a `commit` and no
`integration`. It satisfies a dependency if that commit is on base: nothing
is migrated or rewritten. A stage that completed with no change, and so has no
`commit`, `rebased_tip` or `head`, stays blocked as `missing-commit`. There is
no exception for it; a card that needs such a stage should not depend on it.

### Blocker reasons

Reasons are stable strings; consumers may match on them.

| Reason | Meaning | What clears it |
| --- | --- | --- |
| `not-completed` | The prerequisite is pending, in progress, failed, verifier-failed, stalled or superseded. | It completes. Failed work is never cleared automatically. |
| `awaiting-integration` | It passed, but its run branch has not been integrated into base. | A person integrates it and the record leaves `awaiting`. |
| `missing-commit` | It completed with no usable commit evidence. | Correcting the record, or re-planning the dependent card. |
| `commit-not-on-base` | Its landed tip exists but is not an ancestor of the base branch. | The commit reaching that base. |
| `invalid-graph` | The graph is invalid, so this stage's readiness cannot be judged. | Fixing every entry in `errors`. |

Each prerequisite contributes at most one blocker, the first that applies in
the order above.

## Structural validity

The graph is invalid, and the inspector exits 2, when any of these holds:

- a stage record has no string `id`, or two records share an `id`;
- `depends_on` is present but is not a list, is an empty list, or contains an
  entry that is not a full stage ID (`^[0-9]{2,}[a-z]*-[a-z0-9-]+$`);
- `depends_on` names the same prerequisite twice, names its own stage, or
  names a stage that is not in the queue;
- a cycle runs through at least one `depends_on` edge. Existing
  `gate: {type: stage_completed}` edges count when looking for such a cycle,
  so a mixed legacy/new cycle is caught.

When the graph is invalid every graph member, and every stage named by an
error, is reported with `dependency_ready: false` and an `invalid-graph`
blocker. A cycle can therefore never look like an empty ready set. Stages
unrelated to the graph are still evaluated and keep `dependency_ready: true`,
so a malformed declaration does not stop independent work.

Legacy gates keep their historical status-only meaning. A `stage_completed`
gate naming a stage absent from the queue is not an error: that stage simply
stays pending, as it always has. A cycle made only of legacy gates is not an
error either; the inspector does not judge legacy gates at all.

## Rollout

Three serial cards share one frozen oracle,
`scripts/dependency-graph-smoke.sh`, whose `inspect`, `dispatch` and
`lifecycle` modes belong to cards 142, 143 and 144.

| Card | Delivers | Oracle mode |
| --- | --- | --- |
| 142 | This inspector and this contract. No queue, schema, tick or concurrency change. | `inspect` |
| 143 | `- **Depends on:**` card metadata parsed by `add-stage.sh` and validated with this inspector, `depends_on` in the state schema, tick selection that steps over unready stages, and refusal of pipeline pairs involving graph members. | `dispatch` |
| 144 | The read-only `autometta graph [--repo <path>] [--json]` command over this report, operator documentation, and lifecycle proof across restarted ticks and the existing admission gates. | `lifecycle` |

Each card lands before its successor is admitted. The operator CLI exposes
this same report through `scripts/graph.sh` without a second graph
implementation: it resolves the base branch with the tick's own
`resolve_base_branch` and formats the inspector's output.
