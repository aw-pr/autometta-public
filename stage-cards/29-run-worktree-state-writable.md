# Stage card 29-run-worktree-state-writable: let a sandboxed worker write its handoff envelope

## Metadata

- **Authored:** 2026-08-14
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Claude Opus 5 <claude-opus-5@local>
- **Verifier:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Pairing rationale:** cross-family, and deliberately not a Codex worker:
  the bug is that a sandboxed Codex seat cannot write its envelope, so
  dispatching this card to that family would run it straight into the defect
  it is meant to fix. The Codex verifier supplies the real sandboxed
  dispatch the behavioural regression test needs.

## Objective

Worktree-per-run dispatch (`b1a3aa5`) made every stage run in an ephemeral
worktree whose `state/` is a symlink pointing outside that worktree. A codex
role under `--sandbox workspace-write` cannot write through that symlink, so it
cannot write its handoff envelope — the sole signal `tick.sh` uses to decide the
worker is done. Such a stage completes all its real work and then stalls.

Make the envelope writable from inside the sandbox, without giving the worker
write access to anything else it should not have.

## Reported by

Observed on 2026-08-14 in `emergence-lab` (worktree `../emergence-lab-gpu`,
stage `34-logistic-mandelbrot-fp32-spike`, worker GPT-5.6 Sol under
`workspace-write`). The worker produced both deliverables, ran `npm run verify`
green, confirmed reproducible output — then ended with:

> The handoff envelope is the sole incomplete item: both writes were blocked
> because the dispatch-provided `state` symlink resolves outside this worker's
> writable root.

`tick.sh` marked the stage `stalled`, its deliverables were never committed,
and the next stage in the queue then failed because its declared dependency on
those deliverables could not be satisfied. One blocked `write()` cost two
stages and roughly 119k worker tokens.

## The mechanism, already isolated

`scripts/tick.sh:421-422`, in `ensure_run_worktree`:

```sh
rm -rf "${work_dir:?}/state"
ln -s "../$(basename "$repo_root")/state" "$work_dir/state"
```

`scripts/spawn-worker.sh:185-187` then dispatches
`codex exec -C "$work_dir" --sandbox "$codex_sandbox"`. Under
`workspace-write` the sandbox permits writes beneath `$work_dir`, but the
symlink resolves to `$repo_root/state`, which is outside it.

**The bug is masked by `Requires GUI`, and this is the important part.**
`resolve_codex_sandbox_for_card` (`scripts/models.sh:85-95`) returns
`danger-full-access` for any card declaring `Requires GUI: true`, so those
roles run unsandboxed and their envelope writes succeed. Confirmed on the same
day, in the same repo, through the same dispatch path:

| Stage | `Requires GUI` | Resolved sandbox | Envelope |
|---|---|---|---|
| 34-logistic-mandelbrot-fp32-spike | absent | `workspace-write` | blocked, stalled |
| 35-logistic-mandelbrot-gpu-sampler | true | `danger-full-access` | written |

So the failure selects for cards that are *correctly* conservative about
granting machine access, and is invisible to cards that are not. Stage
`33-markus-lyapunov-interaction` passed on 2026-08-14 only because it declares
GUI. Do not treat "recent stages passed" as evidence the path is sound.

## Inputs (read these in your own context)

- scripts/tick.sh — `ensure_run_worktree` and `teardown_run_worktree`
  (roughly 405-445), plus every site that reads
  `state/handoffs/<stage-id>.json`
- scripts/spawn-worker.sh — lines 125-190, the codex dispatch and the
  `codex_sandbox` resolution
- scripts/spawn-verifier.sh — lines 230-300, the equivalent verifier dispatch
- scripts/models.sh — `resolve_codex_sandbox_for_card` and
  `resolve_codex_sandbox`
- scripts/requeue-stage.sh — it removes the run worktree, so it interacts with
  whatever you choose to store there
- docs/dispatch-contract.md — the pass-2 layer section, on who writes state
- schemas/handoff-envelope.json — the envelope shape

## Deliverables

