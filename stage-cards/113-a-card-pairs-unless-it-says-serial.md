# Stage card 113: a card pairs unless it says serial

## Metadata

- **Authored:** 2026-09-06
- **Orchestrator:** Claude Fable 5.1 <claude-fable-5-1@local>
- **Worker:** Codex GPT-5.6 Sol <codex-gpt-5-6-sol@local>
- **Verifier:** Claude Opus 5 <claude-opus-5@local>
- **Base branch:** dev
- **Run branch:** autometta/113-a-card-pairs-unless-it-says-serial
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Gate:** stage-completed: 111-dev-moving-does-not-park-a-disjoint-landing
- **Path claims:** scripts/add-stage.sh, scripts/tick.sh, scripts/pipeline-pair-smoke.sh, schemas/state.yaml.json, templates/stage-card.md, docs/tick-loop.md, docs/dispatch-contract.md, stage-cards/113-a-card-pairs-unless-it-says-serial.md
- **Pairing rationale:** cross-family. The Codex seat changes the pairing rules; the Opus seat
  verifies because the change is to *when* two agents may share a repo, and
  the failure mode is a collision that only shows under a real double
  dispatch, which the verifier must stage.
- **Type:** Parallelism policy. Touches `scripts/tick.sh`, so serial itself.

## Surfacing concern

Pipeline pairing has fired four times in this repo's history against 24
refusals, and two-stage overlap accounts for 4% of in-flight time in
autometta and 0.5% in emergence-lab. The causes, measured on 2026-09-06:

- 58 of 86 autometta stage records and 47 of 56 in emergence-lab carry no
  `path_claims`, and `scripts/tick.sh:984` returns before logging when
  either side has none. A card without claims is silently serial.
- A single member failure sets `pairing_disabled_stage`
  (`scripts/tick.sh:860-872`) and pairing stays off for the whole repo
  until that stage's re-brief lands. Autometta has been latched off on
  stage 106 since 2026-09-01.
- `pipeline_claims_require_serial` (`:836-842`) refuses any claim under
  `scripts/tick.sh` or `scripts/lib`, which is right for the head, but also
  refuses when only the *tail* is a docs-only card that could not collide
  with anything.

The verifier phase is 6.5 minutes at the median, about a third of a stage's
agent time, and that is what overlap would recover on every landed stage.

## Objective

Pairing is the default: a card declares path claims or declares itself
`serial`, one failure does not switch pairing off for the repo, and a tail
whose claims cannot touch what the head is changing is not refused.

## Inputs (read these in your own context)

- `scripts/add-stage.sh:32-63`, `extract_path_claims`
- `scripts/tick.sh:820-1050`, the pairing preconditions, the latch and the
  serial-only rule
- `scripts/tick.sh:1093-1100` and `:1187-1200`, what happens on a member
  failure
- `scripts/pipeline-pair-smoke.sh`
- `templates/stage-card.md`, the Path claims comment
- `docs/tick-loop.md`, the pipeline section, and `docs/dispatch-contract.md`
  where it describes pairing
- `docs/incidents/2026-08-31-run-lessons-log.md:8-21`, the orphaned-verdict
  incident, which is the risk this card must not reintroduce

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. `scripts/add-stage.sh` refuses a card that has neither a Path claims
   line nor a line `- **Dispatch:** serial`, with a message quoting both
   forms. `templates/stage-card.md` documents the choice as required.
2. `scripts/tick.sh`: a member failure drops the *current* pair to serial
   (unchanged) but does not set `pairing_disabled_stage`; instead a
   per-stage `pairing_failures` counter is kept and pairing is refused only
   for a stage that has failed while paired twice. Remove the latch and its
   refresh, or leave them reachable only via a manifest key
   `pipeline.latch_on_failure: true`.

   `schemas/state.yaml.json` permits the new per-stage `pairing_failures`
   field. The repo's strict state-schema invariant means a state field that
   the schema does not permit is a defect, so the schema edit is part of
   this deliverable rather than a consequence of it. Add the field and
   nothing else; do not relax the schema's additional-properties handling to
   avoid naming it.
