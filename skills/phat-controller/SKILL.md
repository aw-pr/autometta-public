---
name: phat-controller
description: >-
  Pointer to the autometta-escalations skill. The autonomous phat-controller
  role is retired; an operator's orchestration chat now works the queue
  through escalations. Use when the operator asks to "mind the queue", "check
  on the fleet" or "do a controller pass".
---

# phat-controller (retired)

The autonomous queue minder is retired (card 162,
`docs/proposals/controller-retired.md`). The operator orchestrates from an
interactive chat, and the tick writes anything needing a decision to the
escalations folder instead of waiting for a scheduled agent. No Autometta path
dispatches a controller agent.

Claude Code and Codex lifecycle hooks deliver new or changed escalations during
active chats. They do not wake an idle session or authorise a recovery action.
Use the `autometta-escalations` skill:

- List what is pending: `scripts/escalations.sh list`.
- Work each escalation: read it, classify it, decide with the operator, act
  through `autometta-oracle`, `autometta-requeue` or `autometta-card-review`,
  then `ack` it.

The verbs in `scripts/phat-controller.sh` (`picture`, `preserve`, `rebrief`,
`requeue` and the rest) remain, with their guards, as tools an escalation
playbook step calls. They are not a standing role: nothing here authorises a
headless pass.
