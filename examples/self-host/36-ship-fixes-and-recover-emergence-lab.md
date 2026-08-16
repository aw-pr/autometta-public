# Stage card 36-ship-fixes-and-recover-emergence-lab: the fixes are committed but not installed, and five stages are still broken

## Metadata

- **Authored:** 2026-08-16
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** <<worker-identity>>
- **Verifier:** <<verifier-identity>>
- **Worker effort:** medium
- **Verifier effort:** medium
- **Verifier panel:** false
- **Pairing rationale:** <<fill at dispatch — this is operator recovery, so the
  worker needs a real shell and real auth; the verifier checks outcomes in the
  subscriber repo, not a diff>>
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