3. `pipeline_claims_require_serial` applies to the head always, and to the
   tail only when the tail's claims include `scripts/tick.sh` or
   `scripts/lib`; a docs-only or smoke-only tail behind a `tick.sh` head is
   allowed when their claims are disjoint.
4. `scripts/pipeline-pair-smoke.sh` gains: a claimless card is refused at
   queue time; a `serial` card queues; a pair forms after a prior member
   failure; a docs-only tail pairs behind a `tick.sh` head; a tail claiming
   `scripts/lib` behind any head is still refused. Frozen block around the
   new assertions.
5. `docs/tick-loop.md` and `docs/dispatch-contract.md` state the new rules,
   and list the risks this card knowingly accepts: two dispatches may share a
   provider window when `pair_on` is `off`; budget headroom is checked at
   dispatch and tokens are accounted at reap, so a pair can overshoot the cap
   by up to two p95s.

## Constraints

- Strict landing order and the actual-diff rebase check are untouched.
- The orphaned-verdict path fixed by card 96 must keep working; run its smoke.
- Existing queued cards without claims are not rewritten; the refusal is at
  queue time for new cards only.
- Do not raise the pair to a triple.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. `add-stage.sh` refuses a fixture card with no claims and no `serial` line,
   accepts one with `serial`, accepts one with claims.
2. In a fixture repo, after a paired member fails and is re-queued, the next
   eligible pair forms on the following tick without any hand edit.
3. A docs-only tail pairs behind a head claiming `scripts/tick.sh`; a tail
   claiming `scripts/lib/tui/render.py` does not.
4. `scripts/pipeline-pair-smoke.sh` (which also carries card 96's
   no-verdict-left-behind assertions; keep them green) and
   `scripts/state-branch-smoke.sh` are no more red than on clean `dev`; the
   new cases fail against the pre-change scripts.
5. `docs/tick-loop.md` names the accepted risks in the words of deliverable 5.

## Contract test

- **Test file:** scripts/pipeline-pair-smoke.sh
- **Assertions digest:** `sha256:85bce562a4b57974b77d6125ef8179e59a9c29616db3da2212f0bc028be1702b`

The frozen block is **already written**, by the orchestrator, before any
implementation exists. Do not author, extend or edit it: satisfy it by
changing the implementation. It currently fails at the first assertion,
which is correct -- deliverable 1 does not exist yet. Fixtures, helpers and
scaffolding you need may be added outside the markers. If you become
convinced an assertion is wrong, stop and surface it as a blocker rather
than editing it; the verifier recomputes this digest and fails the stage if
the assertions moved.

## Out of scope

- Cross-repo scheduling; it already runs independently.
- A dependency DAG wider than a pair; state has one `current_stage` pointer
  and that is a different card.

## Budget

- **Worker wall-clock:** 90 minutes
- **Verifier wall-clock:** 60 minutes

## Escalation

If removing the latch exposes a state where two verifiers can be alive
for one repo (the 88+87 shape), stop and report rather than add a second
pointer; that is the architectural boundary this card must not cross.

## Verifier handoff

Stage a real double dispatch in the fixture with both agents stubbed to
sleep, and watch two ticks: the pair must form, the head must land first,
and the tail must rebase or park correctly. Then fail the head and confirm
the tail lands by plain ff and the *next* pair still forms. Read the diff of
`pipeline_claims_require_serial` closely: the wrong pass is relaxing it for
the head as well as the tail.

## Family-specific notes

None


## PROPOSED-AMENDMENT (2026-09-06, before first dispatch)

Deliverable 2 and the part of acceptance criterion 2 that rests on it. The
rest of the card stands; deliverables 1, 3, 4 and 5 are not in question, and
deliverable 5's naming of the accepted risks is the right instinct.

### The problem

Deliverable 2 replaces the repo-wide `pairing_disabled_stage` latch with a
per-stage `pairing_failures` counter, and refuses pairing "only for a stage
that has failed while paired twice". Removing the latch is right. The
replacement has three faults, and the first is the one that matters.

