# Learning log: the harness proposals ledger

The fact ledger records what a run established. The escalations folder
records what went wrong this episode. Neither records what the harness
should become. Until now that lived in the run-lessons logs under
`docs/incidents/`, which are prose: nothing can list them, nothing can tell
which ones were acted on, and a lesson from August reaches a card in
November only if someone remembers it.

The proposals ledger closes that gap. It is one append-only JSONL file,
`memory/proposals.jsonl`, committed and shared across both agent families
like `memory/facts.jsonl`. Each line is an event against a proposal: a
suggested change to the harness itself, with the evidence that prompted it,
and then the decisions and the card and commit that followed. The schema is
`schemas/proposals-ledger.json`; the gate and the only writer is
`scripts/proposals.sh` (`autometta proposals`).

The ledger is private-tier: the file stays off the public mirror, and much
of its evidence points at runs in private repositories. The schema, the
script, the skills and every card and commit that results are published,
and each card carries the id of the proposal it answers.

## The weekly cycle

The loop has three beats on different days, and the human sits at the
middle one.

1. **During runs, record.** Every orchestration chat records as it goes,
   following `skills/autometta-learning-log`: where each kind of
   observation belongs, what earns a line (halts, harness-caused failures,
   workarounds, late or missing signals, checks that lied, missing
   guidance), how to write and commit it, and how to record a recurrence.
   The other orchestration skills point there at the moment they meet a
   lesson; on acking an escalation whose diagnosis implicated the harness,
   for instance, the chat writes a `proposed` event
   (`skills/autometta-escalations`, step 7). A verifier that noticed a
   harness defect while verifying writes a `HARNESS:` line in its
   `additional_findings`, and the chat lifts it into the ledger citing the
   artefact. Recording costs one shell command and no model turn. Nothing
   acts on a proposal when it is written.
   A chat left to attend a run alone (`skills/yolo`) records a second sort
   of lesson before it hands back: what its own guidance lacked or got
   wrong, and what it parked for want of authority. Those take a `yolo:`
   title prefix, target `skills/yolo/SKILL.md`, and cite the run log entry
   that shows the decision. The operator's overrulings at the morning
   debrief are recorded the same way.
2. **Once a week, review.** The operator opens an orchestration chat and
   runs `skills/autometta-weekly-review`: lift any `HARNESS:` line the week
   missed (`proposals.sh unlifted`; a stage that passed never escalates, so
   nothing else would surface its line), census the week's processed
   escalations so a halt or failure no chat recorded is still raised, list
   open items, read the
   evidence, merge duplicates into one cause, check the fact ledger for
   recurrence, recommend one decision per cluster, record the operator's
   yes or no. Approved items go to `autometta-run-design`,
   `autometta-card-review` and `autometta-oracle` and become cards carrying
   a `- **Proposal:** <id>` metadata line; the chat records `carded`.
3. **In the quiet window, run.** The cards queue like any others and the
   tick dispatches them under the usual gates, worker in one family and
   verifier in the other. The overnight block in the controller mandate and
   the weekly pace gate are the only scheduling involved. When a card lands,
   the next review records `landed` with the commit.

Saturday morning is the conventional review day, because approved cards
then run through the Saturday and Sunday overnight windows while the
week's subscription quota is still unspent. Nothing in the tooling depends
on the day.

## Why this shape

The idea comes from Google's Harness² and from Retrospective Harness
Optimization: improve the harness around the model rather than the model,
and learn from the runs you already paid for. Harness² adds a probe step
that reruns the task under each candidate edit and keeps what helped. We
leave that out, deliberately:

- **A card with a frozen oracle is the probe.** Every harness change here
  is a stage card with a contract test proven red before and green after,
  verified by the other family. The smoke suite is the regression guard. A
  second rerun loop would pay again for a check the dispatch contract
  already makes.
- **The human is the composer.** Agents proposing edits to their own harness
  is exactly what the load-bearing beliefs fence off. A proposal is a note
  to the review, never authority. Only an `approved` event, recorded with
  the operator's words, lets a change become a card, and a `policy` item
  (caps, gates, allowances, anything the recovery policy says needs an
  explicit yes) needs that yes quoted.
- **Did it help is a ledger question.** The fact ledger's `failed-criterion`
  and `caused-by` lines over the following weeks say whether the mechanism
  recurred. The review reads them before closing an item as `landed`, and a
  cause that stopped recurring on its own is a reason to `reject`, not to
  card.

## The first fortnight

The ledger opened on 2026-11-08. On 2026-11-22 it held 91 proposals: 13
landed, 11 merged into another proposal as the same cause, 67 still open and
none rejected. Two approval rounds had completed the cycle, nine proposals
through seven cards:

| Approved | Card | What changed | Proposals | Attempts |
| --- | --- | --- | --- | --- |
| 2026-11-18 | [175](../stage-cards/175-bounded-hook-history.md) | A finished run's notices are collapsed in an active chat instead of replayed | 1 | 1 |
| 2026-11-18 | [176](../stage-cards/176-interrupted-dispatch-spend.md) | Usage from a quota-refused worker or an aborted Codex verifier is counted, once | 2 | 1 |
| 2026-11-18 | [177](../stage-cards/177-named-verifier-contract.md) | The verifier checks the named frozen contract from the subscriber worktree, even when the test is unchanged | 2 | 2 |
| 2026-11-18 | [178](../stage-cards/178-readiness-headroom.md) | Card preparation compares the spend estimate with the remaining token budget | 1 | 1 |
| 2026-11-22 | [179](../stage-cards/179-serial-claims.md) | An explicit serial flag holds when the card also declares path claims | 1 | 1 |
| 2026-11-22 | [180](../stage-cards/180-verifier-clock.md) | A verdict is timed from the harness's own observation of the finished verifier | 1 | 3 |
| 2026-11-22 | [181](../stage-cards/181-scoped-headroom.md) | The headroom report resolves relative and equivalent repo paths | 1 | 1 |

