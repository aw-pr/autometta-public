# Stage dependency graph

> **Status (card 142).** Only the read-only inspector,
> `scripts/dependency-graph.sh`, exists. **Graph dispatch is unavailable
> until card 143 lands**: `add-stage.sh` does not parse a `Depends on` line,
> the state schema does not declare `depends_on`, and `tick.sh` neither reads
> the field nor consults the inspector. **The `autometta graph` operator
> command is unavailable until card 144 lands.** Until then, `depends_on`
> appears only in hand-built fixtures and in the frozen oracle,
> `scripts/dependency-graph-smoke.sh`.

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

Each card lands before its successor is admitted. Until 143 lands, writing
`depends_on` into a live `state.yaml` has no effect on dispatch, and the state
schema rejects the field.
