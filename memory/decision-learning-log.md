---
name: decision-learning-log
description: Harness lessons go to memory/proposals.jsonl during runs and are decided once a week by the operator; no probe loop, no agent self-edit.
metadata:
  type: project
---

# Decision: a weekly-reviewed proposals ledger, not a self-improving harness

Agreed with Tony on 2026-11-08 after he raised Google's Harness² (he
called it "M2"). Autometta takes the retrospective half of that idea and
leaves out the rerun half.

**Decision.** Suggested harness changes are recorded as they are noticed,
in `memory/proposals.jsonl` through `scripts/proposals.sh`, by the
orchestration chat on acking an escalation and from verifiers' `HARNESS:`
findings. Nothing acts on them until the weekly review
(`skills/autometta-weekly-review`), where the operator approves or rejects
each clustered cause. Approved items become ordinary cards and run in the
overnight windows at the weekend, where quota is usually left.

**Why no probe step.** Harness² reruns the task under each candidate edit
to measure the edit. Here every harness change is already a card with a
frozen oracle and a cross-family verifier, and the smoke suite is the
regression guard. Paying for reruns on top would duplicate the dispatch
contract's own check. Whether a change helped is read later from the fact
ledger's recurrence lines, not measured up front.

**Why the human composes.** Agents editing their own harness is the thing
the load-bearing beliefs guard against. A proposal is a note, never
authority; `policy` items need the operator's yes quoted in the `approved`
note.

**Why weekly, and why the ledger is in memory/.** Weekly matches the
operator's rhythm (design and approve in the day, run overnight) and keeps
review cost to one bounded chat. The ledger is institutional memory, like
`facts.jsonl`, so it is committed and cross-family, and the tick never
writes it.

**How to apply.** Record a proposal only when the diagnosis implicated the
harness; skip plain implementation or quota episodes. At the review, merge
before recommending. No weekend-specific scheduling switch exists; if
harness cards leak into weekdays, that is itself a `policy` proposal for a
`days:` list on the overnight block. See `docs/learning-log.md`.
Related: [[decision-retro-grade]], [[decision-orchestrator-commits-on-verifier-pass]].
