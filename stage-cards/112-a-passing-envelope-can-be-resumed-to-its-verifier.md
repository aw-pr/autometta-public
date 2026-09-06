# Stage card 112: a passing envelope can be resumed to its verifier

## Metadata

- **Authored:** 2026-09-06
- **Orchestrator:** Claude Fable 5.1 <claude-fable-5-1@local>
- **Worker:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Verifier:** Codex GPT-5.6 Sol <codex-gpt-5-6-sol@local>
- **Base branch:** dev
- **Run branch:** autometta/112-a-passing-envelope-can-be-resumed-to-its-verifier
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/phat-controller.sh, scripts/phat-controller-smoke.sh, skills/phat-controller/SKILL.md, stage-cards/112-a-passing-envelope-can-be-resumed-to-its-verifier.md
- **Pairing rationale:** cross-family. The verb edits state by hand-rules the operator currently
  applies by hand; the verifier reproduces the exact 2026-09-03 state and
  confirms the verb, not the operator, clears it.
- **Type:** Controller verb. No `tick.sh` change; pipeline-eligible with a disjoint neighbour.

## Surfacing concern

On 2026-09-03 stage 70 in emergence-lab had a passing envelope that no
verifier ever consumed: a previous session had restored the worktree state
link and set `in_progress` by hand but left `stall_marker` set and
`current_stage` null, and with `current_stage` null the tick never looks at
the stage (`docs/runs/2026-09-03-evening-watch.md:12`). The fix was a hand
edit of two fields, which the requeue skill says never to do.

## Objective

`autometta` (via phat-controller) has a `resume-to-verifier <repo> <stage>`
verb that takes a stage whose envelope already reads `pass` and whose run
worktree stands, and puts it in exactly the state the tick needs to dispatch
its verifier on the next fire, refusing every other shape.

## Inputs (read these in your own context)

- `scripts/phat-controller.sh`, the `requeue` and `merge-awaiting` verbs
  and their preconditions, as the shape to copy
- `scripts/tick.sh`, the branch that dispatches a verifier when a completed
  envelope is present (grep `has a completed worker envelope`), to learn the
  exact fields it reads
- `scripts/phat-controller-smoke.sh`
- `skills/phat-controller/SKILL.md`

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. `pc_resume_to_verifier`: preconditions, all refused with a named reason:
   the stage exists; its envelope exists and reads `status: pass` (or
   `partial`, with a `--accept-partial` flag); its run worktree and branch
   exist; no verifier pid is alive for it; no other stage is `current_stage`.
   Then: `status: in_progress`, `current_stage: <id>`, `stall_marker: null`,
   `worker_pid: null`, verifier fields cleared, and a log line. Nothing else.
2. Wired into the verb table and `usage`.
3. `scripts/phat-controller-smoke.sh` gains: the 2026-09-03 shape resumes and
   a following tick dispatches a verifier (assert on the log line, with the
   verifier spawn stubbed); a stage with no envelope is refused; a stage
   whose worktree is gone is refused; a repo with another `current_stage` is
   refused. Frozen block around the new assertions.
4. `skills/phat-controller/SKILL.md`: the verb in the procedure list, with
   the one-line rule for when to use it versus `requeue`.

## Constraints

- Write state only through `state_apply_json` or the helper the
  controller already uses; no `yq -i` on `state.yaml`.
- Refuse, never repair: a missing worktree is a `requeue`, not a resume.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. The 2026-09-03 fixture shape resumes; the next tick's log shows a
   verifier dispatch for that stage and nothing else changed in `state.yaml`
   (diff the file before and after, only the named fields differ).
2. Each refusal case exits non-zero with its reason and leaves `state.yaml`
   byte-identical.
3. `scripts/phat-controller-smoke.sh` passes; the resume case fails against
   the pre-change controller (verb unknown).
4. `autometta --help` or the controller usage lists the verb.

## Contract test

- **Test file:** scripts/phat-controller-smoke.sh
- **Assertions digest:** frame the assertions in a block between the begin
  marker and the end marker, the begin marker naming this card by its
  `card=stage-cards/112-a-passing-envelope-can-be-resumed-to-its-verifier.md` field, and replace this line's text with the real
  digest printed by `scripts/check-contract-test-gate.sh print scripts/phat-controller-smoke.sh`. Do not
  write a `sha256:` comment inside the block, and do not spell the marker
  tokens anywhere in this card's prose; the card is in your path claims for
  exactly this edit.

## Out of scope

- Resuming a stage to its *worker*.
- Changing what the tick does with an envelope; the verb produces the state
  the tick already understands.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes

## Escalation

If the tick's envelope branch reads fields beyond those listed (check it
before writing the verb), set exactly what it reads and list them in the
envelope. If it needs a field the verb cannot know, stop and report.

## Verifier handoff

Recreate the stage 70 shape from the watch log in a fixture and run the
verb, then a real tick with the verifier spawn stubbed. Diff `state.yaml`
before and after the verb: the list of changed keys must be exactly the
card's list. Try every refusal, and one it does not list: a stage whose
envelope reads `fail`.

## Family-specific notes

None

## Seat history (2026-09-06)

The Codex subscription closed at 10:31Z and this batch was re-seated onto
Claude alone; when Claude session windows then drained faster than the batch
was sized for, the verifying seat moved to the free local route
(`gpt-oss:120b` via `codex exec --oss`). The Codex window reopened the same
afternoon and the card is back on the seats it was authored with. Nothing
about the work changed across either move.
