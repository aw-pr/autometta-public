# phat-controller moved

The autonomous-loop design formerly documented here is now [the tick loop](tick-loop.md). The name **phat-controller** now belongs to the queue-minding role that supervises the loop without replacing it.

The role itself is documented in `skills/phat-controller/SKILL.md` (how to decide, and the formats a decision has to produce) and rendered into a pass from `templates/phat-controller-prompt.md`, `templates/phat-controller-mandate.yaml.tpl` and `templates/phat-controller-seed.md.tpl`. The verbs live in `scripts/phat-controller.sh`, reached as `autometta phat-controller <verb>`; section (k) of the tick loop doc lists them.
