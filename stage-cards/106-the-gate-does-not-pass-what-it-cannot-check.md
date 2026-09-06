# Stage card 106: the gate does not pass what it cannot check

## Metadata

- **Authored:** 2026-09-01
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Verifier:** Codex GPT-5.6 Sol <codex-gpt-5-6-sol@local>
- **Base branch:** dev
- **Run branch:** autometta/106-the-gate-does-not-pass-what-it-cannot-check
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/check-contract-test-gate.sh, scripts/gate-smoke.sh, docs/dispatch-contract.md, stage-cards/106-the-gate-does-not-pass-what-it-cannot-check.md
- **Pairing rationale:** cross-family. The Codex seat verifies because the
  observed evidence for this defect came from a Codex SDK verifier run
  (stage 102) and from two Codex verifier runs in emergence-lab that reported
  the opposite outcome from the same condition; the seat that saw both should
  confirm the two paths now agree.
- **Type:** Fail-closed correction on a verification gate.

## Surfacing concern

The gate answers the same question two ways, and they disagree.

`cmd_print` (`scripts/check-contract-test-gate.sh:82-86`) is handed one file
and calls `digest_block` on it. With no the begin marker marker
present it exits 1: `no the begin marker marker found`. It fails
closed.

`cmd_gate` (`:88-96`) walks the staged files and does:

```sh
staged_content "$f" | grep -q "$MARKER_BEGIN" || continue
```

An unmarked file is skipped, silently, and the gate exits 0 having verified
nothing. It fails open.

Both outcomes were observed on 2026-09-01, hours apart, from the same
underlying condition -- a contract test with no marker block and a card whose
Assertions digest field is prose rather than a real digest.

- autometta stage 102 (`state/verifiers/102-the-state-schema-describes-the-state.json`):
  every one of its six criteria PASSed, and the stage was failed by the gate
  going through `print`. Correct behaviour.
- emergence-lab stages 63 and 70 (`state/verifiers/63-point-cloud-metrics.json`,
  `state/verifiers/70-gray-scott-rebaseline.json`): both verifiers recorded the
  gate exiting 0 and both noted, unprompted, that no digest had actually been
  recomputed. Their own words: "the gate had no frozen block/digest to
  validate."

A gate that exits 0 when it could not check anything is not a gate. It is
worse than absent, because a passing gate is read as evidence and an absent one
is not. Both those emergence-lab stages have since been re-queued and are
running through the fail-open path as this card is authored.

## Inputs (read these in your own context)

- `scripts/check-contract-test-gate.sh` (the whole file)
- `scripts/gate-smoke.sh`
- `docs/dispatch-contract.md`, the section describing the contract test and
  the Assertions digest
- `state/verifiers/102-the-state-schema-describes-the-state.json`, the
  `additional_findings` field

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `cmd_gate` stops treating "no marker" as "nothing to check". A staged file
   that a card names as its contract test and that carries no marker block is
   a violation, not a skip.
2. The gate distinguishes the three states rather than two, and the difference
   is the whole card: a file **no card names** is genuinely not its business
   and is skipped as it is today; a file a card names **as its contract test**
   but that carries no marker is a violation; a marked file is recomputed as
   it is today. Absent and broken are different, and only the second is a
   defect.
3. `scripts/gate-smoke.sh` covers all three states, including a regression for
   the fail-open case: stage a card-named test with no marker and assert the
   gate exits non-zero. That case is what nothing currently tests.
4. `docs/dispatch-contract.md` states the rule plainly: a prose Assertions
   digest does not satisfy the contract test requirement, and a card naming a
   test that carries no marker block will not dispatch clean.

## Constraints

- Do not weaken `cmd_print`; it is already correct.
- Existing marked tests must keep passing unchanged. Run the gate across the
  repo's current contract tests and confirm no new violations appear that are
  not genuinely unmarked.
- The pre-commit hook calls this. A change that makes every ordinary commit
  fail is not the fix; the violation must be narrow and reachable only for a
  file some card actually claims.

