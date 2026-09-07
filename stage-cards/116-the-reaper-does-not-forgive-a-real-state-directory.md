# Stage card 116: the reaper does not forgive a real state directory

## Metadata

- **Authored:** 2026-09-06
- **Orchestrator:** Claude Fable 5.1 <claude-fable-5-1@local>
- **Worker:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Verifier:** Codex GPT-5.6 Sol <codex-gpt-5-6-sol@local>
- **Base branch:** dev
- **Run branch:** autometta/116-the-reaper-does-not-forgive-a-real-state-directory
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/reap-worktrees.sh, scripts/state-branch-smoke.sh, stage-cards/116-the-reaper-does-not-forgive-a-real-state-directory.md
- **Pairing rationale:** cross-family. A small reaper defect with an existing failing assertion;
  the verifying seat verifies by building the worktree the assertion describes.
- **Type:** Red-smoke repair. Pipeline-eligible.

## Surfacing concern

`scripts/state-branch-smoke.sh` has failed on a clean `dev` since before
the 2026-09-01 batch, at `:419-422`: a run worktree whose `state/` is a
*real directory* with modified content is reaped, and the reap output never
names it. The reaper forgives `state` when it is the dispatch symlink
(`scripts/reap-worktrees.sh:119-130`), and the forgiveness leaks to a real
directory, which is exactly the case where uncommitted work is inside.

## Objective

A worktree whose `state/` is a real directory holding modified content is
reported as uncommitted work and left standing.

## Inputs (read these in your own context)

- `scripts/reap-worktrees.sh:100-140`
- `scripts/state-branch-smoke.sh:380-425`, section 7

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. The reaper's dirt pathspec excludes `state` only when
   `[[ -L "$work_dir/state" ]]`; a real directory is checked like any other
   path. If the current code already reads that way, find why the porcelain
   query misses it (a `.gitignore` inside the fixture's `state/`, an
   `--ignored` flag, the pathspec quoting) and fix that.
2. The existing frozen assertions at `:419-422` pass unchanged. If the
   smoke's fixture is wrong rather than the reaper, say so in the envelope
   with evidence and fix the fixture; the card is in your claims for the
   digest update either way.

## Constraints

- No change to how the symlink case is forgiven.
- `scripts/reap-worktrees.sh` must not learn any new flag for this.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. `scripts/state-branch-smoke.sh` is no more red on the run branch than on
   clean `dev`, and its new section-7 assertions pass. The absolute
   "passes" this criterion used to demand is not reachable: section 8's
   "a parked branch leaves the base checkout clean" already fails on clean
   `dev` and is nothing to do with this card.
2. Sections 1 to 6 and 8 of that smoke are unchanged in outcome.
3. A hand-built worktree with a real `state/` directory containing a
   modified tracked file is left standing by `autometta reap` (or the
   script's direct invocation) and named in its output.

## Contract test

- **Test file:** scripts/state-branch-smoke.sh
- **Assertions digest:** frame the assertions in a block between the begin
  marker and the end marker, the begin marker naming this card by its
  `card=stage-cards/116-the-reaper-does-not-forgive-a-real-state-directory.md` field, and replace this line's text with the real
  digest printed by `scripts/check-contract-test-gate.sh print scripts/state-branch-smoke.sh`. Do not
  write a `sha256:` comment inside the block, and do not spell the marker
  tokens anywhere in this card's prose; the card is in your path claims for
  exactly this edit.

## Out of scope

- The reaper's handling of unmerged run branches.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes

## Escalation

If the failure turns out to be in `git status --porcelain` semantics on a
worktree whose `state` was a symlink at dispatch and is now a directory
(two deletions and an untracked dir), report the porcelain output and
stop; that shape needs a decision on what "modified" means.

## Verifier handoff

Build the section-7 worktree by hand and run the reaper on it before and
after. The likely wrong pass is a fixture edit that stops testing the real
directory case; read the smoke diff.

## Family-specific notes

None

## Seat history (2026-09-06)

The Codex subscription closed at 10:31Z and this batch was re-seated onto
Claude alone; when Claude session windows then drained faster than the batch
was sized for, the verifying seat moved to the free local route
(`gpt-oss:120b` via `codex exec --oss`). The Codex window reopened the same
afternoon and the card is back on the seats it was authored with. Nothing
about the work changed across either move.

## Re-brief (2026-09-07)

Attempt 1 passed criteria 2 and 3 and the contract-test gate, and was failed
on criterion 1 alone. The verifier was right on the facts and said so
carefully: `scripts/state-branch-smoke.sh` exits 1 from the run worktree, the
failing assertion is section 8's "a parked branch leaves the base checkout
clean" at `:486-487`, every new section-7 assertion at `:420-423` passes,
and **baseline HEAD exhibits the same section-8 failure**.

The card is what was wrong. Criterion 1 demanded the whole smoke pass, where
every other card in this batch asks for "no more red than on clean `dev`".
Confirmed by hand on clean `dev` at 01:31 and again at `51a3a3a`,
`46ae5b3` and `b7bff27`: the same assertion fails at all of them, so it
predates this stage and predates stage 115's landing, which was my first
suspicion and was wrong.

Criterion 1 is reworded. Attempt 1's work stands and is preserved at
`wip/116-the-reaper-does-not-forgive-a-real-state-directory-attempt-1`;
build on it rather than starting again. Its envelope also carries a root
cause worth reading before you touch anything: the fault was **not** the
dirt pathspec, which already reads `[[ -L "$work_dir/state" ]]` correctly
per card 29, but `ensure_run_worktree`'s skip-worktree bit.

### Separate concern, not this card's to fix

Section 8's failure may be sensitive to ambient repository state rather than
to any commit. Probing it across four commits in worktrees that share one
`.git` gave inconsistent results as the number of live worktrees and
branches changed, which is the signature of a smoke that reads the real
repository instead of only its fixtures. If so, it cannot be trusted as a
gate from a shared clone by anyone, and that is worth a card of its own.
Do not chase it from here.

