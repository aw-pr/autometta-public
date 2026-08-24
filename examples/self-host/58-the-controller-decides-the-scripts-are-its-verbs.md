# Stage card 58: the controller decides, the scripts are its verbs

## Metadata

- **Authored:** 2026-08-24
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Claude Opus 5 <claude-opus-5@local>
- **Verifier:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Base branch:** dev
- **Run branch:** autometta/58-the-controller-decides-the-scripts-are-its-verbs
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** true
- **Gate:** after 56. That card frees the name phat-controller from the tick
  loop, and this card gives the name to the role.
- **Pairing rationale:** the deliverable is mostly prose that another agent
  will be seeded with, so the family that will read it writes it, and the
  other family verifies that the boundary holds against fixtures designed
  to tempt it across.

## Objective

Invert card 54. It shipped a queue-minder shaped as a script that
occasionally asks an agent for a verdict: four remediations enumerated in
bash, one narrow judgement dispatched, the script deciding and acting. The
remit wanted is the initiative an orchestrator session actually exercises,
and initiative does not enumerate.

After this card the role is an agent seeded at configure time with a
persona, a mandate and the repo facts it would otherwise rediscover. It
decides. What remains of `scripts/warden.sh` is the set of verbs it calls.

The design is committed at `docs/proposals/orchestrator-role-review.md` and
is the specification for this card. Read it first. Where this card and the
proposal disagree, the proposal is wrong and you should say so in the
handoff envelope rather than picking one.

Card 54's mechanism is kept. This is not a fresh start: the verbs it built
are tested and stay, and its `PROPOSED-AMENDMENT` contract survives intact.
What goes is the decision layer on top.

## Inputs (read these in your own context)

- `docs/proposals/orchestrator-role-review.md`, the specification.
- `examples/self-host/54-a-warden-pass-minds-the-queue.md` and everything it
  landed: `scripts/warden.sh`, `scripts/warden-smoke.sh`,
  `templates/warden-prompt.md`, `templates/warden-mandate.yaml.tpl`,
  `skills/autometta-warden/SKILL.md`, the two LaunchAgent scripts.
- `examples/self-host/56-phat-controller-is-the-minder-not-the-loop.md`, the
  rename this card depends on.
- `scripts/git-push-check` and the push-discipline section of the dev rules,
  for the verdict mapping.
- `CLAUDE.md`, particularly the headless gotchas, which are the kind of repo
  fact the seed exists to carry.

## Deliverables

1. **A context seed template**, rendered when a job is configured rather
   than on first run. It carries, in this order: the persona and mandate,
   the negative list from the proposal verbatim, the spend authority
   answered for at setup, and the repo facts an orchestrator would
   otherwise rediscover (paths, families and their auth modes, branch
   policy, where state lives, the repo's own gotchas). Operator-owned and
   editable after rendering, like the mandate manifest is today.
2. **The setup skill asks for spend authority** when the job is configured,
   and writes the answer into the seed. It is not a committed default: the
   right level varies by run, by hour and by day, and a default would be
   wrong most of the time it was used.
3. **One skill, two callers.** `skills/autometta-warden/` renamed and
   rescoped so a headless pass and an interactive session load the same
   source of truth rather than two descriptions that drift.
4. **The verbs.** `scripts/warden.sh` reduced to callable operations with
   the scan-and-choose-remediation loop removed. Preserving stranded work
   to a wip branch, requeueing, detecting a stale halt, merging an awaiting
   integration and running the smokes all stay and stay tested.
5. **A decision journal.** Each decision recorded as structured data before
   it is acted on, not only as the git commit that follows. This is the
   seam for a second reviewing controller later; it is not that feature.
6. **The stalled path is covered**, the case card 54 missed. A stage whose
   worker exited without a handoff envelope has its work preserved, its
   marker recorded, and is requeued with a re-brief citing the preserved
   commit.

## Constraints

- The negative list in the proposal is the boundary, and it is exhaustive.
  Do not add a sixth prohibition to make a fixture pass; if one is genuinely
  needed, say so in the handoff envelope and leave it out.
- The controller may change what is recorded and where. It may never change
  what was asked for or whether it was met. Every design question about
  scope resolves against that sentence.
- Pushing inherits `git-push-check` rather than adding policy: act on
  `PUSH`, escalate and carry on with other work on `ASK`, stop and report on
  `HOLD`. Never block the queue waiting for an answer nobody is awake to
  give.
- Spend to the configured authority without asking, and halt when it is
  exhausted. There is nobody to escalate to mid-run.
- The seed is prose an agent reads, not a config file it parses. Thresholds
  that belong in a manifest stay in one.

## Acceptance criteria

1. The seed template exists, and configuring a job renders it to an
   operator-owned path. Show the rendered output for a fresh job.
2. The rendered seed contains all five prohibitions from the proposal, and
   the spend authority that was answered for at setup rather than a
   committed default.
3. Running setup with no answer supplied does not silently choose a spend
   authority. Show what it does instead.
4. `scripts/warden.sh` no longer selects a remediation. Show that the verbs
   remain individually callable and that the smoke still exercises them.
5. A stalled stage fixture, worker exited with no envelope, ends with the
   work preserved on a wip branch, the marker recorded, and the stage
   requeued citing the preserved commit.
6. A fixture where the correct action is none ends with none taken.
7. A fixture where the FAIL rests on the card's wording produces a
   `PROPOSED-AMENDMENT` and no edit to any acceptance criterion. Show the
   card unchanged afterwards by diff.
8. A fixture where `git-push-check` returns `ASK` ends with an escalation
   recorded, no push, and the controller continuing to other work rather
   than blocking.
9. Every decision in the fixtures above appears in the decision journal as
   structured data, written before the action it describes.
10. The skill and the seed do not restate each other's contents in a form
    that can drift. Show which one owns each fact.

## Contract test

Replay the evening of 2026-08-24 as a fixture: stage 54 stalled with
`worker_envelope_missing_after_exit`, a run worktree left standing holding
uncommitted work, and a `state` symlink the worker should not have made.
The controller should reach the same disposition the interactive session
reached that night, preserving the work and requeueing it, without editing
a single acceptance criterion.

## Out of scope

- A second reviewing controller. Leave the seam, build nothing.
- Re-pairing a stage away from a spent subscription. It is the right
  instinct and it is a separate card; the judgement involves billing routes
  this card does not touch.
- Any change to the tick loop itself. The controller minds the queue; the
  tick still drives it.

## Budget

- **Worker wall-clock:** 120 minutes
- **Verifier wall-clock:** 60 minutes

## Verifier handoff

Return each fixture outcome with the git and state evidence, the refusal
cases shown refusing, the rendered seed for a fresh job, the diff proving
no acceptance criterion moved, and the decision journal entries in the
order they were written.

## Family-specific notes

None
