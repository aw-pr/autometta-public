---
name: autometta-requeue
description: >-
  Safely re-queue an Autometta stage for a fresh worker dispatch after a
  verifier FAIL, a killed/dead agent, a card re-brief, or a stale run
  worktree/branch left standing by a prior attempt. Use whenever a stage
  must run again and the previous attempt left anything behind — a run
  worktree/branch, envelopes under state/handoffs/ or state/verifiers/, a
  live agent, or a sticky halt in state/budget.json.
  Symptoms this fixes: "worker envelope status=pass, proceeding to verifier
  dispatch" immediately after a re-queue (verifier sent at unfixed code),
  and `git worktree add` refusing because a run worktree/branch from a
  prior attempt is still standing.
---

# Autometta stage re-queue

A tick trusts per-stage state on disk. Re-queuing by hand goes wrong in two
specific ways:

1. **Stale worker envelope.** `state/handoffs/<stage>.json` from the previous
   round still says `status=pass`, so the next tick skips dispatching a
   worker and sends the verifier straight at the old code. The verifier fails
   again and the stage lands in `verifier_failed` — terminal until a human
   intervenes. The envelope must be purged along with the verifier artefact,
   both per-stage logs, and any `state/active-agents/` registration.
2. **A run worktree/branch left standing.** Under worktree-per-run dispatch
   (backported 2026-08-14; see `memory/adopters/emergence-viewer/
   feedback-worktree-dispatch-thinned-preflight.md`), a FAILed or stalled
   stage leaves its `../<repo>-run-<stage>` worktree and `autometta/<stage>`
   branch standing for inspection. `git worktree add` refuses to cut a fresh
   one over it, so it must be removed (the WIP inside is discarded — it was
   already FAILed or stalled) before re-dispatch.
   (Before that backport, trap 2 was uncommitted worker WIP dirtying
   `repo_root` itself, which the tick's dirty-tree halt refused to dispatch
   over; that no longer applies since dispatch never touches `repo_root`.)

## Procedure

Run the mechanical script; it enforces both rules:

```sh
autometta/scripts/requeue-stage.sh <repo-root> <stage-id>
```

It removes any run worktree/branch left by a prior attempt at this stage,
kills any live agent registered against it, purges every per-stage
artefact the tick could misread as progress, resets the stage record to
`pending` (zero attempts, null pids/timestamps/token counters), clears
`current_stage` if it pointed at the stage, and clears the repo's halt.
The next tick then cuts a fresh worktree and dispatches a fresh worker.

After running it:

- If the card was re-briefed, append the re-brief **under the existing card**
  (keep the canonical template headings intact) and reference the committed
  WIP SHA.
- Do not hand-edit `state/state.yaml` or `state/budget.json` for this — the
  script is the sanctioned path and preserves fields it does not manage.

## Related unhalt-only case

If nothing needs re-queuing and repos are merely halted (e.g. a stale halt
from a prior run window that `budget_ensure_window` hasn't yet cleared),
clear all subscribers at once with:

```sh
autometta/scripts/tick.sh --reset-halt
```

This is safe: a tick re-halts any repo whose halt condition genuinely still
exists. Before a scheduled window, `ai-schedules/bin/preflight_autometta.sh`
reports halted subscribers, stale run worktrees/branches, and
stale-envelope hazards so these are caught before the window opens rather
than 20 minutes into it.
