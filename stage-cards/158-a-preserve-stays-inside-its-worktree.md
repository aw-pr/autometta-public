# Stage card 158: a preserve stays inside its worktree

## Metadata

- **Authored:** 2026-10-12
- **Orchestrator:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Base branch:** dev
- **Run branch:** autometta/158-a-preserve-stays-inside-its-worktree
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Dispatch:** serial
- **Pairing rationale:** same-family by operator decision on 2026-10-12:
  the Claude session limit is spent, so Terra writes it and Sol verifies it
  on the Codex subscription; the oracle was authored and proven by Claude.
  The change is to `scripts/tick.sh`, which is load-bearing, so it
  dispatches serially (run-design section 4).
- **Open decisions:** none

## Surfacing concern

On 2026-10-12 card 157's verifier FAIL made the tick walk the system disk.
`card_deliverable_paths` (`scripts/tick.sh:2003`) offers every backticked
token with a slash in a card's Deliverables section as a deliverable, and
`force_add_card_deliverables` (`scripts/tick.sh:2050`) runs `find` over
each one that exists and force-adds every file it lists. Card 157's
Deliverables quoted absolute system paths and a bare slash as prose, so the
preserve searched them, logged system files over 50MB as oversized
deliverables, and was stopped by hand twice; the autometta subscriber was
disabled to keep the next tick from repeating it. `git add` refuses a path
outside the worktree, so nothing was staged, but the walk itself is
unbounded, and the same card also named the run worktree's state symlink,
which points at the shared state directory.

Any card can trip this by quoting a path in prose. Card 157's text has been
reworded (commit 7d0b3b9); this card makes the tick safe whatever a card
says.

A read-only Codex GPT-5.6 Sol cold read raised five items; each is
answered in the card text.

Baseline on dev before queueing: `scripts/preserve-failed-work-smoke.sh`,
`scripts/requeue-reset-smoke.sh` and `scripts/landing-dispatch-smoke.sh`
all pass.

## Objective

Preserving a failed attempt adds only files that physically live inside
the run worktree, whatever paths the card's Deliverables mention.

## Inputs (read these in your own context)

- `scripts/preserve-stays-inside-smoke.sh`: the frozen contract; read it first.
- `scripts/tick.sh`, from `card_deliverable_paths` to the end of
  `preserve_failed_work`.
- `scripts/preserve-failed-work-smoke.sh`: card 110's proof of the same
  code, which must still pass.

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/tick.sh`:
   - `card_deliverable_paths` drops a token that starts with a slash or a
     tilde, or that has a parent-directory segment (two dots as a whole
     segment, at the start, the end or in between).
   - A deliverable is used only when it resolves, on physical paths with
     symlinks followed, to a file or directory inside the run worktree.
     `card_deliverables_exist` and `force_add_card_deliverables` both apply
     this, so a symlink pointing out of the worktree (the state symlink is
     the standing case) is never searched or force-added. The ordinary add
     records a symlink as a link without following it; that is unchanged.
   - `force_add_card_deliverables` logs one line for each deliverable it
     skips for this reason, naming the token and the stage.
   - Nothing else in the preserve changes: the ordinary add, the size
     limit, the wip commit and the index restore behave as before.
2. `docs/lessons.md`: one short entry saying a card's Deliverables prose is
   read by the tick, what happened on 2026-10-12, and that the preserve now
   stays inside the worktree.

## Constraints

- The frozen block in `scripts/preserve-stays-inside-smoke.sh` is read-only.
- Bash only, compatible with the macOS system bash the tick runs under.
- No change to any other function in `scripts/tick.sh`.
- British English in prose, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of
the stage. Each criterion names the seat that judges it and the command
that produces its evidence; the verifier runs every command itself, in the
run worktree, offline.

1. Verifier: `bash scripts/preserve-stays-inside-smoke.sh` prints PASS and
   exits 0, its output carries a skip line naming `state/` and one naming
   `state/state.json`, and `scripts/check-contract-test-gate.sh print
   scripts/preserve-stays-inside-smoke.sh` prints the digest recorded below.
2. Verifier: `bash scripts/preserve-failed-work-smoke.sh`,
   `bash scripts/requeue-reset-smoke.sh` and
   `bash scripts/landing-dispatch-smoke.sh` each pass, as they do on dev.
3. Verifier: `bash -n scripts/tick.sh` exits 0, and `git diff
   scripts/tick.sh` changes only `card_deliverable_paths`,
   `card_deliverables_exist`, `force_add_card_deliverables` and any new
   helper they call.
4. Verifier: `git status --porcelain` in the run worktree lists only
   `scripts/tick.sh` and `docs/lessons.md`, apart from the card itself and
   `state/`.

## Contract test

- **Test file:** scripts/preserve-stays-inside-smoke.sh
- **Assertions digest:** `sha256:58bb5392a2a844afa40d433f78da01c16843904dea20e6dd57dcd68204ee1d60`
- **Oracle proof:** fails today at its first assertion, because a bare
  slash is offered as a deliverable. The smoke replaces `find` with a
  recorder that searches only inside the fixture worktree, so the red run
  cannot walk the disk. A throwaway patch of the three functions, in a
  detached scratch worktree and then removed, passed every assertion, and
  `scripts/preserve-failed-work-smoke.sh` still passed beside it.

## Out of scope

- Parsing deliverables differently in any other script.
- Card 157's own re-brief.

## Budget

- **Worker wall-clock:** 30 minutes (kill at 45)
- **Verifier wall-clock:** 20 minutes
- **Spend basis:** `state/cost-log.jsonl` on 2026-10-12: worker median
  1.1M tokens, verifier median 1.2M; cards 155 and 156 used less. Plan 4M
  for the stage.

## Dispatch envelope

Write `state/envelopes/158-a-preserve-stays-inside-its-worktree.json` using
`schemas/envelope.json`. List changed deliverables, the exact smoke
commands and their results, and any criterion you could not satisfy with
why. If the card itself is wrong, stop with `status: fail` and say so in
`notes` rather than working round it. Do not self-verify or land your own
branch. The verifier writes
`state/verifiers/158-a-preserve-stays-inside-its-worktree.json` under the
existing verifier contract, giving a criterion-by-criterion verdict.

## Family-specific notes

Codex: workspace-write is all this card needs; the smoke is offline and
builds its fixture under `mktemp -d`. Run every command in the foreground.
