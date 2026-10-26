# phat-controller retired

The autonomous-loop design formerly documented here is now [the tick loop](tick-loop.md). The controller agent that later took the name **phat-controller** has itself been retired: no Autometta path dispatches one.

[`proposals/controller-retired.md`](proposals/controller-retired.md) records the decision, its evidence and what replaced each duty. The deterministic verbs operators and the tick still use live in `scripts/phat-controller.sh`, reached as `autometta phat-controller <verb>`; section (k) of the tick loop doc lists them.
