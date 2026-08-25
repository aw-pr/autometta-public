# Stage card 64: a declared gate is an enforced gate

## Metadata

- **Authored:** 2026-08-25
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Base branch:** dev
- **Run branch:** autometta/64-a-declared-gate-is-an-enforced-gate
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Gate:** none, deliberately. A card about unenforced gates should not add
  another one for an operator to enforce by hand. Queue it after 62, which
  also edits `scripts/tick.sh`, to keep the two diffs from meeting.
- **Pairing rationale:** the change is bash control flow plus a state schema
  field, written by the family that lives in `tick.sh`, and verified by the
  family that can replay a dispatch and read what the loop actually did with
  a stage it should not have started.

## Objective

Four stage cards carry a `Gate:` line. Nothing reads it.

`scripts/add-stage.sh:62` builds the stage record from three fields it
extracts from the card, `id`, `worker` and `verifier`, and writes ten keys
into `state.yaml`. `Gate` is not among them. `scripts/tick.sh:1916` then
selects the next stage with a single predicate:

```sh
next_stage="$(state_json "$state_yaml" | jq -r '.stages[] | select(.status == "pending") | .id' | head -n1)"
```

Position in the list is the only thing standing between a gated stage and a
worker. The comment above that line already records that the predicate was
widened once before, so that a superseded stage sitting ahead of a pending
one is stepped over. A gated stage is the same shape of problem and has not
been given the same treatment.

The gate is therefore enforced by the worker: the loop dispatches, the agent
reads `state.yaml`, finds the prerequisite unmet, and refuses. That is a real
agent doing the right thing, and it is expensive. On 2026-08-24 and 25 it
cost three dispatches, stage 50 twice and stage 60 once, each one a run
worktree cut, a run branch created, an agent spawned and a chunk of the token
window spent to learn a fact the tick could have read from a file for free.

It is also recorded wrongly. A worker that refuses an ungated stage exits
without a passing envelope, so the loop marks the stage `failed`. Stages 50
and 60 are sitting at `failed` this morning and neither has failed at
anything. An operator reading that queue cannot tell a stage that was
attempted and did not work from a stage that was never eligible to start, and
the difference decides whether the right next move is a re-brief or a wait.

The gate syntax is not uniform either, which is part of why nothing parses
it. Card 51 spells it `- **Gate: card 46 completed first.**`, with the
condition inside the bold span. Cards 58, 60 and 61 spell it `- **Gate:**
after 58.`, with the condition outside it and the stage named by number
rather than by id. Two shapes, four cards, no parser.

Two gate conditions actually exist in the queue today and both must survive
this card:

- **After a named stage.** Cards 58, 60 and 61. The gate is met when that
  stage is `completed`.
- **When the queue is empty.** Card 50, whose own body forbids moving stage
  cards while any stage is `pending` or `in_progress`. That is not a
  dependency on one stage, it is a condition on the whole queue, and it is
  why 50 is held back by hand as the deliberate last stage of every run.

After this card, a declared gate is read at queue time, checked before
dispatch, and a stage whose gate is unmet is never started and never called
failed.

## Inputs (read these in your own context)

- `scripts/add-stage.sh`, the `extract_identity` helper and the `.stages +=`
  block that defines the stage record.
- `scripts/tick.sh:1916` and the dispatch branch below it, down to the
  `spawn-worker.sh` call, including the `budget_gate_dispatch` refusal
  immediately above it, which is the closest existing precedent for
  declining to dispatch without mutating state.
- `schemas/state.schema.json`, for where a new stage field belongs.
- The four cards carrying a `Gate:` line today: 51, 58, 60, 61.
- `examples/self-host/50-stage-cards-live-in-stage-cards.md`, whose gate is
  the queue-empty shape and whose constraint section explains why.
- `scripts/phat-controller.sh:886`, which already counts stages that are
  `pending` or `in_progress`, and is the existing expression of "the queue is
  empty".

## Deliverables

1. **One declared gate syntax**, documented where card authors will see it.
   It must express both conditions above, and it must name a prerequisite by
   full stage id rather than by number, because a bare number is ambiguous
   against a list whose ids are slugs. Migrate all four existing cards onto
   it in this change.
2. **`add-stage.sh` parses the gate** and records it on the stage. A card
   with no `Gate:` line queues exactly as it does today. A card whose `Gate:`
   line is present but does not parse is **refused at queue time**, with a
   message naming the line, so the failure lands at the cheap moment rather
   than at dispatch. Do not let an unparseable gate reach the tick and decide
   the queue's behaviour there.
