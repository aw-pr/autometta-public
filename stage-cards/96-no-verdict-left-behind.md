# Stage card 96: no verdict left behind

## Metadata

- **Authored:** 2026-08-31
- **Orchestrator:** Claude Fable 5 <claude-fable-5@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Opus 5 <claude-opus-5@local>
- **Base branch:** dev
- **Run branch:** autometta/96-no-verdict-left-behind
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Gate:** stage-completed: 91-the-burn-is-visible-while-it-burns
- **Path claims:** scripts/tick.sh, scripts/pipeline-pair-smoke.sh
- **Pairing rationale:** tick-loop surgery with its smoke harness beside
  it; codex worker on the mechanics, Claude verifier outside the sandbox.

## Objective

Incident 2026-08-31 section 1 ("the pipeline pair orphans the head
stage's verdict", docs/incidents/2026-08-31-run-lessons-log.md): stage
88's verifier wrote a full PASS and the stage then sat `in_progress` for
over two hours, because verdict consumption runs only for the stage named
by `current_stage`, the pair had moved that pointer to the tail, and each
landing nulled it on the way out. The queue looked healthy while a PASS
lay unread; the symptom is silence. `pipeline.pair_on` is off in this
repo's manifest today purely as mitigation, trading wall clock for
safety.

Close the hole the way the incident names first: the tick's verdict
consumption scans every `in_progress` stage whose registered verifier pid
is dead and whose artefact exists on disk, rather than trusting the
single `current_stage` pointer. `current_stage` remains as display and
fast-path; the scan is the correctness backstop, and it also covers a
verdict orphaned by a crash or restart outside the pair mechanism.

## Inputs (read these in your own context)

- docs/incidents/2026-08-31-run-lessons-log.md, section 1
- scripts/tick.sh (`process_repo`, the artefact check and the
  verdict-consumption path)
- scripts/pipeline-pair-smoke.sh (the harness this extends)

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/tick.sh`: verdict consumption iterates the `in_progress`
   stages; for each with a dead (or absent) verifier pid and a validating
   artefact at the expected path, the existing consumption path runs
   exactly as it would have under `current_stage`. Ordering: heads before
   tails (stage order), one consumption per stage per tick, and the
   existing single-stage behaviour is byte-for-byte preserved when only
   `current_stage` is live.
2. `scripts/pipeline-pair-smoke.sh`: a regression check reproducing the
   incident shape: head verifying, tail lands and nulls `current_stage`,
   head's verifier exits leaving a PASS artefact; the next tick consumes
   the head's verdict and the stage completes.

## Constraints

- No new state files or pointers; the scan derives everything from
  `state.yaml`, the registry, and the artefact paths already in use.
- A stage whose verifier is still alive is never touched by the scan.
- The dirty-tree and lock guards in `process_repo` keep their current
  order; the scan sits inside the existing per-repo pass.
- British English in prose, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

1. `bash -n scripts/tick.sh` and `bash -n scripts/pipeline-pair-smoke.sh`
   pass.
2. The full `scripts/pipeline-pair-smoke.sh` passes, including the new
   regression check and every pre-existing check unchanged.
3. In the new check's fixture, after the tail lands, one tick completes
   the head stage from its on-disk PASS with `current_stage` null
   throughout (evidence: the state transitions and the tick log lines).
4. A fixture with a live verifier pid is left alone by the scan (evidence:
   state unchanged after a tick).
5. `git diff --stat` on the run branch touches only the two claimed paths.

## Contract test

- **Test file:** scripts/pipeline-pair-smoke.sh
- **Assertions digest:** an orphaned PASS is consumed on the next tick;
  live verifiers are never touched; single-stage behaviour unchanged.

## Out of scope

- Re-enabling `pipeline.pair_on` in any repo's manifest (operator
  decision after this lands).
- A second `current_stage`-style pointer (the incident's alternative
  design; the scan supersedes it).
- The FAIL/re-brief path beyond what consumption already does.

## Budget

- **Worker wall-clock:** 14400s
  (raised 2026-08-31 21:25: not a work estimate. The worker passed in six
  minutes; the stage has since sat through provider pauses, and the
  pre-card-97 stall check charges paused hours against this figure. The
  headroom stops a third bogus stall until 97 lands and restores honest
  arithmetic.)
- **Verifier wall-clock:** 1800s

## Verifier handoff

Leave the working tree dirty. Report the new smoke check's output
verbatim, the pre-existing checks' summary, and the diff stat.

## Family-specific notes

None

## Re-brief (attempt 2, 2026-08-31)

Attempt 1 produced the work and was killed before the paperwork: the tick's
budget enforcement (2400s + 50% grace) terminated the worker at 5168s,
before the handoff envelope was written. The diff itself is sound. It is
preserved as commit acc6170 (also on
origin/autometta/96-no-verdict-left-behind), and the orchestrator ran the
full smoke against it: every check passes, including the new orphaned
verdict recovery regression.

Your job is to land that work, not redo it:

1. Restore the preserved diff into your working tree:
   `git checkout acc6170 -- scripts/tick.sh scripts/pipeline-pair-smoke.sh`
   (a tree-only checkout; make no git commits, as ever).
2. Read the restored diff and satisfy yourself it meets the card; fix
   anything that does not.
3. Run the acceptance criteria and collect the evidence.
4. Write the handoff envelope. This is the step attempt 1 died before;
   do not skip it, and do not start open-ended extra validation once the
   criteria have their evidence. The budget above is sized for
   validate-and-envelope, not a rebuild.
