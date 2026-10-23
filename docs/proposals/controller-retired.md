# The controller is retired

Decision, 2026-10-23 (card 162). Supersedes
[orchestrator-role-review.md](orchestrator-role-review.md) as to the agent role
and [controller-as-correspondent.md](controller-as-correspondent.md) in full.

## Decision

No Autometta path dispatches a controller agent. The scheduled pass, its
prompt, context seed, inbox, outbox, transcripts and LaunchAgent are removed.
Orchestration is two roles: the tick runs, and escalations go to the operator's
orchestration chat. The deterministic verbs in `scripts/phat-controller.sh`
stay as tools that chat calls; the mandate file stays because the tick reads
its quota reserve, curfew and spend-authority fields.

## Evidence

The autonomous phat-controller cost more than it saved.

- On 2026-10-23 a promo-flow overnight monitor's controller looped 101 passes
  and 42.7M tokens on one blocked card.
- Its capped replacement could only append an uncommitted proposal, because
  the Codex workspace-write seat cannot write git metadata.
- The fleet LaunchAgent `com.autometta.phat-controller.fleet` had refused every
  15 minutes since 2026-10-15 on an expired spend authority. The operator
  unloaded it on 2026-10-23.
- The judgement the agent was built for is either forbidden to it (card
  criteria, frozen contracts: the negative list) or needs the operator's yes.
  What remained was mechanical, and mechanical work belongs in the tick.

## What replaced each duty

| Former controller duty | Now |
|---|---|
| Notice a failed, stalled or halted stage | The tick writes one escalation file per episode to the escalations folder and sends a desktop notification (card 159, `scripts/escalations.sh`) |
| Tell the operator | A SessionStart hook shows pending escalations at the top of a chat, and the TUI escalations panel shows the pending count (card 160, card 162) |
| Decide what an escalation means, and act | The operator's orchestration chat, using `skills/autometta-escalations` and `autometta-oracle`, `autometta-requeue`, `autometta-card-review`, with the operator's yes where a criterion or contract changes |
| Retry a worker that died without an envelope | The tick preserves the attempt and requeues once; a second ending escalates (card 161) |
| Preserve stranded work, re-brief, requeue, resume a passing envelope, merge an awaiting integration, clear a stale pause, queue a card, run the offline smokes, push | The same verbs in `scripts/phat-controller.sh`, called by the chat or an operator; the append-only card guard, the tick lock and `git-push-check` still bind them |
| Propose a card amendment | `propose-amendment`, appended and committed, never applied; only the operator turns it into a criterion |
| Stop at an exhausted spend authority | Unchanged for the tick: `spend_authority` and `window_reserve` in the mandate, read by `quota_gate_family_dispatch`, now edited by hand (nothing renders them), alongside each repo's `budget.json` caps |
| Read operator messages and answer them (inbox, outbox) | The conversation itself; the TUI messages page is removed |
| Keep a transcript of each pass | The decision journal (`state/phat-controller-journal.jsonl`) still records every mutating verb; escalation files carry the evidence links |
| Run on a schedule | Nothing. The tick is the only scheduled process |

## Consequences

- Removed: `pass`, `inbox`, `inbox-reply`, `inbox-refuse`,
  `transcript-for-decision` and `prune-transcripts` verbs, `--print-seed`, the
  `controller-seed` and `install-launchagent-phat-controller` subcommands,
  `render-controller-seed.sh`, `controller-sdk-experiment.py`, the prompt and
  seed templates and the LaunchAgent template.
- Mandate fields that configured passes (cadence, dispatch identity, reporting
  voice, transcript retention) are removed; readers tolerate their absence.
- A machine that still has the LaunchAgent installed runs
  `scripts/uninstall-launchagent-phat-controller.sh` (kept, idempotent), and
  refreshes its Homebrew build with `scripts/install-homebrew-local.sh`
  (`scripts/check-installed-build.sh` reports drift).
- The role could return only with a clear bound on spend per episode and a seat
  able to write git metadata. Neither exists today.