3. **The tick checks the gate before dispatching.** A stage whose gate is
   unmet is not selected. Selection steps over it to the next pending stage
   whose gate is met, in the same spirit as the superseded case already
   documented at that line.
4. **A gated stage stays `pending`.** No run worktree, no run branch, no
   agent, no attempt counter movement, no state mutation beyond whatever
   record you keep of the skip. `pending` is the honest status: the stage is
   queued and eligible later.
5. **The skip is visible without reading `state.yaml`.** The tick log says
   which stage was stepped over and which condition is unmet. A queue that
   looks stalled must be distinguishable from a queue that is correctly
   waiting, because on 2026-08-25 an hour was lost to exactly that confusion
   in the neighbouring case of a null `current_stage`.
6. **Stages 50 and 60 are corrected in the record.** Both are `failed` today
   and neither failed. Return them to `pending` as part of this change and
   say in the handoff envelope which condition each is now waiting on.
7. **A regression smoke.** A queue holding a gated stage ahead of an ungated
   one dispatches the ungated one and leaves the gated one pending. Prove it
   dispatches the gated one on a pre-fix checkout.

## Constraints

- Do not enforce a gate by reordering `state.yaml`. Order is the operator's
  record of intent and the gate is a condition; conflating them loses both.
- Do not introduce a `blocked` or `gated` status. A gated stage is pending.
  Adding a status means every reader of the queue, the ticker, the dashboard
  and the controller, must learn it, and none of them needs to.
- The gate is a precondition for dispatch, not a precondition for queueing.
  A card whose gate is unmet still gets added by `add-stage.sh`.
- Do not make the gate a scheduling language. Two conditions exist; implement
  those two. No expressions, no boolean combinations, no time windows.
- A stage whose gate names an id that is not in the queue must not silently
  wait forever. Decide what that means, implement it, and say why in the
  handoff envelope.
- Leave `budget_gate_dispatch` alone. It refuses on spend and this refuses on
  order; they are separate checks that happen to sit next to each other.

## Acceptance criteria

1. The gate syntax is documented in one place, and all four cards that
   declare a gate today use it. Show the four lines.
2. `add-stage.sh` writes the parsed gate onto the stage record. Show the
   record for a card with a gate and for one without.
3. A card with an unparseable `Gate:` line is refused by `add-stage.sh` with
   a message naming the line, and nothing is added to `state.yaml`.
4. A tick facing a pending gated stage whose prerequisite is not `completed`
   dispatches nothing for it and leaves it `pending`. Show no worktree under
   the run path, no run branch, and an unchanged stage record apart from any
   skip record.
5. The same tick dispatches the next pending stage whose gate is met, so one
   gated stage does not hold the queue.
6. The queue-empty gate holds: with any stage `pending` or `in_progress`,
   stage 50 is not dispatched; with none, it is.
7. The tick log names the skipped stage and the unmet condition.
8. Stages 50 and 60 read `pending` in `state.yaml` after this change.
9. The regression smoke dispatches the gated stage on a pre-fix checkout and
   does not after.

## Contract test

Replay the 2026-08-24 dispatch of stage 60: a queue in which 60 is pending
and 58 is not yet `completed`. On the pre-fix tree the tick cuts a worktree
and spawns a worker that reads `state.yaml` and refuses, and the stage lands
`failed`. After this change the same queue leaves 60 pending, spawns nothing,
and logs the unmet condition. Show both runs.

## Out of scope

- Any change to how a stage that genuinely fails is recorded. This card is
  about stages that never should have started.
- The `Gate:` line's effect on the manual orchestrator dispatch path in
  `CLAUDE.md`. An orchestrator dispatching by hand reads the card.
- Stage 36, which has been `failed` for eight days for unrelated reasons and
  is not to be touched.

## Budget

- **Worker wall-clock:** 90 minutes
- **Verifier wall-clock:** 45 minutes

## Verifier handoff

Return the four migrated gate lines, the two stage records with and without a
gate, the refusal message for an unparseable line, both halves of the
step-over behaviour with the run path shown empty, the queue-empty case in
both states, the tick log line, the corrected statuses for 50 and 60, and the
smoke failing before and passing after.

## Family-specific notes

None
