# Run lessons log: 2026-08-31 (run-20260831-093047)

Running log for this run, same contract as the 2026-08-24 log: add entries
here rather than starting a new document for this run.

## 1. The pipeline pair orphans the head stage's verdict

Stage 88's verifier wrote a full six-criterion PASS at 11:24:57Z, and the
stage then sat `in_progress` with that verdict unconsumed for over two
hours while ticks idled past it. The cause is structural, not a crash: the
tick's verdict-consumption path runs only for the stage named by
`current_stage` (`scripts/tick.sh`, the artefact check inside
`process_repo`), and `current_stage` is one pointer. Card 68's pipeline
pair deliberately runs two stages at once - 87's worker was dispatched
under 88's live verifier - so the pointer moved to 87, and each landing
(87 at 11:37Z, then 89 at 12:33Z) set `current_stage = null` on its way
out. Nothing was left pointing at 88, and no other code path scans
`in_progress` stages for a dead verifier pid with an artefact on disk.
The queue looked healthy throughout: ticks ran, gates were evaluated,
90 and 91 were stepped over, and the one stage holding a PASS was
invisible.

Recovery was the documented orphaned-pointer fix from the 2026-08-25
handoff: repoint `current_stage` at the stage with yq, refresh the `.bak`,
run one tick. The verdict was consumed immediately and 88 landed as
`3b052c7`.

The hole is card-shaped: a single `current_stage` pointer cannot represent
the two concurrent stages the pipeline pair creates. Either the
consumption path scans every `in_progress` stage whose verifier pid is
dead and whose artefact exists, or the pair keeps a second pointer for the
verifying head. Until one of those lands, any pipeline pair whose tail
lands while the head is still verifying will strand the head's verdict,
and the symptom is silence.
