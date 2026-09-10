---
name: autometta-run-design
description: >-
  Design an Autometta run before anything is queued: decompose the work into
  stage cards, set pairings and gates, size the spend, and declare the
  parallelism plan. Use when the operator asks to "design a run", "plan the
  batch", "queue up a batch", or hands over a set of goals to turn into
  cards. This is the planning half; queueing and minding the live queue
  belong to add-stage.sh and the phat-controller skill.
---

# Designing a run

A run is designed once, before the first card is queued. Everything below is
decided here and written down (in the cards and in the queue order), so the
tick and the controller execute a plan rather than improvising one.

## 1. Decompose into cards

One observable outcome per card, in the shape of `templates/stage-card.md`.
Before writing a criterion, name the seat that will judge it and the command
that produces its evidence (lessons gotcha 16). Never let a smoke supply the
value it is testing.

**Instrumentation and alarm cards dispatch first.** The 2026-08-25 run
queued the outlier alarm behind the heavy refactor it should have been
watching, and a 76.5M-token dispatch ran unremarked (run-lessons entry 18).
If a card in the batch improves the loop's own visibility, it goes ahead of
every card it would have observed.

## 2. Pairing

Cross-family per stage: worker in one family, verifier in the other, per the
load-bearing belief. Additionally, **alternate the worker family across
adjacent stages**. Alternation means a stage's worker and the previous
stage's verifier draw on different provider windows, which is what makes the
pipeline overlap class (section 4) safe against quota contention.

Route the open-ended brief to the stronger tier and the mechanical sweep to
the cheaper one; record the reasoning in the card's pairing rationale.

## 3. Gates

Draw the dependency DAG before ordering the list. Any stage that reads what
another stage writes carries `- **Gate:** stage-completed: <full-stage-id>`.
Express no gate by omitting the line (`none` is refused at queue time).
Cleanup and migration cards that need a quiet tree gate on `queue-empty`.

## 4. The parallelism plan

Declared here, per adjacent pair of stages, and only ever these classes:

- **`serial`** (declared with `- **Dispatch:** serial`; there is no
  default, `add-stage.sh` refuses a card that carries neither this line nor
  `Path claims`): worker N+1 dispatches after stage N lands.
  Correct whenever the pair shares files, either stage touches `tick.sh` or
  `scripts/lib/`, or either card's scope is open-ended.
- **`pipeline`**: worker N+1 may dispatch while verifier N is still
  running. Permitted only when ALL of:
  1. Both cards carry **path claims** (the paths the stage may modify) and
     the claims are disjoint.
  2. Worker families alternate across the pair (section 2), so the overlap
     draws on two provider windows, not one.
  3. Remaining budget headroom covers two large dispatches (p95 of
     `state/cost-log.jsonl` for this repo, not the median), because the cap
     bounds new work, not spend.

Landing policy for a `pipeline` pair, written into both cards:

- Strict queue order: N lands first, always.
- If N **fails**, nothing landed and dev never moved: N+1 lands by plain
  fast-forward. The conflict case is the success case.
- If N **passes**, N+1 is rebased onto the new dev **only if the two diffs
  are file-disjoint** (a mechanical rebase, no judgement). Any conflict
  aborts to a controller escalation; headless conflict resolution stays on
  the forbidden list.
- A FAIL in an overlapped pair drops only that pair to `serial`: the tail
  lands by plain fast-forward, and the next eligible pair may overlap again
  (card 113).

**Mechanical status.** The bounded pipeline mechanism exists. Queue insertion
parses each card's `Path claims:` line, and the tick may overlap worker N+1
with verifier N only after checking claims, alternating families and two-p95
budget headroom. Landing remains ordered and actual-diff checked; a failure
drops only the affected pair to serial. A card without claims must declare
`Dispatch: serial` itself; queue insertion refuses one that declares neither. Cross-repo parallelism remains
independent: two subscribers with fed queues can run concurrently under one
drain.

## 5. Spend plan

Estimate the batch from `state/cost-log.jsonl` (median per role, and the
p95 for the headroom rule). Size the drain as the estimate plus one
outlier, and set its expiry **inside** the current UTC window: a drain that
spans the boundary converts the self-healing daily reset into a 24-hour
halt (run-lessons entry, 2026-08-25 morning). A re-brief is not a discount;
budget attempt 2 at attempt 1's scale unless the re-brief only corrects
details on a preserved tree.

## 6. Hand over

Queue the cards with `add-stage.sh` in gate order, confirm the ticker's
NEXT section shows the intended order, and hand the queue to the tick and
phat-controller. The design session's remaining job is feedback, re-briefs
and landing-boundary commits, not driving dispatches by hand.
