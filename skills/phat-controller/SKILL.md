---
name: phat-controller
description: >-
  Pointer to the autometta-escalations skill. The autonomous phat-controller
  role is being retired; an operator's orchestration chat now works the queue
  through escalations. Use when the operator asks to "mind the queue", "check
  on the fleet" or "do a controller pass".
---

# phat-controller (being retired)

The autonomous queue minder is being retired (card 162). The operator
orchestrates from an interactive chat, and the tick writes anything needing a
decision to the escalations folder instead of waiting for a scheduled agent.

Use the `autometta-escalations` skill:

- List what is pending: `scripts/escalations.sh list`.
- Work each escalation: read it, classify it, decide with the operator, act
  through `autometta-oracle`, `autometta-requeue` or `autometta-card-review`,
  then `ack` it.

Until card 162 removes the controller code, the verbs in
`scripts/phat-controller.sh` (`picture`, `preserve`, `rebrief`, `requeue` and
the rest) still exist and still hold their guards. Call them from an
escalation playbook step, not as a standing role: nothing here authorises a
headless pass to widen its own remit.

A scheduled `autometta phat-controller pass` still renders its operating
context from the seed and the mandate, not from this file. The seed owns the
prohibitions and the mandate owns the thresholds.
