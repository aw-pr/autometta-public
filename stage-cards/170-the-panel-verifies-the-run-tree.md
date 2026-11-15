# Stage card 170: the panel verifies the run tree

## Metadata

- **Authored:** 2026-11-15
- **Orchestrator:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Worker:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Verifier:** GPT-6.1 Sol <gpt-6-1-sol@local>
- **Base branch:** dev
- **Run branch:** autometta/170-the-panel-verifies-the-run-tree
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Recovery attempts:** 3
- **Recovery attempt:** 1
- **Dispatch:** serial
- **Pairing rationale:** operator asked to maximise Claude spend; cross-family kept by a Codex verifier; serial, so no alternation needed. The change spans the two spawn scripts, the tick's verifier spend recording and two docs, and moves the panel from a synchronous call to a background process, so the worker runs at high effort.
- **Open decisions:** none
- **Cold read:** done 2026-11-15; see Cold read below for the family and findings.

## Surfacing concern

Finding H1 of the 2026-11-15 dispatch-path review (`docs/reviews/2026-11-15-dispatch-path.md`, private tier). A card with `- **Verifier panel:** true` is broken under the tick in five ways:

1. **Wrong tree.** `spawn-verifier.sh` hands the panel `card_path` and `repo_root` only (`exec "$panel_script" "$card_path" "$repo_root"`), so every panellist runs in the main checkout (`cd "$repo_root"`, `codex exec -C "$repo_root"`), which does not carry the worker's diff.
2. **A PASS lands an unexamined diff.** The tick then consumes the synthesis and lands the run worktree, which no panellist looked at.
3. **A FAIL halts the repo.** The panel exits 1 on a FAIL majority and 2 on no quorum. `_process_repo_locked` treats any non-zero spawn exit as "verifier dispatch command failed before an agent started": the stage is marked `stalled` with a dispatch-configuration fault and the whole repo halts. The no-quorum path's own `verifier_panel_no_quorum` status write is overwritten the same way.
4. **It blocks the fleet.** The panel polls synchronously inside the tick, holding the repo lock, for up to the card's verifier budget (default 2700 s); every other subscriber waits for that fire.
5. **Wrong route.** Both families are resolved family-wide (`auth-route.sh claude`, `auth-route.sh codex`), so per-role verifier routes are ignored.

Re-verified on `dev` at `8c2675d` with the frozen smoke below, which drives the real `_process_repo_locked`, `spawn-verifier.sh` and `spawn-verifier-panel.sh` against stub panellists: a per-role-only route halts the repo as a configuration fault; with family routes the tick fire blocks 32 to 33 s behind 30-second panellists, every panellist verifies the main checkout, and a FAIL, no-quorum or tied vote leaves the stage `stalled` with the repo halted (`dispatch-configuration-fault`).

## Objective

A panel-mode verifier dispatched by the tick runs in the background against the stage's run worktree on the per-role verifier routes, the tick fire that starts it returns within seconds, and its verdict reaches the stage only through the synthesised artefact: a PASS majority lands, anything else is a stage FAIL (`verifier_failed`), never a dispatch-configuration halt. (An ordinary FAIL still counts towards the repo's consecutive-failure cap, as a single verifier's FAIL does.)

## Inputs (read these in your own context)

