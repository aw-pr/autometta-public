# Stage card 111: dev moving does not park a disjoint landing

## Metadata

- **Authored:** 2026-09-06
- **Orchestrator:** Claude Fable 5.1 <claude-fable-5-1@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Opus 5 <claude-opus-5@local>
- **Base branch:** dev
- **Run branch:** autometta/111-dev-moving-does-not-park-a-disjoint-landing
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/tick.sh, scripts/landing-rebase-smoke.sh, docs/tick-loop.md, stage-cards/111-dev-moving-does-not-park-a-disjoint-landing.md
- **Pairing rationale:** cross-family, with the Codex seat working because it authored the
  measured tick-cost work in card 100 and knows the landing path; the Opus
  seat verifies because the whole card turns on when a rebase is safe, which
  is judged by constructing conflicting and non-conflicting histories and
  reading the result.
- **Type:** Integration. The largest single wall-clock lever in the batch after queue starvation. Touches `scripts/tick.sh`, so serial.

## Surfacing concern

`finalize_run_worktree` (`scripts/tick.sh:1652-1692`) only fast-forwards.
If the base has moved by any commit since dispatch, the landing path
(`:2168-2190`) parks the passed branch as `integration.state: awaiting`,
pushes it, and appends a line to `HANDOFF.md` in the base checkout. A human
then merges it by hand, and while they do, the next stage is dispatched
from the moved base without the parked work. Twenty-one landings have been
parked this way (`HANDOFF.md:691-731`); watched latency was 1 to 40
minutes, unattended 25 hours (stage 58). Both parks on 2026-09-03 were
caused by docs-only commits to `dev`, and the HANDOFF append itself
dirtied the tree that `merge-awaiting` then refused to touch.

The mechanical rebase already exists for a pipeline tail:
`pipeline_prepare_tail_rebase` (`:1117-1185`) rebases only when the two
diffs are file-disjoint and aborts to an escalation on any conflict. It is
reachable only from the pair path.

## Objective

A passed run branch whose diff is file-disjoint from the base's movement
lands by mechanical rebase and fast-forward, in the same fire; only a
genuine file overlap parks it. The tick stops writing into the base
checkout when it parks.

## Inputs (read these in your own context)

- `scripts/tick.sh:1117-1185`, the existing tail rebase and its
  disjointness test
- `scripts/tick.sh:1652-1692` and `:2140-2195`, finalize and the landing path
- `scripts/phat-controller.sh`, `pc_merge_awaiting`, which must keep working
  for the parks that remain
- `docs/tick-loop.md`, the landing and integration sections
- `HANDOFF.md:691-731`, the integration ledger, for the shapes of past parks

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. Factor the disjointness-and-rebase logic out of
   `pipeline_prepare_tail_rebase` into a function the landing path can call
   with a run branch and a base branch. The pair path keeps using it.
2. On landing, when the base is not an ancestor of the run tip: compute the
   files touched by `base@dispatch..base` and by `base@dispatch..run_tip`.
   If disjoint, rebase the run branch onto base in the run worktree, re-run
   nothing (the verifier's verdict stands; record `integration.rebased: true`
   with both tips), fast-forward, tear down. If any file overlaps, or the
   rebase reports a conflict, abort the rebase and park exactly as today.
3. The park path no longer appends to `HANDOFF.md` in the base checkout. The
   ledger record in `state.yaml` and the log line are the record; the status
   verb's awaiting-integration section already prints them.
4. `scripts/landing-rebase-smoke.sh`: (a) docs-only movement on base with a
   code-only run branch lands by rebase and `dev` is fast-forwarded; (b)
   movement touching a file the run branch also touched parks with
   `awaiting`; (c) the base checkout is clean after a park; (d) a rebase
   conflict on a file-disjoint pair (rename or directory collision) aborts
   cleanly and parks. Frozen block around those assertions.
5. `docs/tick-loop.md`: the landing section describes the three outcomes,
   ff, rebase-and-ff, park, and states the rule that the verdict is not
   re-run after a disjoint rebase, and why.

## Constraints

- Never resolve a conflict headlessly; `git rebase --abort` is the only
  answer to one.
- The rebase happens in the run worktree, never in the base checkout.
- The recorded `run_tip` before rebase must survive in the ledger so the
  verified commit is still findable.
- `pipeline-pair-smoke.sh` keeps passing; the pair path is a caller, not a
  casualty.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. Fixture (a) lands: `dev` tip is the rebased run commit, the run
   worktree is gone, `integration.state` is `merged` with `rebased: true`.
2. Fixture (b) parks with `awaiting`; fixture (d) parks and no rebase is in
   progress in the worktree afterwards (`git status` shows no rebase).
3. After a park, `git -C <base> status --porcelain` is empty.
4. `scripts/landing-rebase-smoke.sh`, `scripts/pipeline-pair-smoke.sh` and
   `scripts/phat-controller-smoke.sh` pass; case (a) fails against the
   pre-change `tick.sh`.
5. `pc_merge_awaiting` still merges a parked branch from fixture (b).

## Contract test

- **Test file:** scripts/landing-rebase-smoke.sh
- **Assertions digest:** `sha256:069a507688be9bb41bbf6c342348d51e3fc32d3359f1f646f01942bdd253bf9d`

## Out of scope

- Re-verifying after a rebase. Disjoint files are the whole premise; if
  that premise is wrong for some repo, that repo sets a manifest flag, which
  is a later card.
- Batching the watcher's commits.

## Budget

- **Worker wall-clock:** 90 minutes
- **Verifier wall-clock:** 45 minutes

## Escalation

If the landing path cannot know the base tip at dispatch time (check
whether `state.yaml` records it; card 72 in this repo made the run page
know where the run starts), record it at dispatch as part of this card and
say so, rather than approximating with the merge base. If even that needs
a schema change beyond one field, stop and report.

## Verifier handoff

Construct all four histories yourself in a throwaway repo and run the
real tick against them. The dangerous wrong pass is fixture (a) passing
because the smoke made the base movement *empty*; check the base really
moved. Then the second: a rebase that leaves the run worktree mid-rebase
after a conflict. Inspect `.git/rebase-merge` absence after fixture (d).
Confirm the pair smoke still passes, since you are the seat that would
notice the shared function changing under it.

## Family-specific notes

None

## Seat history (2026-09-06)

The Codex subscription closed at 10:31Z and this batch was re-seated onto
Claude alone; when Claude session windows then drained faster than the batch
was sized for, the verifying seat moved to the free local route
(`gpt-oss:120b` via `codex exec --oss`). The Codex window reopened the same
afternoon and the card is back on the seats it was authored with. Nothing
about the work changed across either move.
