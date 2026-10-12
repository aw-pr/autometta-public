---
name: autometta-oracle
description: >-
  Author the frozen contract test (the oracle) for an Autometta stage card
  before the card is queued: one assertion per criterion and per
  constraint, proven red on the base branch and green against a throwaway
  reference, digested with check-contract-test-gate.sh and recorded on the
  card. Use whenever a card's Contract test section is about to be filled,
  or the operator says "write the contract test", "freeze the oracle",
  "digest for card NN", "assertions for this card", or asks why a card has
  no digest. Orchestrator seat only: the worker never authors or edits the
  frozen block. Not for interviewing or reviewing the whole card
  (autometta-card-review) or planning a batch (autometta-run-design).
---

# Authoring the oracle

The oracle is the executable form of a card's acceptance criteria
(`docs/dispatch-contract.md`, "Contract tests"). The orchestrator writes it
before any implementation exists and freezes it by digest. In the era when
the template told the worker to write it (cards 101 to 134), 43 per cent of
cards landed clean on attempt 1; since the orchestrator has owned it (card
135 onward), 13 of 15. `autometta first-attempts <repo>` recomputes the
rate.

## Does the card earn one?

Any stage with executable acceptance does. A prose-only, throwaway or
exploratory card leaves the section as `None` and says why in its
Surfacing concern. Decide this first.

## Procedure

1. **Read the whole card**, every Re-brief and amendment included. Card
   113's oracle contradicted an amendment its author had not read.
   Query earlier walls on the same subject:
   `scripts/facts-query.sh --predicate failed-criterion`.

2. **Seat and command per criterion.** Before writing code, name for each
   criterion the seat that judges it (Codex workspace-write sandbox, Claude
   CLI, SDK verifier) and the command that produces its evidence
   (`docs/lessons.md`, gotcha 16). A criterion with no command is a manual
   gate: send it back to the card or to the operator. Confirm the seat can
   run the command at all: network, GUI, writes outside the worktree,
   waiting on a background batch.

3. **One test file, one seam.** Prefer an existing `scripts/*-smoke.sh`, or
   a new one beside it; choose the highest seam that still fails for the
   right reason. One test file per card, because a card records one digest
   (card 101 named two and failed card 152). If a reused smoke carries an
   `AUTOMETTA-CONTRACT-NONE` line, remove it in the same commit: the gate
   rejects a file carrying both markers.

4. **Write the frozen block.** The BEGIN marker names the card
   (`card=stage-cards/NN-slug.md`, or `docs/stages/...` in repos that use
   that layout). Rules:
   - **Everything that decides the verdict goes inside the markers**:
     assertions, assertion helpers, and the fixture builders whose content
     the assertions depend on. Only paths, `fail()`, temp-dir setup and the
     final PASS line stay outside. A helper outside the block can be
     weakened without moving the digest.
   - **A smoke that writes marker text must not contain the markers
     literally**: assemble them (`"AUTOMETTA-CONTRACT-""BEGIN"`), or the
     gate sees two blocks.
   - Expected values come from the card or a literal, never recomputed the
     way the implementation would compute them.
   - Every assertion tests a non-empty value (card 132's vacuous check).
   - Every "do not change X" constraint gets a regression assertion (card
     148 had none and failed on it).
   - Every surface the card names gets its own assertion.
   - For a checker (a lint, a gate), assert precision as well as recall:
     each bad fixture trips exactly one check, and a good fixture trips
     none.
   - Output is terse: one `FAIL: <<card>>: <<reason>>` line, non-zero exit.
   - Portable to this machine: BSD `sed` does not expand `\n` in a
     replacement; on macOS `mktemp -d` lives under `/var`, which git
     reports as `/private/var`.

5. **Prove red on the base.** Run the test on the base branch, before any
   implementation. Record which assertion fails first and why. A test that
   passes on the base tests nothing. A test that fails for a different
   reason than the card intends (a missing module, an environment gap) is
   a baseline finding: record it on the card as unchanged-from-base, do
   not make it a criterion.

6. **Prove green with a throwaway reference.** In a detached scratch
   worktree (`git worktree add --detach <<scratch-dir>> <<base>>`), write
   the smallest implementation that should satisfy the card, in any
   language, and run the test. It must pass every assertion. When it does
   not, decide which side is wrong, and record on the card any trap the
   worker will meet too (in the batch that introduced this skill, the
   reference hit the `/var` path trap above). Then remove it:
   `git worktree remove --force <<scratch-dir>>` and `git worktree prune`.
   Never commit the reference. On a small card, red on the base plus a
   careful read of the block is enough; say so on the card.

7. **Digest and record.** `scripts/check-contract-test-gate.sh print
   <<test-file>>` prints the digest. The card's Contract test section
   carries `Test file`, `Assertions digest` and an `Oracle proof` line:
   which assertion fails today and why, and that a reference passed (or why
   that step was skipped). Commit the test and the card together.

8. **Lint and queue.** `scripts/card-lint.sh --strict <<card>>` must exit 0;
   it checks that the block names this card, carries no NONE marker and
   matches the recorded digest. Then `scripts/add-stage.sh <<repo>> <<card>>`.

## Done when

- Every criterion and every constraint maps to an assertion with a seat
  and a command.
- The test fails on the base at a named assertion for the card's reason,
  and passed the reference, or the card says why that step was skipped.
- Test, digest and Oracle proof are on the card, in one commit with the
  test.
- No scratch worktree or reference branch remains.
