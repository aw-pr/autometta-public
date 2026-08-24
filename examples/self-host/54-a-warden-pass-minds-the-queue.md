# Stage card 54: a warden pass minds the queue

## Metadata

- **Authored:** 2026-08-24
- **Orchestrator:** Claude Fable 5 <claude-fable-5@local>
- **Worker:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Verifier:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Base branch:** dev
- **Run branch:** autometta/54-a-warden-pass-minds-the-queue
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Pairing rationale:** this adds an agent role to the control plane,
  the most consequential change a card here can make; Claude designs and
  writes it, Codex verifies at high effort against fixtures where the
  warden must refuse to act.

## Objective

On 2026-08-24 the operator left the queue running unattended. The loop
dispatched and verified correctly, but every stall in between needed a
human-shaped intervention: deciding a verifier FAIL was a card defect
rather than a work defect, writing the re-brief, requeueing, merging
`awaiting` integrations, clearing a mis-parsed pause, feeding the queue
in dependency order, refreshing the installed build at a gap. An
interactive orchestrator session did all of it on a 15-minute check
cadence. That cadence and checklist worked; the framework should own
them.

Add a **warden pass**: a scheduled, bounded orchestrator-role agent
dispatch that triages the queue and performs a small, enumerated set of
remediations. It is cron plus tick, not a daemon; one pass reads state,
makes at most one remediation, writes state, exits.

