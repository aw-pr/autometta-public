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

## Keep proof proportional

Use the shared preparation allowance in `autometta-card-review`; this skill
gets no separate budget. A reference checks whether the oracle can distinguish
correct from incorrect behaviour. It is not a second production implementation.
Prefer a minimal fixture, a local seam or an already valid implementation path.
Do not require full end-to-end reference green for every card regardless of cost.
If proving the test requires doing most of the worker's job, stop and use a
bounded implementation attempt with explicit evidence obligations, or split the
card. Apply an already authorised exception without asking again.

Frozen assertions remain orchestrator-owned. Under an explicitly authorised
coverage exception, freeze the validated core and name the uncovered outcomes
and supplemental worker/verifier evidence separately. A defective check must be
labelled diagnostic or excluded, never passed. The independent verifier must
validate supplemental measurements and their raw evidence; missing evidence
cannot earn overall PASS. Do not weaken historical frozen tests or invent an
exemption for a card with executable acceptance.

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

6. **Bound the positive proof.** Exercise a minimal passing fixture or a
   narrowly scoped throwaway reference when it cheaply catches an impossible or
   toothless assertion. Pair it with the intended base failure; check that bad
   fixtures fail for the correct reason. For a small, clear change, red plus a
   careful assertion review can suffice; record the limitation. A full reference
   is justified only when the risk it resolves warrants the additional cost
   within the shared preparation allowance. Do not iterate a reference until it
   becomes the implementation. If the operator accepts a bounded attempt before
   complete proof, record the exact coverage exception and remaining evidence
   gate. Preserve useful scratch results; never discard the only evidence or
   imply that a reference passed when it did not. Keep reference behaviour out
   of the dispatch baseline unless it is deliberately delivered as a separate
   implementation change.

7. **Digest and record.** `scripts/check-contract-test-gate.sh print
   <<test-file>>` prints the digest. The card's Contract test section
   carries `Test file`, `Assertions digest` and an `Oracle proof` line:
   which assertion fails today and why, and that a reference passed (or why
   that step was skipped). Commit the test and the card together.

8. **Lint and queue.** `scripts/card-lint.sh --strict <<card>>` must exit 0;
   it checks that the block names this card, carries no NONE marker and
   matches the recorded digest. Then `scripts/add-stage.sh <<repo>> <<card>>`.

## Done when

- Every criterion and constraint maps to a frozen assertion or an explicitly
  authorised supplemental evidence gate with a seat and command.
- The test fails on the base at a named assertion for the card's reason,
  and passed the reference, or the card says why that step was skipped.
- Test, digest and Oracle proof are on the card, in one commit with the
  test.
- Scratch work is clearly labelled and separated from the dispatch baseline;
  preserve evidence before any cleanup.
