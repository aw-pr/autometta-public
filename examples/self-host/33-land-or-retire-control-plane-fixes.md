# Stage card 33-land-or-retire-control-plane-fixes: six commits have been stranded on a side branch for two weeks

## Metadata

- **Authored:** 2026-08-16
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** <<worker-identity>>
- **Verifier:** <<verifier-identity>>
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Pairing rationale:** <<fill at dispatch — cross-family. The worker resolves
  conflicts in the loop's most load-bearing files, so the verifier must not be
  the family that wrote them>>

## Objective

`feat/control-plane-fixes` carries six commits from 2026-08-01/02 that have
never reached `dev`. They live in a second worktree at
`/Users/AnthonyWest/repos/autometta-cp-fixes`, clean and forgotten. Meanwhile
`dev` has moved on through worktree-per-run dispatch and solved at least one of
the same problems a second, different way.

Decide commit by commit what lands, land it, and retire the branch.

## Reported by

Found on 2026-08-16 during a repo review, not by anyone missing the features:

```
$ git log --oneline dev..feat/control-plane-fixes
965d569 feat(hygiene): idle dash reaper + log/recent-agent/worker-log retention
f2ef17c feat(ticker): RECENT age cutoff + live worker-log tail
0a2a1b8 feat(dash): scope status.sh/status-ticker.sh/attach.sh to one repo
03854d4 fix(tick): dispatch the verifier on a partial worker envelope
b755176 feat(tick): implement --repair (was a stub, worse than missing)
b2859b8 fix(budget): self-clearing halts + dedupe the halt-log spam
```

Both branches are pushed, so nothing is at risk of being lost. What is at risk
is the assumption that `dev` is the whole story — an agent reading `tick.sh` on
`dev` today cannot tell that a `--repair` implementation and a partial-envelope
fix exist twenty commits away on another branch.

## Why this is not a routine merge

The two lines of work overlap on exactly the files that matter:

```
schemas/budget.json      schemas/state.yaml.json
scripts/budget.sh        scripts/spawn-verifier.sh        scripts/tick.sh
```

Two collisions are substantive rather than textual:

- **`b2859b8 fix(budget): self-clearing halts`** and dev's
  **`9666f16 budget: auto-reset halted-or-at-cap budgets at the start of a new
  run window`** are two independent answers to the same complaint. One of them
  is right, or the right answer is a third thing. Merging both mechanically
  would leave two halt-clearing paths in one file, which is how a halt stops
  meaning anything. This interacts directly with card 31, where a budget cap
  failed to stop a 150x overrun — do not land a second halt-clearing path
  without reading that card first.
- **`03854d4 fix(tick): dispatch the verifier on a partial worker envelope`**
  touches envelope handling, which card 29 is also about. Check whether it
  helps, hinders, or is orthogonal to the sandboxed-envelope fix before landing
  it.

The remaining four (dash scoping, ticker, hygiene reaper) look independent of
the dispatch path and should be cheap.

## Inputs (read these in your own context)

- `git log -p dev..feat/control-plane-fixes` — all six, read them
- `/Users/AnthonyWest/repos/autometta-cp-fixes` — the worktree, currently clean
- docs/plans/2026-08-01-control-plane-review.md — the review these came from
- examples/self-host/31-budget-cap-did-not-stop-dispatch.md — the halt question
- examples/self-host/29-run-worktree-state-writable.md — the envelope question

## Deliverables

1. A per-commit verdict: land as-is, land rewritten, or drop with a reason.
   Six commits, six verdicts. "Drop" is a legitimate answer for anything `dev`
   has since solved differently.
2. The landing itself, as atomic commits on `dev`, preserving the original
   authors via `Co-Authored-By` where a commit is rewritten rather than merged.
3. An explicit decision on the two halt-clearing mechanisms: which survives,
   why, and confirmation that only one path can clear a halt afterwards.
4. The branch and its worktree retired once landed — `git worktree remove`, and
   the branch deleted locally and on `origin` — so the next reviewer does not
   have to rediscover this.
5. Whatever the four independent commits need to keep working under
   worktree-per-run dispatch, which did not exist when they were written.

## Constraints

- Do not land the budget commit and dev's window-reset commit as two live code
  paths. One halt-clearing mechanism, or none.
- Do not force-push or rewrite either branch's published history.
- The repo's acceptance suite must be green after each landed commit, not only
  at the end — that is the atomic-commit rule, and here it is also the only way
  to bisect a regression in `tick.sh` afterwards.
- Do not retire the branch until its content is either landed or explicitly
  dropped in writing.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. The repo's own acceptance suite is green.
2. Every one of the six commits has a recorded verdict, and every "land"
   verdict is visible in `git log dev`.
3. Exactly one halt-clearing mechanism exists in `scripts/budget.sh`.
4. `git log dev..feat/control-plane-fixes` is empty, or its remainder is
   documented as deliberately dropped.
5. The worktree and branch are gone, locally and on `origin`.
6. `scripts/tick.sh --repair` either works or does not exist. A stub is worse
   than a missing feature, which is what `b755176` was written to fix.

## Contract test

- **Test file:** <<fill at dispatch>>
- **Assertions digest:** <<fill at dispatch>>

## Out of scope

- Fixing the budget cap overrun itself — card 31.
- The sandboxed envelope fix — card 29.
- New control-plane features beyond what the six commits contain.

## Budget

- **Worker wall-clock:** 60 minutes
- **Verifier wall-clock:** 45 minutes

## Verifier handoff

Worker reports: the six verdicts with reasons; which halt-clearing mechanism
survived and why; what the partial-envelope commit does to card 29's problem;
anything that needed rewriting for worktree-per-run dispatch; and confirmation
the branch and worktree are retired.

## Family-specific notes

Conflict resolution in `tick.sh` benefits from a family that can hold the whole
file in context. Neither family has a structural advantage here, so pair on
whatever the current queue makes cheap.
