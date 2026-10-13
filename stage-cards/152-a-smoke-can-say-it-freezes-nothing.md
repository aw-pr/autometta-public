# Stage card 152: a smoke can say it freezes nothing

## Metadata

- **Authored:** 2026-10-11
- **Orchestrator:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Base branch:** dev
- **Run branch:** autometta/152-a-smoke-can-say-it-freezes-nothing
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Dispatch:** serial
- **Pairing rationale:** Terra for a mechanical gate rule and a one-line
  sweep over 33 files. Opus verifies because the contract-test gate is a
  safety mechanism: the card must open exactly one explicit door and leave
  the fail-closed rule standing everywhere else. Serial and queued last,
  because the sweep touches 33 smoke files and must not race any card that
  edits one.

## Surfacing concern

Cards 113 and 150 each made a mandated edit to `scripts/tui-smoke.sh`, and
each time the contract-test gate reported a violation the verifier had to
reason past. The gate refuses an edit to any `scripts/*-smoke.sh` that
carries no frozen block, which closed a real fail-open defect. But 33 of
the 73 smokes are regression suites that no card freezes (card 80 names
`tui-smoke.sh` with `Assertions digest: None`), so every edit to one of
them reads as a violation. A gate that cries wolf on routine edits trains
verifiers to wave its output through.

## Objective

A smoke can declare, on a line of its own, that it freezes nothing and
why: `AUTOMETTA-CONTRACT-NONE reason=<text>`. The gate accepts an edit to
such a file. It still refuses a smoke with neither marker, an opt-out
without a reason, a file carrying both markers, and an opted-out file that
a card names with a real `sha256:` digest. Every unfrozen smoke in the repo
carries the opt-out.

## Inputs (read these in your own context)

- `scripts/contract-optout-smoke.sh`: the frozen contract; read it first.
- `scripts/check-contract-test-gate.sh`: `cmd_gate` and its comments.
- `docs/dispatch-contract.md` section "Contract tests".

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/check-contract-test-gate.sh`: the opt-out rule above, checked
   before the frozen-block branch, with a warning naming the file for each
   refusal. `print` is unchanged. The header comment documents the marker.
2. Every `scripts/*-smoke.sh` that has no `AUTOMETTA-CONTRACT-BEGIN` line
   gains one comment line directly after its shebang:
   `# AUTOMETTA-CONTRACT-NONE reason=<short reason>`. Use a reason that is
   true of the file, such as `regression suite; no stage card freezes it`.
   No other change to those files.
3. `docs/dispatch-contract.md`: a short paragraph under "Contract tests"
   naming the opt-out, when it is right (a regression suite) and when it is
   not (any test a card relies on as its contract).

## Constraints

- The frozen block in `scripts/contract-optout-smoke.sh` is read-only.
- A smoke with neither marker is still refused; do not widen the door.
- Do not add a frozen block to any existing smoke, and do not edit any
  existing frozen block.
- British English in prose, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. `bash scripts/contract-optout-smoke.sh` passes on the run branch, run by
   the verifier, and `scripts/check-contract-test-gate.sh print
   scripts/contract-optout-smoke.sh` prints the digest recorded below.
2. `scripts/check-contract-test-gate.sh --worktree` exits 0 on the run
   branch against `dev`.
3. `git diff dev --stat` shows each swept smoke with exactly one added line,
   and the verifier runs at least `tui-smoke.sh`, `dashboard-liveness-smoke.sh`,
   `gate-smoke.sh` and three more swept smokes of its choosing, all passing.
4. The verifier shows, in a scratch copy, that removing the opt-out line
   from one swept smoke and editing it makes the gate refuse again.
5. `bash -n` passes on the gate and on every swept smoke.

## Contract test

- **Test file:** scripts/contract-optout-smoke.sh
- **Assertions digest:** `sha256:fe7a48e6cea4479f4c11f1169dc513f57a05626844115dbd292ea65c46156f09`

The orchestrator authored the frozen block on 2026-10-11. It fails today at
its second case, because the gate refuses an opted-out smoke; the first
case, the fail-closed rule, already passes and must keep passing. A
throwaway reference implementation passed every case.

## Out of scope

- Freezing any regression suite.
- Card 80's metadata, which is consistent with the opt-out as written.

## Budget

- **Worker wall-clock:** 30 minutes
- **Verifier wall-clock:** 25 minutes
- **Spend basis:** planning allowance 4M tokens under the 2026-10-11 drain.

## Dispatch envelope

Write `state/envelopes/152-a-smoke-can-say-it-freezes-nothing.json` using `schemas/envelope.json`. List
changed deliverables, the exact smoke commands and their results, and any
criterion you could not satisfy with why. Do not self-verify or land your
own branch. The verifier writes `state/verifiers/152-a-smoke-can-say-it-freezes-nothing.json` under the
existing verifier contract, giving a criterion-by-criterion verdict.

## Re-brief after attempt 1 (2026-10-11)

Attempt 1 passed criteria 1, 3, 4 and 5 and failed criterion 2:
`check-contract-test-gate.sh --worktree` refused `scripts/state-writable-smoke.sh`,
because card 101's Test file line named it beside `effort-flags-smoke.sh`
with one digest that belongs only to the latter. That was a defect in card
101's metadata, not in the worker's gate, and the orchestrator has corrected
card 101 on `dev`. With that correction, attempt 1's tree passes the gate
and the frozen smoke (checked by the orchestrator).

Attempt 1 is pinned at `a7e2b1bdcc0624737220487f4bf6de06a9125ace` on
`wip/152-a-smoke-can-say-it-freezes-nothing-attempt-1`. Start from it
(`git cherry-pick a7e2b1bdcc0624737220487f4bf6de06a9125ace`) rather than
from scratch. Then run, and report in the envelope, every acceptance
command you can run in your sandbox, `scripts/check-contract-test-gate.sh
--worktree` first: attempt 1's envelope said its smoke commands were not
run.

Cards 97, 99 and 32 name `budget-cap-smoke.sh`, `verifier-route-matrix-smoke.sh`
and `cost-log-smoke.sh` with prose or placeholder digests. None of those
files has ever carried a frozen block, so the opt-out describes them
truthfully; leave them swept.
