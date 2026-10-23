# Stage card 162: the controller is retired

## Metadata

- **Authored:** 2026-10-23
- **Orchestrator:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Worker:** Claude Sonnet 5.5 <claude-sonnet-5-5@local>
- **Verifier:** GPT-6.1 Sol <gpt-6-1-sol@local>
- **Base branch:** dev
- **Run branch:** autometta/162-the-controller-is-retired
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Gate:** stage-completed: 161-the-tick-retries-a-dead-worker-once
- **Dispatch:** serial
- **Pairing rationale:** mostly deletion plus doc edits across many files, which Sonnet handles well; Sol verifies cross-family, alternating from card 161. Last in the run because cards 159 to 161 replace everything it removes.
- **Open decisions:** none

## Surfacing concern

The autonomous phat-controller has cost more than it saved. On 2026-10-23 a promo-flow overnight monitor's controller looped 101 passes and 42.7M tokens on one blocked card; its capped replacement could only append an uncommitted proposal, because the Codex workspace-write seat cannot write git metadata. The fleet LaunchAgent `com.autometta.phat-controller.fleet` had refused every 15 minutes since 2026-10-15 on an expired spend authority (the operator unloaded it on 2026-10-23). The judgement it was built for is either forbidden to it (criteria, contracts) or needs the operator's yes; the mechanical part now lives in the tick (card 161) and its reporting in the escalation folder (cards 159 and 160).

## Objective

No Autometta path dispatches a controller agent. The deterministic verbs operators and the tick still use keep working; the agent pass, its prompt, seed, inbox, outbox, transcripts and LaunchAgent are removed; the docs describe orchestration as "the tick runs, escalations go to the operator's orchestration chat".

## Inputs (read these in your own context)

- `scripts/phat-controller.sh` (the verb table near its end, `pc_pass`, inbox/outbox, transcripts)
- `scripts/install-launchagent-phat-controller.sh`, `scripts/uninstall-launchagent-phat-controller.sh`, `templates/launchagent-phat-controller.plist.tpl`
- `templates/phat-controller-prompt.md`, `templates/phat-controller-seed.md.tpl`, `scripts/render-controller-seed.sh`, `scripts/controller-sdk-experiment.py`
- `templates/phat-controller-mandate.yaml.tpl` and every reader of the mandate (`grep -rn phat-controller-mandate scripts`)
- `scripts/phat-controller-smoke.sh`, `scripts/drain.sh`, `scripts/spawn-worker.sh`
- `docs/tick-loop.md`, `docs/dispatch-contract.md`, `docs/proposals/orchestrator-role-review.md`, `docs/proposals/controller-as-correspondent.md`
- any TUI or dashboard code that reads the inbox, outbox or journal (`grep -rln "phat-controller-inbox\|phat-controller-outbox" .`)

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/phat-controller.sh`: remove the `pass` verb and everything only it uses (prompt rendering, seed checks, transcripts, inbox and outbox verbs, agent identity resolution for passes). Keep `picture`, `preserve`, `rebrief`, `requeue`, `card-append`, `push`, `queue-card`, `escalate` and `journal`, each still behaving as today. `escalate` keeps its card-159 escalation write.
2. Remove `scripts/install-launchagent-phat-controller.sh`, `templates/launchagent-phat-controller.plist.tpl`, `templates/phat-controller-prompt.md`, `templates/phat-controller-seed.md.tpl`, `scripts/render-controller-seed.sh` and `scripts/controller-sdk-experiment.py`. Keep `scripts/uninstall-launchagent-phat-controller.sh` so other machines can clean up, and make it idempotent when nothing is installed.
3. The mandate file stays: the tick reads its quota reserve, curfew and spend-authority fields (`quota_gate_family_dispatch` in `scripts/tick.sh`). Remove only the fields that configured controller passes (cadence, dispatch identity, reporting voice), and make every reader tolerate their absence.
4. TUI and dashboard: remove or replace the messages pane that wrote to the controller inbox; where it showed controller state, show the pending escalation count from `scripts/escalations.sh list` instead.
5. `scripts/phat-controller-smoke.sh`: drop the pass, inbox and transcript cases; keep and pass the verb cases.
6. Docs: `CLAUDE.md` (the operational roles paragraph and the hosted skills list), `docs/tick-loop.md` and `docs/dispatch-contract.md` describe the two-role model (tick plus operator orchestration chat); `docs/proposals/controller-retired.md` records this decision, its evidence (the surfacing concern above) and what replaced each controller duty; the two existing proposals get a one-line "Superseded by" header, otherwise unchanged.
7. `HANDOFF.md`: note that the installed Homebrew build must be refreshed (`scripts/check-installed-build.sh`) and the uninstall script run on any other machine.

## Constraints

- No behaviour change to worker or verifier dispatch, landing, budgets, quota gates or the heartbeat.
- History is not rewritten; removed files are deleted in an ordinary commit.
- `git grep -n "pc_pass\|phat-controller-prompt\|phat-controller-seed"` finds nothing outside `docs/proposals/` and `stage-cards/`.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. **No agent path, verifier:** `git grep -n "pc_pass\|phat-controller-prompt\|phat-controller-seed\|controller-sdk-experiment"` returns matches only under `docs/proposals/` and `stage-cards/`. Base: red (many matches).
2. **Verbs intact, worker and verifier:** `scripts/phat-controller-smoke.sh` exits 0 with its verb cases. Base: green.
3. **No regression, worker and verifier:** `scripts/escalations-smoke.sh`, `scripts/session-start-escalations-smoke.sh`, `scripts/auto-retry-smoke.sh`, `scripts/budget-cap-smoke.sh`, `scripts/quota-pace-smoke.sh`, `scripts/reserve-default-smoke.sh` and `scripts/state-branch-smoke.sh` exit 0. Base: green once cards 159 to 161 have landed.
4. **Uninstall is idempotent, worker and verifier:** running `scripts/uninstall-launchagent-phat-controller.sh` twice with nothing installed exits 0 both times.
5. **Docs, verifier:** the documents in deliverable 6 describe the two-role model and the new proposal maps each former controller duty to its replacement.

## Contract test

- **Test file:** None
- **Assertions digest:** None
- **Oracle proof:** None: criterion 1 is a grep and criteria 2 to 4 reuse existing smokes; card review confirms no frozen block is needed.

## Out of scope

- Renaming the `phat-controller.sh` script, its verbs or the mandate file.
- Reworking the journal format.
- Changing any subscriber repo's own monitors (promo-flow's overnight monitor already makes no controller passes).

## Budget

- **Worker wall-clock:** 60 minutes (kill at 90)
- **Verifier wall-clock:** 30 minutes
- **Spend basis:** autometta role median 1.0M tokens, p95 3.7M (2026-10-23). Plan 6M: wide but shallow edits.

## Dispatch envelope

Write `state/envelopes/162-the-controller-is-retired.json` using `schemas/envelope.json`. List changed and deleted files, the exact smoke commands and their results, and any criterion you could not satisfy with why. If the card itself is wrong, stop with `status: fail` and say so in `notes`. Do not self-verify or land your own branch. The verifier writes `state/verifiers/162-the-controller-is-retired.json`.

## Family-specific notes

None