**It counts the wrong event.** A stage that fails while paired usually fails
for reasons that have nothing to do with pairing: a verifier FAIL on the
merits, an agent death, a provider refusal. The card increments on bare
failure, so "this stage failed" and "pairing broke this stage" become the
same fact. In this repo that is not hypothetical. On the morning this card
was queued, 104 was on its third attempt, 105 and 106 had each failed once,
and 107's worker was killed mid-write by a provider quota. Under the rule as
written, pairing would switch off for precisely the stages that get retried
most, which is the latch again with a narrower blast radius and a slower
fuse. Nothing in the deliverable asks the counter to record *why* it
incremented, so the resulting refusal cannot be diagnosed from state.

**Nothing resets it.** The latch being replaced cleared when the stage's
re-brief landed. The deliverable is silent on clearing `pairing_failures`,
so a stage re-briefed into a genuinely different implementation carries its
pairing ban for the life of the run. That is a regression in recoverability
against the latch, on the exact axis that caused the 2026-09-01 outage this
card exists to fix.

**Two is a threshold without an evidence base.** The card's own surfacing
concern reports four pairings against 24 refusals in this repo's history.
There is not enough history to say what a pairing-caused failure looks like,
and a counter that trips at two on an undiscriminated signal trips on noise.

### Proposed replacement for deliverable 2

> 2. `scripts/tick.sh`: a member failure drops the *current* pair to serial
>    (unchanged) but does not set `pairing_disabled_stage`. In its place a
>    per-stage `pairing_failures` counter records only failures attributable
>    to pairing — the tail failing to rebase onto the moved head, or a claim
>    collision detected at reap. A verifier FAIL on the merits, an agent
>    death, and a provider refusal each increment nothing, because none of
>    them is evidence about pairing. Each increment records the attributed
>    cause alongside the count, so a later refusal can be explained from
>    state. The counter is cleared when a re-brief lands for that stage, as
>    the latch it replaces was. Pairing is refused for a stage whose
>    attributed count reaches two. Remove the latch and its refresh, or
>    leave them reachable only via a manifest key
>    `pipeline.latch_on_failure: true`.

### Proposed addition to deliverable 4

> A stage that fails while paired for a reason unrelated to pairing — take a
> verifier FAIL — does not increment `pairing_failures`, and the next pair
> including that stage still forms.

### Proposed replacement for acceptance criterion 2

> 2. In a fixture repo, after a paired member fails and is re-queued, the
>    next eligible pair forms on the following tick without any hand edit;
>    and a stage carrying one attributed pairing failure still pairs after
>    its re-brief lands.

### Why this is a proposal and not an edit

Prohibition 1. The operator authorised this amendment in session on
2026-09-06 after being shown the reasoning; the wording above is the
controller's, and the decision to adopt it remains the author's.

## Seat history (2026-09-06)

The Codex subscription closed at 10:31Z and this batch was re-seated onto
Claude alone; when Claude session windows then drained faster than the batch
was sized for, the verifying seat moved to the free local route
(`gpt-oss:120b` via `codex exec --oss`). The Codex window reopened the same
afternoon and the card is back on the seats it was authored with. Nothing
about the work changed across either move.

## Re-brief (2026-09-06)

Attempt 1 was refused before implementation by the Codex worker, correctly,
on two card defects. Both are fixed above and neither was the worker's to
fix.

1. Deliverable 2 required a per-stage `pairing_failures` field, but
   `schemas/state.yaml.json` appeared in neither the Deliverables nor the
   Path claims. Adding the field would have violated scope; omitting it
   would have violated the strict state-schema invariant. The schema is now
   named in both.

2. The card told the worker to author the frozen assertion block and record
   its own digest. That contradicts `docs/dispatch-contract.md:131` -- the
   orchestrator authors the assertions so the test cannot be tautological,
   and `templates/worker-prompt.md:22` forbids the worker to touch them. The
   worker was right to stop. The block is now authored and the real digest
   is recorded.

The second defect is not specific to this card: it is the shipped wording of
the Contract test section, so every card carrying that template asks the
worker to write its own oracle. Card 131 covers it. Stage 124 landed with a
worker-authored contract test for this reason, which is worth knowing when
reading its verdict.

Attempt 1 modified no product deliverables. It cost 822k tokens and its
finding was worth more than that.