1. A fix that lets a `workspace-write` codex role write its handoff envelope.
   Choose the approach, state the reasoning, and address at least these two:
   - **Grant a writable root.** Pass `$repo_root/state` (or just
     `$repo_root/state/handoffs`) to codex as an additional writable root
     alongside the workspace. Narrower is better: the worker needs to write
     one file, not the whole state directory, and `state/state.yaml` is
     explicitly `tick.sh`-only per `schemas/state.yaml.json`.
   - **Write locally, collect centrally.** Make `work_dir/state` a real
     directory and have `tick.sh` read the envelope from the run worktree
     rather than from `repo_root/state/handoffs/`. Keeps the sandbox boundary
     intact with no privilege grant, at the cost of touching every reader.

   Whichever you choose, a worker must still not be able to write
   `state/state.yaml` or `state/budget.json`. A fix that hands the worker the
   whole state directory has traded a stall for a worker that can edit its own
   budget and verdict, which is strictly worse.
2. A regression test that dispatches, or faithfully simulates, a
   `workspace-write` codex role and asserts the envelope arrives where
   `tick.sh` reads it. It must fail against current `main`. A test that only
   exercises the `danger-full-access` path reproduces the mask rather than the
   bug, and is worse than no test.
3. `docs/lessons.md` — add this as a numbered gotcha, including the masking
   behaviour, since that is what made it hard to see.
4. Check `teardown_run_worktree` and `requeue-stage.sh` still behave correctly
   under the chosen fix. Both delete the run worktree; if the envelope now
   lives there, deleting it before it is read loses the stage.

## Constraints

- Do not widen the codex sandbox generally, and do not resolve this by making
  more cards declare `Requires GUI`. That grants full machine access to work
  that does not need it and would spread the masking further.
- Do not change the envelope schema or the contract's step ordering.
- Preserve `state/state.yaml` as `tick.sh`-write-only.
- The fix must work for both `spawn-worker.sh` and `spawn-verifier.sh`; a
  sandboxed codex *verifier* has the same problem writing
  `state/verifiers/<stage-id>.json`. Fixing only the worker leaves the second
  half of every cross-family stage broken.
- Claude roles are unsandboxed and unaffected; do not regress them.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. The repo's own acceptance suite is green.
2. A codex role dispatched with `--sandbox workspace-write` writes its handoff
   envelope successfully, and `tick.sh` reaps the stage. Demonstrate with a
   real dispatch, not by reading the diff.
3. The same holds for a sandboxed codex verifier writing
   `state/verifiers/<stage-id>.json`.
4. The regression test fails against the pre-fix commit. Check it out, run it,
   state the failure.
5. A worker still cannot write `state/state.yaml` or `state/budget.json`.
   Attempt both and show they are refused.
6. `Requires GUI: true` cards still work, still resolve to
   `danger-full-access`, and are not otherwise altered.
7. `requeue-stage.sh` and `teardown_run_worktree` do not destroy an envelope
   that has not yet been read.
8. `docs/lessons.md` records the gotcha and the masking behaviour.

## Contract test

- **Test file:** <<fill at dispatch>>
- **Assertions digest:** <<fill at dispatch>>

## Out of scope

- Redesigning worktree-per-run dispatch. It is sound; one path is wrong.
- The sticky `dirty-working-tree` halts on `aegis-guardrails` and
  `agentic-rag-kimble`, which are a separate issue.
- Anything in the subscriber repos.

## Budget

- **Worker wall-clock:** 60 minutes
- **Verifier wall-clock:** 45 minutes

## Verifier handoff

Worker reports: which approach was taken and why the other was rejected; the
exact writable surface a sandboxed worker now has, and evidence that
`state.yaml` and `budget.json` are not in it; that the verifier path was fixed
alongside the worker path; the regression test's failure output against the
pre-fix commit; and what was checked in `requeue-stage.sh` and
`teardown_run_worktree`.

## Family-specific notes

The verifier needs to run a real codex dispatch under `workspace-write`, so it
needs working codex auth. If the acceptance run needs a browser for any reason
it must declare `Requires GUI` — but note that doing so for the *test dispatch
itself* would reproduce the mask and invalidate criterion 2.