- `scripts/spawn-verifier-panel.sh`
- `scripts/spawn-verifier.sh` (`main` up to the panel branch, `update_verifier_state`, and the tail where the single verifier records its pid and registers)
- `scripts/tick.sh` (`consume_verifier_artefact`; the verifier dispatch block in `_process_repo_locked` that calls `spawn_verifier_for_stage`; `verifier_completion_ready`)
- `scripts/models.sh` (`codex_state_argv_for_repo`)
- `scripts/budget.sh` (`budget_parse_tokens_from_log`, `budget_account_tokens_from_dispatch`)
- `scripts/auth-route.sh` (header: `--role`)
- `docs/verifier-panel.md`
- `schemas/verifier-panel.json`
- `scripts/panel-run-tree-smoke.sh` (the frozen contract test)

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/spawn-verifier.sh`: the panel branch passes the stage's run worktree (`work_dir`) to `spawn-verifier-panel.sh`.
2. `scripts/spawn-verifier-panel.sh`:
   - Accepts the run worktree (for example `--work-dir <dir>`; without it, `repo_root`, which is what `autometta panel` uses). The two SDK panellists `cd` into it; the Codex panellist runs `codex exec -C <work_dir>` and gets the same state write grant the single Codex verifier gets from `codex_state_argv_for_repo` (call the helper; do not copy its result), so it can still write its artefact under the subscriber's `state/`. Artefact paths are unchanged: panellists at `state/verifiers/<id>.panel/{opus,sonnet,codex}.json`, synthesis at `state/verifiers/<id>.json`.
   - Resolves both families with `auth-route.sh <family> --role verifier`.
   - Reads its poll interval from `AUTOMETTA_PANEL_POLL_INTERVAL` (whole seconds, default 10; anything else falls back to 10).
   - Under the tick (not `--read-only`), runs every preflight in the foreground (both auth routes, the `ANTHROPIC_API_KEY` requirement, `op-fetch`, `verify-sdk.py`, the Codex API home), so a genuine configuration fault still exits non-zero before anything is spawned. Then it starts the panel as a background process in its own process group, disowned, records that process as the stage's `verifier_pid` with `verifier_artefact: state/verifiers/<id>.json` (this foreground step is still inside the tick's call, under its lock), registers it in `state/active-agents/` with the run worktree as its working directory, and exits 0 within seconds.
   - The background panel writes only its own files: panellist artefacts and logs, the synthesis artefact and the synthesis log. It never writes `state/state.yaml` or `state/budget.json`; both belong to the tick under its repo lock.
   - The synthesis is `PASS` only with quorum (2 of 3 votes) and a strict PASS majority. A FAIL majority, a missing quorum or a tie is written as `overall: "FAIL"` with the real `quorum` counts, and `additional_findings` starts with the reason: `[Panel synthesis — majority PASS]`, `[Panel synthesis — majority FAIL]`, `[Panel synthesis — no quorum]` or `[Panel synthesis — tie]`. The background panel always writes a synthesis, so the tick always gets a verdict through the ordinary artefact path. The `verifier_panel_no_quorum` status is retired.
   - `--read-only` (`autometta panel`) is unchanged: synchronous, synthesis JSON on stdout, panellist artefacts in a temp dir, exit 0 for PASS, 1 for FAIL and 2 for no quorum or a tie, and no write to `state.yaml`, `budget.json` or the canonical artefact (its panellist logs and registrations are as today).
3. Panel spend is recorded exactly once, as the sum of the three panellists, by the tick under its lock when it consumes the synthesis, in all three places a verifier's spend goes: `budget.json` `tokens_spent`, the stage's `verifier_tokens` snapshot and the cost-log verifier row. For example: the synthesis log (`state/logs/<id>-verifier.log`) carries one `Total tokens: <sum>` line, and for a panel artefact (one with `panellists`) `consume_verifier_artefact` in `scripts/tick.sh` passes no work dir to `budget_account_tokens_from_dispatch`, `stage_snapshot_tokens` and `costlog_emit_verifier`, so all three read that log instead of looking up a transcript. Without that, the Codex panellist's session transcript, now keyed by the run worktree, is matched and charged alone and the two SDK panellists are lost; with the panel still calling `budget_account_tokens_from_log` itself, the background process races the tick on `budget.json`.
4. `docs/verifier-panel.md`: the panellists verify the stage's run worktree; under the tick the panel runs in the background and the tick consumes its synthesis like a single verifier's artefact; no quorum and a tie are recorded as a FAIL synthesis, so the stage stops at `verifier_failed` for the operator; per-role verifier routes apply; `AUTOMETTA_PANEL_POLL_INTERVAL` is documented; the Cost section describes how panel spend is now recorded. Remove every mention of `verifier_panel_no_quorum`. `schemas/verifier-panel.json`: the `overall` description says PASS needs quorum and a strict majority (it says `pass_count >= fail_count` today) and the `quorum` description drops `verifier_panel_no_quorum`.
5. The frozen smoke `scripts/panel-run-tree-smoke.sh` passes. Do not edit it.

## Constraints

- The single-verifier path in `spawn-verifier.sh` is unchanged.
- The tick's verdict handling (`_process_verifier_artefact`, `verifier_completion_ready`, the verifier dispatch block) is unchanged; the tick learns a panel's verdict only from the artefact. The only `scripts/tick.sh` change allowed is how a panel artefact's spend is recorded (Deliverable 3).
- Panel composition, identities, quorum size, effort arguments, sandbox selection (`resolve_panel_codex_sandbox`) and the artefact paths are unchanged.
- If a card that lands ahead of this one changes the verifier artefact contract (for example binding a verdict to its dispatch), the panel's synthesis must meet that contract as the single verifier's artefact does; the frozen smoke drives the real tick, so a mismatch shows there.
- Offline only: the smoke stubs `op-fetch`, `agent-whoami` and `dig` on `PATH` and builds its fixtures under `mktemp -d`; no network, agent or spend.
- The worker makes no commits and runs no git command that changes its own checkout; the smokes' own fixture repos under `mktemp -d` are exempt. The tick commits on PASS.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. **Worker and verifier:** `scripts/panel-run-tree-smoke.sh` exits 0 and prints `PASS: panel-run-tree-smoke` (about 50 s; its stub panellists take 30 s). Its frozen cases, each a fixture subscriber whose stage has a returned worker and a run worktree holding the worker's change, driven through the real `_process_repo_locked`: (A) votes PASS, PASS, FAIL on routes set only by `AUTOMETTA_CLAUDE_MODE_VERIFIER=api` and `AUTOMETTA_CODEX_MODE_VERIFIER=api`; (B) FAIL, FAIL, PASS, (C) PASS plus two crashes and (D) PASS, FAIL and a crash, all three on family routes. For each, the fire that dispatches the panel returns in under 15 s, does not halt the repo, and leaves the stage `in_progress` with `verifier_artefact: state/verifiers/<id>.json` and a live `verifier_pid` that leads its own process group and is registered in `state/active-agents/` with the run worktree as `working_dir`; `state.yaml` and `budget.json` are byte-identical while the panel runs; each panellist is dispatched once into the run worktree, and the Codex one gets an `--add-dir` grant on the subscriber's `state`; in (A) the Claude panellists get `ANTHROPIC_API_KEY` and the Codex one `OPENAI_API_KEY`; the synthesis reads PASS, FAIL, FAIL with quorum 1 of 2 and "no quorum", and FAIL with "tie". The next fire lands (A) with the worker's change on `dev`, leaves (B), (C) and (D) `verifier_failed` with the repo not halted, and logs no dispatch-configuration fault; in (A) and (B) `tokens_spent`, the stage's `verifier_tokens` and the cost-log verifier row all read 3000 (three 1000-token panellists, the Codex one also leaving a transcript keyed by the run worktree). A panel with no Claude API route still fails the spawn in under 15 s with no panellist started and no `verifier_pid`. `spawn-verifier-panel.sh <card> <repo> --read-only` prints a PASS synthesis with exit 0 and a FAIL one with exit 1, and writes neither `state.yaml`, `budget.json` nor the canonical artefact. `docs/verifier-panel.md` mentions the run worktree, the background and `AUTOMETTA_PANEL_POLL_INTERVAL`; neither it nor `schemas/verifier-panel.json` mentions `verifier_panel_no_quorum`, and the schema no longer says `pass_count >= fail_count`. Base: red, first at (A) `dispatching the panel halted the repo (dispatch-configuration-fault)`; the preflight and read-only cases are green on the base.
2. **Worker and verifier:** `scripts/effort-flags-smoke.sh`, `scripts/verifier-route-matrix-smoke.sh` and `scripts/envelope-migration-smoke.sh` each exit 0. Base: all green. `envelope-migration-smoke.sh` passes the tick's network preflight and writes the tick log under the controller home: a sandboxed seat runs it with a `dig` stub first on `PATH` (a script that prints `192.0.2.1`) and `AUTOMETTA_HOME` pointed at a temp dir, and says so in its evidence. The frozen smoke sets up both itself.
3. **Verifier:** `bash -n` passes on `scripts/spawn-verifier-panel.sh`, `scripts/spawn-verifier.sh` and `scripts/tick.sh`, and `shellcheck -S warning` on them reports only the base's warnings (SC1007 in `spawn-verifier-panel.sh`, SC2046 in `spawn-verifier.sh`, SC2034 and SC2154 in `tick.sh`).
4. **Verifier:** by reading `git diff dev`: any `scripts/tick.sh` change is confined to how a panel artefact's spend is recorded; the background panel has no write to `state.yaml` or `budget.json`; the foreground preflight still exits non-zero on a missing API key or Codex API home; the Codex panellist's state grant comes from calling `codex_state_argv_for_repo`, not a copied path; an invalid `AUTOMETTA_PANEL_POLL_INTERVAL` falls back to 10; a panellist that misses the deadline or writes an unreadable artefact counts as no vote.

## Contract test

- **Test file:** scripts/panel-run-tree-smoke.sh
- **Assertions digest:** sha256:46f570fbc0549c5571ed98fc265460fdf9d42edc842fcf8e10b0a0625b61d1d7
- **Oracle proof:** red on `dev` at `8c2675d`, first at scenario (A): `dispatching the panel halted the repo (dispatch-configuration-fault)`. A diagnostic copy that does not stop at the first failure shows every H1 defect on the base: (A) refused on the family-wide route; (B), (C) and (D) block the fire for 32 to 33 s, halt the repo and leave the stage `stalled`; every panellist verified the main checkout; no `--add-dir` grant; no synthesis for (C) or (D); no landing, and every FAIL case logged as a dispatch-configuration fault; the docs and schema still name `verifier_panel_no_quorum`. The preflight and read-only cases pass on the base. A throwaway reference in a detached scratch worktree (a `--work-dir` argument; `--role verifier`; a foreground preflight that re-execs the script as a disowned `set -m` background supervisor, records its pid and artefact with `yq` and registers it; FAIL synthesis with a reason prefix for no quorum and a tie; a summed `Total tokens:` synthesis log; `consume_verifier_artefact` passing no work dir to the three spend recorders for an artefact with `panellists`, through a new optional argument to `costlog_emit_verifier`; doc and schema edits) passed every assertion in about 50 s, with dispatch fires of 2 to 4 s, and left criteria 2 and 3 as on the base. With its `tick.sh` change reverted the budget read 1000 instead of 3000, so the accounting assertions have teeth. It was removed and not committed. Traps for the worker: the panel script is `exec`'d from `spawn-verifier.sh`, so whatever it prints and its exit code are the spawn's; `register-agent.sh` and `yq` must run before the foreground exits; `disown` needs job control (`set -m`) for its own process group; `budget_parse_tokens_from_log` prints nothing for a log with no usage line.

## Out of scope

- A local (Ollama) Codex verifier route for the panel; `auth-route.sh codex --role verifier` printing `local` is treated as today.
- The panel's composition, its model choice and its cost.
- The single verifier, worker dispatch, and every other finding in the review (verdict binding, budget reads, tail rebase, locks and process handling are separate cards).
- Deploying the change. The live fleet tick runs the installed Homebrew keg, not this checkout; reinstalling the keg after this lands is a separate operator step.

## Budget

- **Worker wall-clock:** 60 minutes
- **Verifier wall-clock:** 30 minutes
- **Spend basis:** about twice card 164 (1.2M to 1.5M tokens across both roles): two scripts and a background-process design. Preparation spent: about 45 minutes of orchestrator time and one 89k-token Codex cold read.

## Dispatch envelope

Return the standard envelope: status, the output of the worker's acceptance commands (criteria 1 and 2), the base results recorded above for comparison, and the list of changed files. Name the accounting route you chose for Deliverable 3.

## Family-specific notes

None.

## Cold read

Read by GPT-6.1 Sol (Codex, read-only sandbox), 2026-11-15, against the first draft. Folded in:

1. Fixture commits by the smokes are not worker commits: now exempt in Constraints.
2. `--read-only` writes panellist logs and registrations today: Deliverable 2 now names exactly what it must not write, which the smoke checks.
3. The stage's `verifier_tokens` snapshot and the cost-log row are also transcript-first: Deliverable 3 now covers all three spend records and the smoke asserts each.
4. Criterion 2's `envelope-migration-smoke.sh` needs DNS and a writable controller home in a sandbox: criterion 2 names the `dig` stub and `AUTOMETTA_HOME`; the frozen smoke sets both itself.
5. The schema's `overall` description contradicted strict majority: Deliverable 4 and a smoke assertion.
6. "Never a repo halt" was too broad given the consecutive-failure cap: the Objective now says never a dispatch-configuration halt.
7. Ties, reason prefixes, the supervisor's process group and registration, the foreground preflight, FAIL accounting and the read-only FAIL exit code were unasserted: scenario (D) and assertions for each were added. Deadline expiry, malformed panellist artefacts and an invalid poll interval stay with the verifier's reading (criterion 4); a copied state grant would pass the smoke, so criterion 4 also has the verifier check the helper is called.
8. The docs assertions now also require the background and `AUTOMETTA_PANEL_POLL_INTERVAL`; the Cost section's accuracy is criterion 4 reading.
9. Metadata and section disagreed on the cold read: this section.
