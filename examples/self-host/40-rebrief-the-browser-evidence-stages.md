# Stage card 40-rebrief-the-browser-evidence-stages: four emergence-lab stages are terminal because nobody told the verifier how to look

## Metadata

- **Authored:** 2026-08-23
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Claude Opus 5 <claude-opus-5@local>
- **Verifier:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes
- **Pairing rationale:** cross-family, and the worker must reach a second repo
  and its controller state, which the claude route can do and a sandboxed codex
  worker cannot. The verifier's job is to check the re-brief against the
  original verdicts rather than to re-run the stages, which is reading work.

## Objective

Successor to card 36, which is retired. Card 36's premise was wrong and its own
worker proved it; this card carries the finding that survived.

Four `emergence-lab` stages sit terminal with working code committed. Each
failed on a browser-evidence criterion, every time because the verifier could
not obtain a browser, not because the code was wrong. Re-brief them so the
criterion is satisfiable, and requeue them.

## Reported by

`docs/incidents/2026-08-16-emergence-lab-five-broken-stages.md`, written by
card 36's worker on 2026-08-16 with five per-stage verdicts and log citations.
Read it first; it is the input, not background.

Current state in `emergence-lab/state/state.yaml`, read 2026-08-23:

| Stage | Status | Attempts | Committed work |
|---|---|---|---|
| 05-math-formula-rendering | `verifier_failed` | 1 | genuine failure, leave alone |
| 13-reset-all-controls-to-defaults | `stalled` | 2 | `a0ba582` |
| 14-fractal-colour-cycle-pacing | `verifier_failed` | 1 | `6af7104` |
| 15-boids-density-motion-tuning | `verifier_failed` | 1 | `38b5e6d` |
| 16-sandpile-larger-slower | `stalled` | 0 | requeued by card 36, stalled again |

### What has changed since card 36 ran

Card 36's worker declined to re-brief four of the operator's cards on its own
initiative, correctly: on 2026-08-16 there was no answer to "how should a
verifier obtain browser evidence", so a re-brief would have been guesswork
about what evidence a headless seat may substitute.

That gap closed on 2026-08-22. `templates/verifier-prompt.md` now requires any
browser check to run fully headless, launching the verifier's own headless
Chromium against a dev server it starts itself, and forbids attaching to the
operator's Chrome (`7c7f22b`). The instruction whose absence let each verifier
conclude it could not look now exists, which is what makes this card possible
and is the whole reason it is not a repeat of card 36.

One thing to establish rather than assume: a sandboxed codex role aborts at
NSApplication init even headless, which is what `Requires GUI` in
`templates/stage-card.md` exists for. Whether these four cards need it depends
on which family verifies them, and two of them currently name a superseded
identity.

## Inputs (read these in your own context)

- `docs/incidents/2026-08-16-emergence-lab-five-broken-stages.md` - the five
  verdicts and their log citations.
- `../emergence-lab/docs/stages/13-reset-all-controls-to-defaults.md`,
  `14-fractal-colour-cycle-pacing.md`, `15-boids-density-motion-tuning.md`,
  `16-sandpile-larger-slower.md` - the four cards to re-brief.
- `../emergence-lab/docs/stages/05-math-formula-rendering.md` - read it to
  confirm it stays out, do not edit it.
- `../emergence-lab/state/state.yaml` and `state/verifiers/*.json` for those
  stages - the original verdicts, including which criterion failed.
- `templates/verifier-prompt.md` - the headless rule, and the exact wording a
  re-brief should lean on rather than restate.
- `templates/stage-card.md` - `Requires GUI`, and the canonical headings.
- `scripts/requeue-stage.sh` - the only sanctioned requeue path.
- `scripts/agent-whoami` - the source of any identity string.
- `examples/self-host/36-ship-fixes-and-recover-emergence-lab.md` - its Retired
  section records why this card exists.

## Deliverables

- The four `emergence-lab` stage cards, re-briefed in place.
- Four requeues via `scripts/requeue-stage.sh`, not by editing state.
- `docs/incidents/2026-08-16-emergence-lab-five-broken-stages.md` - an
  appended section recording the re-brief and its reasoning.
- A short note in `docs/lessons.md` if the re-brief turns up anything general
  about criteria a verifier cannot satisfy.

## Constraints

- Do not change the code under test. This card re-briefs cards and requeues
  stages; it does not fix fractals, boids, sandpile or controls.
- Do not touch stage 05. It is a genuine failure and card 36's worker was
  right to leave it.
- A re-brief says how the criterion may be satisfied. It must not weaken what
  is being checked: "shows a denser flock with faster motion and no blank
  canvas" stays, and gains a headless method for establishing it.
- Take the headless rule from `templates/verifier-prompt.md` by reference.
  Restating it in four cards creates four copies to drift.
- Any identity you write comes from `scripts/agent-whoami`. Two of these cards
  name `Claude Opus 4.7` and `GPT-5.5`; check each against the helper rather
  than copying from the table or from each other. Do not rewrite the
  authorship history of past attempts.
- Append the re-brief under the existing card, keeping the template headings
  intact, per the `autometta-requeue` skill.
- `emergence-lab` is paused until 22:05 for the card 57 sweep. Requeue the
  stages; do not unpause the repo or dispatch into it.
- British English, no em dashes.

## Acceptance criteria

1. Each of the four cards names a headless method by which its browser
   criterion can be satisfied, by reference to `templates/verifier-prompt.md`,
   and the substance of each original criterion is unchanged. Show the before
   and after of each criterion.
2. `Requires GUI` is resolved for each of the four: either set with a stated
   reason, or explicitly not needed with a stated reason, based on the
   verifying family rather than on a guess.
3. Every identity in the four cards resolves through `scripts/agent-whoami`,
   and no superseded identity remains in a role the next run will use.
4. All four stages are `pending` in `emergence-lab/state/state.yaml` with zero
   attempts and no stale envelope, worktree or run branch, and the requeue was
   performed by `scripts/requeue-stage.sh`.
5. The incident doc carries an appended section recording what was re-briefed
   and why, naming the four commits whose code was already good.
6. `emergence-lab` is still paused until 22:05 and nothing was dispatched into
   it by this stage.

Note what is deliberately absent: whether the four stages subsequently pass is
not an acceptance criterion. That is decided by a later run against code this
card does not touch, and making it a condition here would be the same mistake
card 37's criteria 4 and 5 made.

## Out of scope

- Fixing stage 05.
- Any change to the emergence-lab application code.
- Unpausing `emergence-lab` or altering its budget.
- Consolidating the emergence-lab subscribers, which card 38 surfaced and left
  to the operator.
- Changing `templates/verifier-prompt.md`. Use the rule; do not amend it.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes

## Notes for the worker

- Card 36 is the cautionary tale in the same problem space: it assumed a cause,
  and its worker had to spend the stage disproving the card before it could do
  anything useful. Start from the incident doc's verdicts, which are evidence,
  not from this card's framing.
- Card 36's worker surfaced the re-brief as a human call rather than making it.
  That call has now been made, which is why this card exists; the judgement
  still to be made is per-card, on what evidence a headless seat can produce
  for each specific criterion.
- Stage 16 was requeued once already and stalled again at
  `verifier_attempts: 0`. Find out why before requeuing it a second time; a
  second identical requeue is not a plan.
