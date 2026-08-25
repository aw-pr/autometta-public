# Stage card 53: the tick preserves failed work itself

## Metadata

- **Authored:** 2026-08-24
- **Orchestrator:** Claude Fable 5 <claude-fable-5@local>
- **Worker:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Base branch:** dev
- **Run branch:** autometta/53-the-tick-preserves-failed-work-itself
- **Worker effort:** medium
- **Verifier effort:** medium
- **Verifier panel:** false
- **Pairing rationale:** git plumbing inside the tick's reap path, where
  the cost of a bug is losing a FAILed worker's diff; verified
  cross-family by exercising real FAIL fixtures, not by reading the
  branch logic.

## Objective

On 2026-08-24 three verifier FAILs in one day each needed the same manual
sequence before requeue: commit the run worktree's uncommitted diff to the
run branch, pin it on a `wip/<stage>-attempt-N` branch so
`requeue-stage.sh`'s branch removal cannot orphan it, and reference the
sha in the card's re-brief. The orchestrator did it by hand three times
(45: d5f98ab, a6c81f1; 44: 94c5df1). Forgetting it once means a requeue
discards a near-passing implementation and the next attempt re-spends
millions of tokens re-deriving it.

Make preservation the tick's job. A verifier FAIL should leave behind, in
every case and with no human in the loop: the diff committed on the run
branch, a pinned `wip/` ref, and the sha recorded in the stage's state
record where a re-brief can cite it.

## Inputs (read these in your own context)

- `scripts/tick.sh` — the verifier-FAIL handling and the reap path that
  currently leaves the worktree standing with an uncommitted diff.
- `scripts/requeue-stage.sh` — the branch and worktree removal the pin
  must survive; it must also learn to leave `wip/` refs alone.
- The three manual preservation commits named above, as the shape of the
  commit message and author attribution to reproduce (author is the
  worker identity from the card; the `state` symlink substitution is
  excluded from the commit, as those commits did with `:!state`).
- `schemas/state.yaml.json` — where the preserved sha is recorded.
- `docs/dispatch-contract.md` — the FAIL flow to update.

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/tick.sh` — on marking a stage `verifier_failed`, commit the
   run worktree's diff (excluding the `state` substitution) to the run
   branch, authored as the card's worker identity, message naming the
   stage, attempt and one-line FAIL reason; pin `wip/<stage>-attempt-<n>`
   at that commit. A clean worktree preserves nothing and says so.
2. The stage's state record gains `wip_commit` and `wip_branch` for the
   latest preserved attempt.
3. `scripts/requeue-stage.sh` — never deletes `wip/` refs; its output
   names the preserved sha when one exists so a re-brief can cite it
   without archaeology.
4. `scripts/reap-worktrees.sh` — a worktree whose diff is preserved on a
   `wip/` ref is collectable after requeue; the current refusal on
   uncommitted work no longer applies once preservation has run.
5. `docs/dispatch-contract.md` — the FAIL flow documents preservation as
   automatic, and the re-brief convention references `wip_commit`.
6. An offline smoke: fixture worktree with a diff, FAIL path run,
   assertions (able to fail, per the bash 3.2 lesson) that the commit
   exists, the pin exists, state carries the sha, and requeue leaves the
   pin standing.

## Constraints

- Preservation must never block the tick: any git failure in the
  preserve step logs loudly, leaves the worktree standing exactly as
  today, and moves on. Fail open to today's behaviour, never to loss.
- No change to what counts as FAIL, to attempt caps, or to card 35's
  refusal path (a refusal is not a FAIL and preserves nothing).
- `wip/` refs are per-attempt and append-only during a stage's life;
  cleaning them up after a stage completes is the operator's, or a later
  card's, not this one's.
- British English, no em dashes.

## Acceptance criteria

1. A fixture FAIL with a dirty worktree leaves the diff committed on the
   run branch, the `wip/` pin, and `wip_commit`/`wip_branch` in state;
   authorship matches the card's worker identity.
2. A fixture FAIL with a clean worktree preserves nothing and logs that.
3. `requeue-stage.sh` after preservation removes worktree and run branch,
   leaves the `wip/` pin, and prints the preserved sha.
4. A preserve-step git failure (fixture: read-only ref dir) leaves the
   worktree standing and the tick completing its pass.
5. The smoke passes with assertions demonstrated able to fail; every
   existing offline smoke still passes; `bash -n` on touched files.

## Contract test

- **Test file:** None
- **Assertions digest:** None

## Out of scope

- Any LLM-driven triage or re-briefing; card 54 owns the judgement layer.
- Changing FAIL semantics or attempt accounting.
- wip-ref garbage collection.

## Budget

- **Worker wall-clock:** 60 minutes
- **Verifier wall-clock:** 30 minutes

## Verifier handoff

Return the fixture outcomes for all four FAIL/requeue cases with the git
evidence (branch, ref, state record), and the failure-injection result.

## Family-specific notes

None
