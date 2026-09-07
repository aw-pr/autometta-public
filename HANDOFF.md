# Handover

**Status (2026-09-07 20:30):** Batch 108-134 is **complete**. 109 stages
completed, nothing pending, nothing in flight, nothing awaiting merge. The
fleet is refreshed to `fb08d95` and emergence-lab's working tree is clean.
`dev` is pushed.

## State of play

- **autometta is idle with an empty queue.** The machine is free.
- **emergence-lab is paused until 22:00 BST 2026-09-07** by an operator
  record from the previous night ("autometta has the machine overnight
  tonight"). It lifts by itself; clear the record if you want it sooner.
- **A drain expires 2026-09-08 01:06 BST**, after which autometta's cap
  drops back to 600M against ~605M already spent, so it would re-halt on
  `token-cap` if anything were queued. Moot while the queue is empty.
- Spend counters were never reset, so `tokens_spent` is an honest record of
  what this run cost.

## What landed, and the thread running through it

Five stages in this batch failed or nearly failed on **one template
defect**: the stage-card template told whoever held the card to author the
frozen assertion block and record its digest, and whoever holds the card is
the worker. That contradicts `docs/dispatch-contract.md:131`, which exists
so the oracle cannot be tautological. It cost 113, 115, 116, 118 and 123.
**Card 131 fixed it**; `add-stage.sh` now refuses a card that names a test
file without a real digest.

**`check-contract-test-gate.sh` was found wrong about its own inputs four
times, by three different verifiers** (cards 121, 129, 134). It could not
see untracked files, tripped on any file merely mentioning the marker
tokens, gave different answers in `--worktree` and `--staged` about the same
tree, and reported a missing card as a missing digest line. All four are
fixed. This matters more than any single stage: a passing gate is read as
evidence.

**Stage 124 landed with a worker-authored contract test** for the reason
above. Read its verdict knowing that.

**Stage 115's attempt-2 verdict was destroyed** in the state-wipe incident;
its work was re-checked by hand and marked completed. It is the only landed
stage in this batch with no surviving verifier artefact.

## Known defects, surfaced but not carded

- **The tick never reaches its orphaned-verdict scan while a current stage
  is active.** A stage whose worker died after writing a PASS envelope sits
  `in_progress` indefinitely. This hit 108, 110, 114, 116, 118, 120 and 123;
  every one was dispatched to its verifier by hand. **This is the highest-
  value uncarded defect.**
- **A `state_apply_json` write race.** Two verifiers dispatched together
  clobbered one another's `verifier_pid`. Unnoticed, the tick would have
  double-dispatched and burned an attempt.
- **`state-branch-smoke.sh` section 8** fails on clean `dev` and has since
  at least `51a3a3a`; it may read ambient repo state rather than its own
  fixtures. Recorded on card 116.
- **`templates/verifier-prompt.md:15`** tells verifiers to run the gate
  "against the working tree" without naming `--worktree`; a bare invocation
  is staged mode and exits 2 on a dispatch tree. One word, own card.
- **Codex quota readings are stale whenever Codex is idle** - they come from
  its local rollout log, so a figure can sit frozen for hours. Claude's are
  live.
- **Verifier attempt counters understate this batch**, because hand
  dispatches bypass the tick's accounting.

## Two operator notes

- **Never `git add -A` in a run worktree.** Its `state` is a deliberate
  symlink; committing it made git replace the real state directory on the
  next checkout and took `state.yaml`, `budget.json`, every verifier
  artefact and the cost log with it. Recovery came from the
  `autometta/state` snapshot branch, which does not carry artefacts or logs.
- **Editing `dashboard/` in the repo does not reach the page.** Run
  `autometta dashboard` to redeploy, and prefer `--serve --watch` over
  `file://`.

## Unverified by design

The per-stage chart change (`fb08d95`) was made by hand at the operator's
request: ordered by queue newest-first, queued cards at zero, status
colours, and a runs slider. It carries **no verifier and no contract test**.
Checked against a synthetic fixture across three slider positions, and the
three dashboard smokes pass.