The operator's mandate, 2026-08-24, is the design brief: given cards
with acceptance criteria, a run should go straight through unattended,
with environment glitches and card glitches cleared by the warden
rather than a human. The human is escalated to for exactly two things:
**repeated failure** (a stage exhausting its attempt cap, or the same
remediation firing twice for one stage without progress) and **metered
spend** (any action that would draw on a paid account beyond the budget
file's caps, or a provider signalling payment where none was expected).
Everything else the warden either fixes from its list or surfaces and
waits.

## What the warden may do (the whole list)

1. **Requeue a `verifier_failed` stage** after triage: read the verifier
   artefact and the preserved WIP (card 53's `wip_commit`), append a
   re-brief to the card citing both, and run `requeue-stage.sh`. If the
   artefact shows the FAIL rests on the card's own wording rather than
   the work, the warden appends a **proposed** amendment to the card
   marked `PROPOSED-AMENDMENT`, requeues nothing, and surfaces it: only
   the operator, or an interactive orchestrator, turns a proposal into a
   criterion change.
2. **Merge an `awaiting` integration** into base when the merge is
   conflict-free, run the repo's offline smokes on the result, push per
   `git-push-check`, and re-render the installed build at a queue gap.
   A conflict is surfaced, never resolved by the warden.
3. **Clear a pause or halt that is provably stale**: the recorded reason
   names a reset time that has passed (card 52's grace rule), or a
   `tick-cap` halt from a previous window. Anything else stands.
4. **Queue the next card** from `stage-cards` `PLAN.md` order when the
   queue is empty and the plan names an unqueued card whose stated gate
   (e.g. card 51's "after 46") is satisfied.

Anything not on this list is out of bounds by construction: the warden's
prompt carries the list, and the verifier's fixtures include situations
where the correct action is none.

## Inputs (read these in your own context)

- This session's evidence: the re-briefs on cards 43, 44, 45, the
  preservation commits, the pause incident (card 52), and the merge
  pattern in `docs/dispatch-contract.md`.
- `scripts/tick.sh`, `scripts/requeue-stage.sh`, `scripts/budget.sh`,
  `scripts/spawn-worker.sh` (the dispatch shape to reuse for the warden
  agent), `templates/worker-prompt.md` and `templates/verifier-prompt.md`
  (the template style the warden prompt joins).
- `templates/launchagent.plist.tpl` and
  `scripts/install-launchagent.sh` — the scheduling surface; the warden
  is a second LaunchAgent interval or a flag on the existing tick,
  worker's choice, argued in the handoff.
- `docs/cost-log.md` — the warden is a costed role; its dispatches land
  in the cost log under role `warden`.

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/warden.sh` — one pass: gather the triage picture
   mechanically (state, budget, verifier artefacts, integration records,
   tick log tail), decide whether any of the four remediations applies,
   and either do the mechanical ones (2, 3, 4 are deterministic given
   the picture) directly or dispatch one bounded agent for the judgement
   one (1), via the existing spawn machinery, families and auth routes.
2. `templates/warden-prompt.md` — the checklist prompt for remediation
   1: triage taxonomy (work defect, card defect, harness artefact,
   provider refusal), the re-brief format used on cards 43 to 45, the
   PROPOSED-AMENDMENT rule, and the hard bound of one remediation per
   pass.
3. Scheduling: the warden runs every 15 minutes when any stage is
   non-terminal and does nothing when the ledger is quiet; wire it per
   the chosen surface with the same AbandonProcessGroup care as the
   tick.
4. Budget: warden agent dispatches respect `state/budget.json` like any
   role, appear in the cost log as role `warden`, and the warden makes
   at most one agent dispatch per pass.
5. `docs/phat-controller.md` and `docs/dispatch-contract.md` — the role
   documented: what it may do (the list above verbatim), what it must
   surface instead of doing.
6. Offline smoke: fixtures for each remediation and for at least three
   refusal cases (conflicted merge, non-stale pause, FAIL needing an
   amendment), with assertions able to fail.

## Constraints

- **The allowed-actions list is closed.** Adding an action is a card,
  not a prompt edit.
- One remediation per pass, hard-coded in `warden.sh`, not delegated to
  the prompt.
- The warden never edits acceptance criteria, never force-pushes, never
  touches the publish branch, never writes into a subscriber repo, and
  never clears a halt whose reason it cannot prove stale.
- Every warden action is a commit or a state write with the warden's
  identity attributed; silent action is prohibited.
- Depends on cards 52 and 53 having landed (the stale-pause rule and
  `wip_commit` are load-bearing inputs). If either has not, halt naming
  the gate.
- Cron plus tick stays the model: no long-lived process, no watch loop.
- British English, no em dashes.

## Acceptance criteria

1. Fixture `verifier_failed` with preserved WIP and a work-defect
   artefact: the warden dispatches one triage agent, the card gains a
   re-brief citing artefact and `wip_commit`, the stage is requeued, and
   the cost log carries the role.
2. Fixture where the artefact blames the criterion wording: the card
   gains a PROPOSED-AMENDMENT block, nothing is requeued, and the
   surfaced report names it.
3. Fixture `awaiting` integration that merges clean: merged, smokes run,
   pushed per `git-push-check`. Fixture with a conflict: surfaced,
   untouched.
4. Fixture stale pause (card 52's replay) cleared; fixture live pause
   left standing.
5. Empty queue with a gated card whose gate is unmet: nothing queued;
   with the gate met: queued.
6. Two passes in a row with two remediations available perform one each,
   in a stated priority order.
8. Escalation fixture: the same remediation applying twice to one stage
   without the stage advancing produces an operator escalation (a loud
   log line and a ticker-visible alert), not a third attempt at the
   remediation.
7. All smokes pass with assertions demonstrated able to fail; `bash -n`
  on every touched shell file.

## Contract test

- **Test file:** None
- **Assertions digest:** None

## Out of scope

- Replacing the interactive orchestrator; the warden handles the
  routine, the human handles the novel.
- Multi-repo wardening beyond what the fleet tick already iterates.
- Any change to worker or verifier semantics.
- Notifications beyond the existing log and ticker surfaces.

## Budget

- **Worker wall-clock:** 120 minutes
- **Verifier wall-clock:** 60 minutes

## Verifier handoff

Return each fixture outcome with the git and state evidence, the refusal
cases shown refusing, the chosen scheduling surface with its rationale,
and the warden's one-pass bound demonstrated.

## Family-specific notes

None
