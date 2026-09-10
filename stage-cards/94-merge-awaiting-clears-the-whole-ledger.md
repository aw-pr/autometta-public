# Stage card 94: merge-awaiting clears the whole ledger

## Metadata

- **Authored:** 2026-08-31
- **Orchestrator:** Claude Fable 5 <claude-fable-5@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Opus 5 <claude-opus-5@local>
- **Base branch:** dev
- **Run branch:** autometta/94-merge-awaiting-clears-the-whole-ledger
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Gate:** stage-completed: 91-the-burn-is-visible-while-it-burns
- **Path claims:** scripts/phat-controller.sh, scripts/phat-controller-smoke.sh
- **Pairing rationale:** control-plane bash with a smoke harness beside it,
  the same seats as cards 85 and 88: a codex worker on the shell mechanics,
  a Claude verifier reading the smoke evidence from outside the sandbox.
  Path claims are disjoint from card 93's TUI files, so the two may run as
  a pipeline pair once card 91 lands.

## Objective

`pc_merge_awaiting` with no stage argument is wedged on this repo, observed
twice on 2026-08-31. It selects only the first awaiting record in the
stages array (`[.stages[] | select(.integration.state == "awaiting")][0]`
at scripts/phat-controller.sh:1259). Stage 83 holds a stale record: its
run branch was merged by hand and deleted, so the branch no longer
resolves, the verb logs "surfaced, not touched", and returns without ever
reaching a live candidate. Stages 28 and 90 sat awaiting behind it the
same afternoon and both needed a human with an explicit stage id. A verb
that exists to clear the integration ledger autonomously must not be
blocked forever by the one record it cannot act on.

Two changes, both inside the verb:

1. **Iterate every awaiting candidate**, in stage order, rather than
   stopping at the first. Each candidate gets the existing per-stage
   treatment (progress check, journal decision, merge or surface); one
   candidate's failure or refusal moves on to the next rather than ending
   the pass. The pass's exit code reflects the worst outcome the mandate
   cares about, with merged-at-least-one counting as acted.
2. **Close out a stale record instead of surfacing it forever.** When the
   run branch no longer resolves, check whether the record's `head` commit
   is already contained in the base branch (`git merge-base
   --is-ancestor`). Contained means a human already merged it: write the
   record's state to `merged` through the existing state helpers and
   journal the close-out. Not contained, or no `head` recorded, keeps
   today's surfaced-not-touched behaviour, but no longer blocks the rest
   of the pass.

## Inputs (read these in your own context)

- scripts/phat-controller.sh (`pc_merge_awaiting`, `pc_progress_check`,
  `pc_journal_decision`, the state helpers it already uses)
- scripts/phat-controller-smoke.sh (the merge-awaiting section around
  line 575: "a clean awaiting integration merges, a conflicted one
  surfaces")
- scripts/tick.sh `finalize_run_worktree` and the reap close-out path, for
  the containment check this mirrors

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/phat-controller.sh`: `pc_merge_awaiting` iterates all awaiting
   records when called without a stage id, and closes out stale records
   whose head is contained in the base branch. The explicit-stage-id form
   keeps its current behaviour.
2. `scripts/phat-controller-smoke.sh`: the merge-awaiting section gains
   two checks: (a) a repo whose first awaiting record is stale (branch
   deleted, head merged) and whose second is live ends the pass with the
   stale record closed out and the live branch merged; (b) a stale record
   whose head is NOT contained is surfaced, left awaiting, and does not
   stop a later live record from merging.

## Constraints

- State writes go through the existing state helpers only; no hand-rolled
  YAML edits (lessons.md gotcha 10 applies to every writer).
- The progress-check and escalation contract per stage is unchanged; the
  cap counts per stage, not per pass.
- No change to tick.sh: the tick's own awaiting path is out of scope.
- The verb never resolves a conflicted merge; conflicts still surface,
  per the card 54 mechanism the smoke already pins.
- British English in prose, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

1. `bash -n scripts/phat-controller.sh` and
   `bash -n scripts/phat-controller-smoke.sh` pass.
2. The full `scripts/phat-controller-smoke.sh` passes, including the two
   new checks and the pre-existing merge-awaiting checks unchanged.
3. In the new smoke fixture (a): after one no-arg pass, the stale record
   reads `merged`, the live record reads `merged`, and the base branch
   contains the live head.
4. In the new smoke fixture (b): the uncontained stale record still reads
   `awaiting` after the pass, and the live record behind it reads
   `merged`.
5. With a single explicit stage id, behaviour matches dev today (evidence:
   the pre-existing smoke checks pass unmodified).
6. `git diff --stat` on the run branch touches only the two claimed paths.

## Contract test

- **Test file:** scripts/phat-controller-smoke.sh
- **Assertions digest:** stale-first ledger clears in one pass; uncontained
  stale surfaces without blocking; conflicts still surface unresolved.

## Out of scope

- Scheduling the controller (no LaunchAgent work here).
- The tick's own awaiting/HANDOFF path in tick.sh.
- Rewriting stage 83's live record in this repo's state: the fixed verb
  run by the operator does that after landing.

## Budget

- **Worker wall-clock:** 2400s
- **Verifier wall-clock:** 1800s

## Verifier handoff

Leave the working tree dirty. Report the smoke output verbatim for the two
new checks, the pre-existing merge-awaiting checks, and the diff stat.

## Family-specific notes

None