## Acceptance criteria

1. `bash -n scripts/check-contract-test-gate.sh` clean.
2. A staged contract test that a card names, carrying no marker block, makes
   the gate exit non-zero and the message names the file and its card.
3. A staged file no card names, carrying no marker, is still skipped and the
   gate exits 0.
4. A staged marked file whose block has changed without its card's digest
   changing still fails, exactly as now.
5. `scripts/gate-smoke.sh` passes and contains a case that fails against the
   pre-change gate. Demonstrate that it does.
6. The gate run against the current tree reports only genuine violations, and
   the handoff lists them.

## Contract test

- **Test file:** `scripts/gate-smoke.sh`
- **Assertions digest:** `sha256:d666fc1d10348307f97a75d722d26cef13aa30f48d656f627397c234d94fb082`

## Out of scope

- Adding markers to every existing unmarked contract test across the fleet.
  Deliverable 6 is to *report* them; fixing them is per-repo work.
- Stage 102's own re-queue and the markers for `state-schema-smoke.sh`.
- The subscriber repos' cards.

## Budget

- **Worker wall-clock:** 75 minutes
- **Verifier wall-clock:** 30 minutes

## Escalation

If tightening `cmd_gate` turns out to make a large number of existing cards
fail, stop and report the count with examples rather than either weakening the
rule or mass-editing cards. A migration is a decision for the operator, not a
side effect of a correctness fix.

## Verifier handoff

Reproduce both halves of the disagreement before judging anything: run
`print` and `gate` against the same unmarked, card-named test on the
pre-change script and confirm they disagree, then on the changed script and
confirm they agree. Judge criterion 5 by running the new smoke against the old
gate yourself and watching it fail -- a smoke that passes against both is not
a regression test, and that is the most likely way this card gets passed
wrongly.

## Re-brief 2026-09-06: the smoke must not spell the token it is testing

Attempt 1 passed criteria 1 to 5 and is preserved at
`a6078050d070e13125b3ff494acef9ca0c009dd6`
(`wip/106-the-gate-does-not-pass-what-it-cannot-check-attempt-1`). Adopt it.
It failed criterion 6 and the gate because `scripts/gate-smoke.sh` contains the
begin token four times: the real block at `:353`, a fixture inside a quoted
heredoc at `:435-437`, and a printf fixture at `:453-463`. `extract_block`
(`check-contract-test-gate.sh:34-41`) counts every line holding the token
regardless of quoting or position, so `print` and `gate` both reject the file
as holding more than one block. That is the correct reading of the file, not a
gate defect, so the fix is in the smoke.

The decision, taken above the card after weighing the alternatives: **build
the fixture tokens from the gate's own constants instead of spelling them.**

- In section 4 of `gate-smoke.sh`, read the markers out of the gate script:
  `mk_begin="$(sed -n "s/^MARKER_BEGIN='\(.*\)'/\1/p" "$gate_script")"` and
  likewise `mk_end`. Rewrite the heredoc fixture and the printf fixture to
  emit `"$mk_begin"` and `"$mk_end"` with `%s`. The literal token then appears
  exactly once in the file, at the real block.
- Do not exempt the file by name in `cmd_gate`: this card names it as its
  contract test, so an exemption would make the gate skip the one file the
  card requires it to check. Do not anchor `extract_block` to column zero
  either; that changes the frozen-block definition for every existing test.
- Record a real digest in this card's Assertions digest line from
  `check-contract-test-gate.sh print scripts/gate-smoke.sh`. Path claims now
  include the card. This card's prose has already been reworded so it no longer
  spells the token; keep it that way.
- Criterion 6 stands: the gate against the whole tree reports only genuine
  violations, and the envelope lists them. The gate's own usage comment,
  `docs/dispatch-contract.md`, the worker and verifier prompt templates and
  `HANDOFF.md` all carry the token and will trip the whole-file grep at
  `cmd_gate:132` if staged. That is a real pre-existing defect. Report it in
  the envelope; do not fix it here, it needs its own card.
