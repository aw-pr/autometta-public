---
name: autometta-warden
description: >-
  Mind an Autometta queue the way the scheduled warden pass does: triage a
  verifier_failed stage, merge a conflict-free awaiting integration, clear a
  provably stale pause or halt, or queue the next gated PLAN.md card. Use
  when the operator asks to "mind the queue", "check on the fleet", "do a
  warden pass", or wants an interactive session to babysit a running
  Autometta loop the way an orchestrator did by hand on 2026-08-24. Loads
  the same mandate manifest and the same closed action list
  scripts/warden.sh uses, so a human-driven session and the scheduled pass
  operate under one contract.
---

# Minding the Autometta queue

This skill is the interactive twin of `scripts/warden.sh`
(`autometta warden`, `docs/phat-controller.md` section (k)). Same mandate,
same closed action list. The difference is who is deciding: the scheduled
pass acts alone inside the list; this skill runs inside a conversation with
the operator, who can authorise going beyond it.

## Load the mandate first

```sh
autometta warden --print-mandate
```

This prints the resolved mandate from `$PHAT_CONTROLLER_HOME/warden-mandate.yaml`
(copied from `templates/warden-mandate.yaml.tpl` on first run if no operator
copy exists). Read the escalation thresholds, the `repos` allow-list (empty
means every enabled subscriber), the reporting voice, and use that voice for
whatever you report back in this session.

## The whole list -- identical to the scheduled pass

1. **Requeue a `verifier_failed` stage after triage.** Read the verifier
   artefact and the preserved WIP (`wip_commit`, card 53). If the FAIL is a
   work defect, append a re-brief under the card's existing headings citing
   the artefact and the `wip_commit` sha (follow the format on cards 43 to
   45), commit that one file with your own identity as author (a
   `git commit` in this session resolves it through `agent-whoami`; stage
   only the card path, never a broad `git add`), then run
   `scripts/requeue-stage.sh <repo> <stage-id>`. If the
   FAIL rests on the card's own wording, append and commit a
   `## PROPOSED-AMENDMENT (...)` block naming the specific problem and your
   proposed replacement text -- **do not requeue**, and say so plainly in
   your summary. Turning a
   proposal into an actual criterion change needs the operator's explicit
   go-ahead in this conversation; do not do it unasked.
2. **Merge a conflict-free `awaiting` integration.** A stage's
   `state.yaml` carries `integration.state: awaiting` when base moved
   between dispatch and PASS. Check cleanliness with
   `git merge-tree --write-tree <base> <run-branch>` before touching
   anything; a conflict is surfaced to the operator, never resolved by you.
   On a clean merge: fast-forward when base is an ancestor, otherwise make
   the clean two-parent merge commit the `awaiting` record calls for. Remove
   the run worktree and branch (`scripts/requeue-stage.sh --worktree-only`),
   run the repo's offline `scripts/*-smoke.sh` checks (never the live
   `sdk-cache-smoke.sh`), and push the exact base refspec per
   `git-push-check` (never push without it).
3. **Clear a pause or halt that is provably stale.** A `paused_until` in the
   past, or a `halted: true` whose `window_started_at` is not today. Prefer
   `autometta tick --reset-halt` for the general case; for a single repo,
   `scripts/budget.sh`'s `budget_pause_active` / `budget_ensure_window` are
   the audited functions that already decide staleness -- do not re-derive
   the rule by hand.
4. **Queue the next `PLAN.md` card** when a repo's queue is empty and the
   plan names an unqueued card whose stated gate (`blocked by N`,
   `gated on N`, `after N`) is satisfied -- check `PLAN.md`'s own `done`
   column first, `state.yaml`'s `completed` status second. If the gate's
   wording is ambiguous, say so and ask rather than guessing.

**Nothing else is in scope for this skill's unattended judgement.** The list
above is fixed at `scripts/warden.sh` and is not extended by this skill or
by the mandate. You may exceed it only with the operator explicitly saying
so in this conversation -- the scheduled pass never can, and this session
should not either without that explicit go-ahead. State when you are about
to step outside the list before doing it.

## Escalate rather than repeat

Track the same rule the scheduled pass tracks: if the same remediation
would be the *third* consecutive attempt against the same stage with no
progress, or a `verifier_failed` stage's `verifier_attempts` is at or above
the mandate's `attempt_cap`, stop and surface it to the operator instead of
trying again. The scheduled pass records this in
`<repo>/state/warden-state.json`; read it before acting if you are not sure
whether a stage has already been through this twice.

The mandate may name either a Claude or Codex triage identity. Preserve that
choice and its auth route; never silently substitute one family for the other.

Before dispatching anything that spends tokens (remediation 1's triage
judgement is the only one that does), use `budget_gate_dispatch`, apply the
mandate's `metered_spend` route policy, and stop if the budget ledger is
missing or unusable. Charge the returned usage to `state/budget.json` as
well as writing the role's cost-log line. If the provider output matches the
mandate's unexpected-payment pattern, escalate and do not apply the returned
triage envelope.

## Report in the mandate's voice

End the session with a short summary in the reporting voice from the
mandate: what was found, what was done or not done, and why. Name every
stage you touched and every one you deliberately left alone.