The first round went from approval to the last landing in about ninety
minutes, the second in a little over an hour. Card 180 fixes a fault the
ledger's own tooling depended on: `unlifted` had been reading the completion
time a verifier wrote into its own report.

Four more proposals landed without a card, as direct fixes the operator
approved in chat, which the record allows (`landed` from `approved`). Those
had no frozen test and no cross-family verifier, so they say nothing about
the gate.

What the fortnight does and does not show:

- **Recording gets used.** Ninety-one lines in fourteen days, from several
  repositories, at one shell command each.
- **Review is the constraint.** Sixty-seven items are undecided. Recording
  is running well ahead of the weekly sitting.
- **The review has not yet said no.** Every decision so far is an approval
  or a merge. Until a `rejected` event exists, the claim that the review
  filters proposals rests on the 67 it has left alone.
- **The gate did its job on harness changes too.** The verifier rejected
  card 177 once and card 180 twice before either landed. A change to the
  harness got no easier a passage than a change to a subscriber.
- **Whether it helped is still open.** Two weeks is too short for the fact
  ledger to show a mechanism staying fixed. The recurrence check described
  under "Why this shape" is the test, and it has not yet been run against
  these seven.

## The record

One proposal is a sequence of events sharing an `id`:

| Event | Written by | Carries | Legal from |
| --- | --- | --- | --- |
| `proposed` | orchestration chat | title, kind, target, change, evidence | nothing |
| `approved` | weekly review, quoting the operator | note | proposed |
| `rejected` | weekly review | note | proposed, approved, carded |
| `merged` | weekly review | into (the surviving id) | proposed |
| `carded` | weekly review, after `add-stage.sh` | stage_id | approved |
| `landed` | weekly review, after the landing | commit | carded, or approved when the operator had the chat fix it directly |
| `dismissed` | weekly review, with the operator's agreement | repo, evidence, note | nothing |

`dismissed` opens and closes in one event. It records a verifier `HARNESS:`
line judged to be outside the harness (the subscriber's own fixture, say),
so `proposals.sh unlifted` stops listing it without a proposal that would
never be approved. `unlifted` treats a line as lifted once a `proposed` or
`dismissed` event under the same repo cites its artefact
(`state/verifiers/<file>.json`, optionally with an anchor) after the
artefact's completion time; a stage re-verified since then is listed again.
That time is the harness's own observation of the finished verifier
(`verifier_completed_at` in the stage record) when its
`verifier_completed_receipt` names the report on disk, and the report's
`ran_at` otherwise (a legacy report, or one rewritten after it was observed).

`kind` is one of `script`, `skill`, `template`, `schema`, `doc`, `policy`.
`target` is one or more repo-relative paths in the autometta checkout, never
absolute. `evidence` is one or more references a reviewer can open: stage
ids, escalation ids, unattended run log ids with an entry number
(`20261116T2200Z-promo-flow#4`, a file under `$AUTOMETTA_HOME/yolo/`), facts
subjects, paths with an anchor, commit SHAs. A
proposal with no evidence is refused at the gate; one whose evidence does
not say what it claims is held or rejected at the review.

Every write carries the recording agent's identity in git author form, from
`--agent` or `$AUTOMETTA_AGENT`, obtained through `agent-whoami`. There is
no default identity, for the same reason the commit author has none: a
plausible wrong name is worse than a refused write.

The ledger is never edited or reordered. A wrong decision is corrected by
the next legal event, so an `approved` item can still be `rejected`, and a
rejected one that turns out to matter is proposed again with the new
evidence. `scripts/proposals.sh lint` checks the schema, the per-event
fields and every transition, and `scripts/proposals-smoke.sh` is its
regression coverage.

## What stays where

- `memory/proposals.jsonl`: suggested harness changes and their lifecycle.
- `memory/facts.jsonl`: typed assertions about landed work, written by the
  tick (`docs/fact-ledger.md`). The review reads it; the proposals script
  never writes it.
- `$AUTOMETTA_HOME/escalations/`: this episode's decision, worked and acked
  during the week (`docs/tick-loop.md`, Escalations). An escalation is often
  the evidence for a proposal; it is not the proposal.
- `$AUTOMETTA_HOME/yolo/`: one decision log per unattended run, written by
  the attending chat before each action (`skills/yolo`). It is the evidence
  for a `yolo:` proposal and the operator's morning reading; like an
  escalation, it is not the proposal.
- `docs/incidents/*-run-lessons-log.md`: the narrative. Keep writing it when
  a run deserves the paragraph; the ledger holds the actionable line.
- `memory/retro-grade-*.md`: rubric drift, a separate weekly advisory
  (`docs/retro-grade.md`). A drift the operator wants fixed becomes a
  proposal.

The tick never writes this ledger. A proposal is a judgement about the
harness, and the loop's own writes are limited to facts about work it has
already judged.
