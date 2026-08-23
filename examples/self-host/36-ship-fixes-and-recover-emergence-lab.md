# Stage card 36-ship-fixes-and-recover-emergence-lab: the fixes are committed but not installed, and five stages are still broken

## Metadata

- **Authored:** 2026-08-16
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Claude Opus 5 <claude-opus-5@local>
- **Verifier:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Worker effort:** medium
- **Verifier effort:** medium
- **Verifier panel:** false
- **Pairing rationale:** cross-family. Operator recovery needs a real shell
  and real auth, which rules out a sandboxed seat for the worker; the Codex
  verifier checks outcomes in the subscriber repo rather than a diff.
- **Blocked by:** cards 29 and 30. 30 is fixed and committed; 29 is not started.

## Objective

Subscriber repos dispatch against the installed Homebrew keg, not this
checkout. The keg is at `496c7cc`; `dev` is three commits further on and
carries the card-30 effort-flag fix. Until the keg is re-rendered, every
subscriber still runs the bug.

Then recover `emergence-lab`, where five stages are sitting broken from the two
defects cards 29 and 30 describe.

## Reported by

Repo review on 2026-08-16.

```
$ autometta --version
autometta 496c7cc
$ git rev-parse --short HEAD
ae099a4
```

`/opt/homebrew/opt/autometta -> ../Cellar/autometta/496c7cc`, rebuilt
2026-08-14 17:36 — after the Xcode 27 upgrade that had blocked it, so the
blocker recorded in `HANDOFF.md` is resolved and that note can go. The keg
simply predates the card-30 fix.

`emergence-lab` state, unchanged since the incidents:

| Stage | Status | Verifier attempts |
|---|---|---|
| 05-math-formula-rendering | `verifier_failed` | 1 |
| 13-reset-all-controls-to-defaults | `stalled` | 2 |
| 14-fractal-colour-cycle-pacing | `verifier_failed` | 1 |
| 15-boids-density-motion-tuning | `verifier_failed` | 1 |
| 16-sandpile-larger-slower | `stalled` | 3 |

Both failure modes in cards 29 and 30 produce exactly these two statuses, so
some of these five are victims rather than genuine failures. Which is which is
the first question, not an assumption: a stage that really did fail
verification must not be requeued as though the tooling was at fault.

## Inputs (read these in your own context)

- `~/repos/emergence-lab/state/state.yaml` and `state/logs/` — the five stages'
  logs tell you which failed for tooling reasons and which failed on merit
- scripts/install-homebrew-local.sh — the keg render
- skills/autometta-requeue/ — the safe requeue procedure, including run
  worktrees and envelopes left behind by a prior attempt
- scripts/requeue-stage.sh
- examples/self-host/29-run-worktree-state-writable.md
- examples/self-host/30-effort-flags-ifs-wordsplit.md
- HANDOFF.md — the superseded keg-rebuild note to remove

## Deliverables

1. The keg re-rendered from a `dev` that contains both fixes, verified with
   `autometta --version` matching `git rev-parse --short HEAD`.
2. A per-stage verdict for the five: tooling victim (requeue) or genuine
   failure (leave, or re-brief the card). Five stages, five verdicts, each
   citing its log.
3. The tooling victims requeued through the `autometta-requeue` skill, not by
   hand-editing `state.yaml`. Any stale run worktree, branch, or envelope from
   the prior attempt cleared first — a requeue that leaves a worker envelope
   behind sends the verifier straight at unfixed code.
4. `HANDOFF.md` updated: drop the resolved Xcode blocker, record what shipped.
5. Confirmation that the other subscribers on the keg (`aegis-guardrails`,
   `agentic-rag-kimble`) still dispatch after the re-render.

## Constraints

- Do not requeue anything before both fixes are in the keg. A requeue against
  the old keg reproduces the failure and costs another three attempts.
- Do not hand-edit `state.yaml` in a subscriber repo. `tick.sh` owns it.
- Do not requeue a stage that genuinely failed verification. The retry cap is
  not a way to keep asking until the answer is yes.
- Do not re-render the keg from a dirty tracked worktree; the script refuses,
  and it is right to.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. `autometta --version` matches the `dev` HEAD short SHA.
2. The installed keg contains both fixes — check the installed
   `scripts/models.sh` and `scripts/tick.sh`, not the checkout.
3. Each of the five stages has a recorded verdict with its log cited.
4. Requeued stages reach a worker dispatch that gets past the point the
   original attempt died. Show the log.
5. No stale run worktree, branch or envelope remains from a prior attempt.
6. `HANDOFF.md` no longer carries the resolved Xcode blocker.

## Contract test

- **Test file:** n/a — operator recovery. Evidence is the state of the
  subscriber repo and the installed keg, not a test file.
- **Assertions digest:** n/a

## Out of scope

- Fixing cards 29 or 30 themselves.
- The budget overrun in `emergence-lab-gpu` — cards 31 and 32.
- Any change to `emergence-lab`'s own application code.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes

## Verifier handoff

Worker reports: the keg SHA before and after; the five verdicts with the log
evidence behind each; what was cleared before each requeue; how far the
requeued stages got; and confirmation the other two subscribers still dispatch.

## Family-specific notes

Requeue and keg rendering need a real shell and working auth for whichever
family the requeued stages name. A sandboxed codex worker cannot re-render a
Homebrew keg.

## Retired, 2026-08-23

This card is retired unrun rather than requeued. Its premise does not hold and
its deliverables are landed, superseded, or belong to a successor.

Its own worker established the premise was wrong: none of the five broken
`emergence-lab` stages is a victim of cards 29 or 30, which postdate the
2026-05-26/27 incidents by two and a half months. The statuses matched only
because `verifier_failed` and `stalled` are the only terminal states the loop
has. That finding, with five per-stage verdicts and log citations, is the
card's one durable artefact and is committed at
`docs/incidents/2026-08-16-emergence-lab-five-broken-stages.md` (2e0415f). It
was salvaged from the run worktree, where it was untracked and would have gone
with the first requeue.

Disposition of the rest:

- Keg re-render: superseded. The keg has been re-rendered three times since,
  most recently to 1fe7588, so the version the card names is long gone.
- Five verdicts: landed, as above.
- Requeue of `emergence-lab` stage 16: performed, and it has since stalled
  again at `verifier_attempts: 0`. Unfinished, and it belongs to the successor
  rather than to this card.
- `HANDOFF.md`: written at the time.

The run worktree and `autometta/36-ship-fixes-and-recover-emergence-lab` are
removed. The branch carried no commits: the worker's output was uncommitted
working-tree state, and the only part of it worth having is the incident doc.

What is left undone is not this card's shape. Stages 13, 14 and 15 have
working code committed (`a0ba582`, `6af7104`, `38b5e6d`) and one FAIL each,
every time on the browser-evidence criterion, because the verifier could not
obtain a browser rather than because the code was wrong. Stage 16 carries a
criterion of the same kind. When this card ran on 2026-08-16 that was an open
capability gap and its worker correctly refused to re-brief four of the
operator's cards on its own initiative.

The gap has since closed. `templates/verifier-prompt.md` now requires any
browser check to run fully headless against a dev server the verifier starts
itself (7c7f22b, 2026-08-22), which is the instruction whose absence let each
verifier decide it could not look. A successor card should re-brief those four
stages against that rule, and check whether a codex verifier also needs
`Requires GUI: true` on those cards, since a sandboxed codex role aborts at
NSApplication init even headless.
