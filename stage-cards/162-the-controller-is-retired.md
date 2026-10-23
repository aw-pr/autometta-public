# Stage card 162: the controller is retired

## Metadata

- **Authored:** 2026-10-23
- **Orchestrator:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Worker:** Claude Sonnet 5.5 <claude-sonnet-5-5@local>
- **Verifier:** GPT-6.1 Sol <gpt-6-1-sol@local>
- **Base branch:** dev
- **Run branch:** autometta/162-the-controller-is-retired
- **Worker effort:** medium
- **Verifier effort:** medium
- **Verifier panel:** false
- **Gate:** stage-completed: 161-the-tick-retries-a-dead-worker-once
- **Dispatch:** serial
- **Pairing rationale:** mostly deletion plus doc edits across many files, which Sonnet handles well; Sol verifies cross-family, alternating from card 161. Last in the run because cards 159 to 161 replace everything it removes.
- **Open decisions:** none
- **Cold read:** Codex (GPT-6.1 Sol, read-only) 2026-10-23. Answered: the retained verbs are now listed in full, `pc_resolve_agent_identity` stays for `pc_card_append`, the CLI command is `controller-seed`, criterion 1's grep excludes `uninstall-`, the proposals edit is carved out of the records constraint, `tui-messages-smoke.sh` is deliverable 10, the skill is deliverable 11, and criterion 4 runs against a fixture `HOME`.
- **Claims closure:** 2026-10-23, `git grep` for every removed file and verb; deliverables 8 and 9 and the record-folder exemption come from it.

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
- `bin/autometta`, `MANUAL.md`, `skills/autometta-setup/SKILL.md`, `docs/phat-controller.md`, `docs/machine-dependencies.md` (each names a removed script, verb or template)
- `scripts/quota-window-smoke.sh` (calls `render-controller-seed.sh`)

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/phat-controller.sh`: remove the `pass`, `inbox`, `inbox-reply`, `inbox-refuse`, `transcript-for-decision` and `prune-transcripts` verbs, the `--print-seed` option, and every function only they use (prompt rendering, seed checks, transcripts, inbox and outbox). Keep every other verb behaving as today: `picture`, `preserve`, `rebrief`, `propose-amendment`, `requeue`, `resume-to-verifier`, `stale-halt`, `merge-awaiting`, `smokes`, `push`, `queue-card`, `escalate`, `journal` and `--print-mandate`, plus the `pc_card_append` function. Keep any helper a retained verb still calls: `pc_resolve_agent_identity` stays, because `pc_card_append` takes its commit author from `PC_AGENT_IDENTITY`. `escalate` keeps its card-159 escalation write.
2. Remove `scripts/install-launchagent-phat-controller.sh`, `templates/launchagent-phat-controller.plist.tpl`, `templates/phat-controller-prompt.md`, `templates/phat-controller-seed.md.tpl`, `scripts/render-controller-seed.sh` and `scripts/controller-sdk-experiment.py`. Keep `scripts/uninstall-launchagent-phat-controller.sh` so other machines can clean up, and make it idempotent when nothing is installed. `render-controller-seed.sh` is also what wrote the mandate's `spend_authority` and `window_reserve` bounds; nothing replaces it (operator decision 2026-10-23): `init-host.sh` already installs the mandate from its template, and the operator edits the fields by hand (deliverable 6 documents them).
3. The mandate file stays: the tick reads its quota reserve, curfew and spend-authority fields (`quota_gate_family_dispatch` in `scripts/tick.sh`). Remove only the fields that configured controller passes (cadence, dispatch identity, reporting voice), and make every reader tolerate their absence.
4. TUI and dashboard: remove or replace the messages pane that wrote to the controller inbox; where it showed controller state, show the pending escalation count from `scripts/escalations.sh list` instead.
5. `scripts/phat-controller-smoke.sh`: drop the pass, inbox and transcript cases; keep and pass the verb cases.
6. Docs: `CLAUDE.md` (the operational roles paragraph and the hosted skills list), `docs/tick-loop.md` and `docs/dispatch-contract.md` describe the two-role model (tick plus operator orchestration chat); `docs/proposals/controller-retired.md` records this decision, its evidence (the surfacing concern above) and what replaced each controller duty; the two existing proposals get a one-line "Superseded by" header, otherwise unchanged.
7. `HANDOFF.md`: note that the installed Homebrew build must be refreshed (`scripts/check-installed-build.sh`) and the uninstall script run on any other machine.
8. `bin/autometta`: remove the `controller-seed` subcommand (which runs `render-controller-seed.sh`), the `install-launchagent-phat-controller` / `install-launchagent-warden` subcommand, the `--print-seed` usage and the removed verbs from the `phat-controller` usage line; keep `uninstall-launchagent-phat-controller`. `templates/phat-controller-mandate.yaml.tpl` stops pointing at `controller-seed` and says the fields are edited by hand. `MANUAL.md` and `skills/autometta-setup/SKILL.md` drop the install step and the removed subcommands. `docs/phat-controller.md` and `docs/machine-dependencies.md` stop naming removed files (`docs/phat-controller.md` may become a short pointer to `docs/proposals/controller-retired.md`).
9. `scripts/quota-window-smoke.sh`: its two `render-controller-seed.sh` cases write the mandate fields directly with `yq` instead, asserting the same tick behaviour; its file list drops the removed scripts.
10. `scripts/tui-messages-smoke.sh`: it exercises the inbox composer and `pc_inbox_scan`, both removed. Delete the cases for removed behaviour; if nothing remains, delete the file.
11. `skills/phat-controller/SKILL.md` (already a pointer after card 160): say the role is retired and point at `autometta-escalations`; `CLAUDE.md`'s hosted-skills line describes it the same way. The directory stays, because `mcp-hub` distributes it by symlink.

## Constraints

- No behaviour change to worker or verifier dispatch, landing, budgets, quota gates or the heartbeat.
- History is not rewritten; removed files are deleted in an ordinary commit.
- `git grep -n "pc_pass\|phat-controller-prompt\|phat-controller-seed"` finds nothing outside `docs/proposals/`, `stage-cards/`, `docs/experiments/`, `docs/runs/` and `memory/`. Those hold dated records (memory is append-only): do not edit `docs/experiments/`, `docs/runs/` or `memory/` at all, and in `docs/proposals/` make only deliverable 6's changes (the new `controller-retired.md` and a one-line header on each of the two existing proposals).

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. **No agent path, verifier:** `git grep -n "pc_pass\|phat-controller-prompt\|phat-controller-seed\|controller-sdk-experiment\|render-controller-seed\|install-launchagent-phat-controller" -- . ':!docs/proposals' ':!stage-cards' ':!docs/experiments' ':!docs/runs' ':!memory'` prints nothing. The `[^n]` in the pattern below keeps the retained `uninstall-launchagent-phat-controller` from matching; the exact command is `git grep -nE "(^|[^n])install-launchagent-phat-controller|controller-seed|pc_pass|phat-controller-prompt|controller-sdk-experiment" -- . ':!docs/proposals' ':!stage-cards' ':!docs/experiments' ':!docs/runs' ':!memory'`. Base: red (matches in `scripts/`, `bin/`, `templates/`, `docs/`, `MANUAL.md`, `skills/`).
2. **Verbs intact, worker and verifier:** `scripts/phat-controller-smoke.sh` exits 0 with its verb cases. Base: green.
3. **No regression, worker and verifier:** `scripts/escalations-smoke.sh`, `scripts/session-start-escalations-smoke.sh`, `scripts/auto-retry-smoke.sh`, `scripts/budget-cap-smoke.sh`, `scripts/quota-pace-smoke.sh`, `scripts/reserve-default-smoke.sh`, `scripts/quota-window-smoke.sh` and `scripts/state-branch-smoke.sh` exit 0; `bash -n bin/autometta` passes. Base: green once cards 159 to 161 have landed (all green on dev 2026-10-23; `state-branch-smoke` after `1cc7742`). `scripts/state-schema-smoke.sh` is red on dev for an environment reason (host python lacks the `yaml` module) and is not a criterion.
4. **Uninstall is idempotent, worker and verifier:** with `HOME` set to an empty temporary directory and a stub `launchctl` that exits non-zero first on `PATH`, running `scripts/uninstall-launchagent-phat-controller.sh` twice exits 0 both times and writes nothing outside that `HOME`. This is fixture evidence; uninstalling from a real host is the operator's step (deliverable 7).
5. **Docs, verifier:** the documents in deliverable 6 describe the two-role model and the new proposal maps each former controller duty to its replacement.
6. **TUI, worker and verifier:** `scripts/tui-messages-smoke.sh` exits 0 if it remains, or is deleted with its removal named in the envelope. Base: green.

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

## Re-brief

**Attempt 1 (2026-10-23), killed, work preserved.** The heartbeat killed the worker as a token outlier (13.5M live tokens, mostly cache reads of a 200K context, against a 0.84M median; kill at 15x). It wrote no envelope. Its work is preserved at `fa61fca36eef79906f5bda76349570e148d13806` on `wip/162-the-controller-is-retired-attempt-1`, and the orchestrator checked it: criterion 1's grep prints nothing, criteria 2, 3, 4 and 6 pass (all ten named smokes green, `bash -n bin/autometta` clean, the uninstall script exits 0 twice against a fixture HOME), and the card-138a digest it re-recorded matches its test.

**One defect.** `docs/dispatch-contract.md` lost about 370 lines unrelated to the controller. These sections exist on dev and are absent from the attempt: "Which token cap binds: host default, repo override, drain", "Budget window auto-reset", "Drain mode: the deliberate overnight run", "Token accounting", "Which autometta runs: root resolution" (with "The rule", "Telling the truth about it", "The dirty-checkout exposure", "Checking the split"), and "Pushing a release to the subscribers" (with "The vendored set", "The stamp" and its code block, "The two commands", "What a refresh refuses").

**Orchestrator authorisation (frozen block).** Deliverable 9 sent the worker into `scripts/quota-window-smoke.sh` without saying its renderer cases sit inside card 138a's frozen block. That was a card defect. The orchestrator authorises attempt 1's edit to that block (the hand-edited mandate replaces the deleted renderer, and a new assertion checks the tick reads the value back) and the re-recorded 138a digest `sha256:bec1c224309a319a6bca1b534c30e595383976561a00c32792c64962cabb6700`. The verifier should check the edit stays this narrow, not reject it for touching a frozen block.

**Attempt 2 is a repair.**

1. Restore attempt 1 in full from the fresh run worktree with a patch, so files attempt 1 deleted are deleted again and this card is not rewound: `git diff d7449bd fa61fca36eef79906f5bda76349570e148d13806 -- . ':!stage-cards/162-the-controller-is-retired.md' | git apply --index` (`d7449bd` is attempt 1's base; checked by the orchestrator to apply cleanly on dev).
2. In `docs/dispatch-contract.md`, restore every section listed above verbatim from dev (`git show d7449bd:docs/dispatch-contract.md`), keeping attempt 1's controller-wording edits elsewhere in the file. Check: `comm -23 <(git show d7449bd:docs/dispatch-contract.md | grep -E '^#{1,4} ' | sort -u) <(grep -E '^#{1,4} ' docs/dispatch-contract.md | sort -u)` prints nothing.
3. Re-run criterion 1's grep and the criterion 3 smokes once, and write the envelope. Change nothing else. Keep the context small: do not re-read files you are not changing.

**Pairing for the repair:** Sonnet 5.5 worker and GPT-6.1 Sol verifier, both at medium effort, cross-family as before. The verifier runs the heading check above, criterion 1, criterion 5 on the docs, and the smokes, and checks that the diff from `fa61fca36eef79906f5bda76349570e148d13806` touches only `docs/dispatch-contract.md`.
