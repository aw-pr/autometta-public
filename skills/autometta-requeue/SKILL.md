---
name: autometta-requeue
description: >-
  Safely re-queue an Autometta stage for a fresh worker dispatch after a
  verifier FAIL, a killed/dead agent, a card re-brief, or a dirty-tree halt.
  Use whenever a stage must run again and the previous attempt left anything
  behind — worker WIP in the tree, envelopes under state/handoffs/ or
  state/verifiers/, a live agent, or a sticky halt in state/budget.json.
  Symptoms this fixes: "halted (reason already recorded: dirty-working-tree)"
  on every tick, and "worker envelope status=pass, proceeding to verifier
  dispatch" immediately after a re-queue (verifier sent at unfixed code).
---

# Autometta stage re-queue

A tick trusts per-stage state on disk. Re-queuing by hand goes wrong in two
specific ways, both observed on 2026-08-13 (aegis-guardrails stage 01):

1. **Stale worker envelope.** `state/handoffs/<stage>.json` from the previous
   round still says `status=pass`, so the next tick skips dispatching a
   worker and sends the verifier straight at the old code. The verifier fails
   again and the stage lands in `verifier_failed` — terminal until a human
   intervenes. The envelope must be purged along with the verifier artefact,
   both per-stage logs, and any `state/active-agents/` registration.
2. **Uncommitted worker WIP.** Leaving round-N output in the tree "for round
   N+1 to continue from" keeps `git status` dirty, and the tick's
   dirty-tree halt then refuses the very dispatch that would continue it.
   The WIP must become a commit — authored by the worker model that wrote
   it (`wip(<stage-id>): round-N output, pre re-queue`) — and the card
   re-brief must point at that SHA, not at "the working tree".

## Procedure

Run the mechanical script; it enforces both rules fail-closed:

```sh
autometta/scripts/requeue-stage.sh <repo-root> <stage-id>
```

It refuses while the tree is dirty (commit the WIP first, worker-authored),
kills any live agent registered against the stage, purges every per-stage
artefact the tick could misread as progress, resets the stage record to
`pending` (zero attempts, null pids/timestamps/token counters), clears
`current_stage` if it pointed at the stage, and clears the repo's halt.
The next tick then dispatches a fresh worker.

After running it:

- If the card was re-briefed, append the re-brief **under the existing card**
  (keep the canonical template headings intact) and reference the committed
  WIP SHA.
- Do not hand-edit `state/state.yaml` or `state/budget.json` for this — the
  script is the sanctioned path and preserves fields it does not manage.

## Related unhalt-only case

If nothing needs re-queuing and repos are merely halted (e.g. trees were
dirty and have since been cleaned by commits), clear all subscribers at once
with:

```sh
autometta/scripts/tick.sh --reset-halt
```

This is safe: a tick re-halts any repo whose halt condition genuinely still
exists. Before a scheduled window, `ai-schedules/bin/preflight_autometta.sh`
reports halted subscribers, dirty trees, and stale-envelope hazards so these
are caught before the window opens rather than 20 minutes into it.
