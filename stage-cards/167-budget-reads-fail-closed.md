# Stage card 167: budget reads fail closed

## Metadata

- **Authored:** 2026-11-15
- **Orchestrator:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Worker:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Verifier:** GPT-6.1 Sol <gpt-6-1-sol@local>
- **Base branch:** dev
- **Run branch:** autometta/167-budget-reads-fail-closed
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Recovery attempts:** 3
- **Recovery attempt:** 1
- **Dispatch:** serial
- **Pairing rationale:** operator asked to maximise Claude spend; cross-family kept by a Codex verifier; serial, so no alternation needed. Opus writes it because the change runs through the tick's error-handling spine (errexit context, every budget write) where a subtle bash 3.2 rule decides the outcome; Sol verifies at high effort against a frozen offline smoke and the tick-sourcing regression set. No Gate: the claims below share files with card 166 (`scripts/requeue-stage.sh`, `scripts/tick.sh`) but read nothing 166 writes, and the serial queue order puts 166 first.
- **Open decisions:** none
- **Cold read:** done 2026-11-15, GPT-6.1 Sol (Codex, read-only sandbox, high effort); see Cold read below for the findings and how each was folded in.

## Surfacing concern

Findings H2, L2 and L3 of `docs/reviews/2026-11-15-dispatch-path.md`, re-verified on `dev` at `8c2675d` on 2026-11-15 (the scripts are unchanged since the review's snapshot `fc2929f`).

- **H2, a corrupt budget disables every cap.** `process_repo` calls `_process_repo_locked "$repo_root" "$manifest_path" || rc=$?` (`scripts/tick.sh:3178`), which suspends errexit for the whole dispatch path. When `state/budget.json` is not valid JSON, `budget_ensure_window`'s `jq` writes an empty temp file, `json_check` fails and is ignored, and `mv` replaces the budget with the empty file (`scripts/budget.sh:577-579`; `budget_write_atomic` at 33-35 is the same). From then on every `jq -r '.halted'` and cap comparison in `budget_check_caps` (`scripts/budget.sh:284-322`) reads an empty string, never `true`, so it returns 0 and `budget_gate_dispatch` allows the dispatch. The reviewer's repro, rerun today from a halted budget (999,999,999 spent against a 1,000 cap) truncated mid-write, prints `budget_check_caps rc=0`, `budget_gate_dispatch: ALLOWED` and `budget.json size after tick-equivalent: 0 bytes`. A missing `budget.json` takes the same path and is recreated empty. Only `state.yaml` has an integrity guard (`scripts/tick.sh:3441-3457`).
- **L2, one subscriber ends the fleet fire.** `main` calls `process_repo` as a plain statement inside the subscriber loop (`scripts/tick.sh:4188`) with errexit live, and `process_repo` returns `_process_repo_locked`'s non-zero code (for example after rejecting a malformed `current_stage`, `scripts/tick.sh:3565-3569`), so the tick exits and every later subscriber is skipped for that fire.
- **L3, a failed render replaces state.yaml.** `state_apply_json` runs `yq -P '.' "$tmp_json" > "$tmp_yaml"` then `mv` with no check (`scripts/tick.sh:901-902`); with errexit suspended (H2) a failed or empty render replaces `state.yaml`. `scripts/requeue-stage.sh:238-239` has the same two lines; there errexit is live, so a failing `yq` already aborts, but an empty successful render still replaces the file.

The frozen smoke reproduces each of these on `dev` (see Oracle proof).

A bash 3.2 rule decides how the fix can be shaped. Measured 2026-11-15 on `/bin/bash` 3.2.57, the only bash on this machine and the one `#!/usr/bin/env bash` resolves to under the LaunchAgent: a function called in a condition context (`f || x`, `f && x`, `if f`, `if ! f`, `while f`) runs with errexit suppressed, and the suppression reaches into every subshell and background job it starts, even one that runs `set -e` itself. `set +e; ( set -e; g ); rc=$?; set -e` restores errexit inside `g` only when the function containing it is itself called plainly. So the review's suggested L2 fix, `process_repo … || log …`, would switch errexit off again inside every repo's fire. The smoke's errexit case catches that.

Deployment is orchestrator work: verify the effective fleet root separately from the Homebrew package; this card changes neither.

## Objective

A tick fire never dispatches against a budget it cannot read and never replaces `budget.json` or `state.yaml` with a failed write: an unreadable `budget.json` (missing, empty, not JSON, or not a JSON object) refuses that repo's dispatch on every fire, is left exactly as found and is named on a `budget-integrity:` line; a failing step inside a repo's fire stops that repo's fire; and neither stops the fleet fire reaching the next subscriber.

## Inputs (read these in your own context)

- `scripts/budget.sh` (`json_check`, `budget_write_atomic`, `budget_check_caps`, `budget_gate_dispatch`, `budget_ensure_window`)
- `scripts/tick.sh` (`state_apply_json` around lines 852-910; `process_repo` around 3159-3200; the first 100 lines of `_process_repo_locked` from 3433; `main` from 4103)
- `scripts/requeue-stage.sh` (the state reset, lines 219-240)
- `scripts/budget-fail-closed-smoke.sh`
- `scripts/escalations-smoke.sh` (lines 213-262: card 159's frozen `process_repo` cases)
- `docs/reviews/2026-11-15-dispatch-path.md` (sections H2, L2 and L3 only)

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. `scripts/budget.sh`: one readability predicate (the file exists, is non-empty and parses as a JSON object). `budget_write_atomic` and `budget_ensure_window` return non-zero, leave `budget.json` untouched and remove their temp file when the budget is unreadable or when the `jq` output fails `json_check`. `budget_check_caps` returns a code other than 0, 1 or 2 for an unreadable budget, so `budget_gate_dispatch`'s existing fail-closed `*)` arm refuses. Each of these refuses by an explicit return, not by relying on errexit: their callers run them in conditions (`if ! budget_gate_dispatch`, `budget_check_caps … || budget_rc=$?`).
2. `scripts/tick.sh`, `_process_repo_locked`: a budget-integrity guard beside the existing state-integrity guard, before `budget_ensure_window`. An unreadable `budget.json` (missing, empty, whitespace, not JSON, or JSON that is not an object) logs one line whose message, after the logger's timestamp, begins `budget-integrity:` and names the full path of that `budget.json`; dispatches nothing; does not modify, move or recreate the file; and returns non-zero.
3. `scripts/tick.sh`, `process_repo`: `_process_repo_locked` runs with errexit live, never inside a condition context. Its return code is captured and returned as today, and the escalations scan, tmux viewer, retention sweep and lock release run after it whatever it returned. A failure inside those post-steps keeps today's behaviour.
4. `scripts/tick.sh`, `main`: a non-zero `process_repo` is logged on a line naming the subscriber's repo path and `rc=<code>`, and the loop goes on to the next subscriber. The call stays out of any condition context so that errexit is live inside `process_repo` (see the bash 3.2 rule in the Surfacing concern).
5. `scripts/tick.sh`, `state_apply_json`: when the `yq -P` render fails or produces an empty file, log it, remove its temp files, return 1 and leave `state.yaml` untouched.
6. `scripts/requeue-stage.sh`: the same guard on its `yq -P` render of the reset state; exit non-zero and leave `state.yaml` untouched.
7. The frozen smoke `scripts/budget-fail-closed-smoke.sh`, committed with this card, passes. Do not edit it.

## Constraints

- A failing step inside `_process_repo_locked` stops that repo's fire: add no new `|| true`, `|| :` or `|| return 0` to an existing call there. The smoke probes this with a background errexit probe and a failing `auto_retry_dead_workers`; criterion 4 checks the diff.
- The integrity guard never repairs, moves, recreates or rewrites `budget.json`; recovery is the operator's, as with the state-integrity guard's "manual recovery required". A missing `budget.json` is refused like an unreadable one and is not created.
- A readable budget behaves exactly as today: caps, halts, pauses, drains, window resets, breach records and the healthy dispatch path (criterion 2's regression set).
- `process_repo` still returns `_process_repo_locked`'s code and still scans escalations and releases the lock on every path (card 159's frozen cases in `scripts/escalations-smoke.sh`).
- `scripts/requeue-stage.sh` keeps a `yq -P` render step for the reset state; the smoke's failure injection keys on it.
- `process_repo` and `_process_repo_locked` stay functions of `scripts/tick.sh` run in the tick's own process (a subshell is fine; a new `bash` process is not), so the smoke's function stubs for agents, displays and quota readers still apply to them.
- Card 114's frozen `scripts/tick-profile-smoke.sh` requires the per-phase profile laps to sum to within 10% of the fire's wall clock. A subshell drops its `profile_mark_ns` updates, so a subshell that contains `profile_lap` calls double-counts them in the parent's next lap unless the parent re-marks the clock after it (measured on the reference, 2026-11-15).
- Only `scripts/budget.sh`, `scripts/tick.sh` and `scripts/requeue-stage.sh` change: no change to the schema or values of `state.yaml` or `budget.json`, to any cap, or to `scripts/heartbeat.sh`, the spawn scripts or `scripts/models.sh` (criterion 4).

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. **Worker and verifier:** `bash scripts/budget-fail-closed-smoke.sh` exits 0. Its frozen cases run through a driver that sources `scripts/tick.sh` in its own bash process, with `spawn-worker.sh`, agents, displays and quota readers stubbed; budget, state writes, `process_repo` and `main` are the real code. (h2) In a fleet of a truncated, an empty, a missing and an array `budget.json` followed by a healthy repo, on each of two fires: no worker is dispatched for the four; each file keeps its bytes, inode and mtime (the missing one is not created); a `budget-integrity:` line names each path; each subscriber's non-zero `rc=` is logged; its lock is released and its escalations scan runs; and a healthy subscriber after them is dispatched. (h2) `budget_write_atomic`, `budget_ensure_window`, `budget_check_caps` and `budget_gate_dispatch`, each called inside a condition, return non-zero on a truncated, empty, whitespace, array, `null` or missing budget, with `budget_check_caps` returning neither 1 nor 2; they change nothing and leave no `budget.json.tmp.*`; a failing `jq` filter, a multi-document `jq` output and a failing window write each leave a readable budget untouched; and a readable budget is still accepted and written. (l2) A subscriber with a malformed `current_stage` does not stop the next subscriber's dispatch, is logged with `rc=1`, releases its lock and is scanned. (errexit) A probe inside `_process_repo_locked` shows errexit live in every healthy repo's fire; a repo whose `auto_retry_dead_workers` fails dispatches nothing, is logged with a non-zero `rc=`, releases its lock and is scanned, and the next subscriber is dispatched. (l3) `state_apply_json` returns 1, leaves `state.yaml` byte-identical and leaves no temp file when `yq -P` fails part-way or renders nothing; `requeue-stage.sh` exits non-zero with `state.yaml` byte-identical in both cases; a normal render still writes. Base: red at the first assertion (`(h2) a worker was dispatched for a-truncated, whose budget.json is unreadable`).
2. **Worker and verifier:** no smoke that exercises the tick, the budget or requeue and exits 0 on the dispatch base exits non-zero on the result. The set is `grep -lE 'tick\.sh"|budget\.sh"|requeue-stage\.sh' scripts/*-smoke.sh` on the result. Run every one on the result; for each that fails, extract the base (`mkdir -p "$TMPDIR/base167" && git archive HEAD | tar -x -C "$TMPDIR/base167"`; the worker does not commit, so `HEAD` is the dispatch base) and run it there: it fails the criterion only if it passes on the base. `scripts/tick-cost-smoke.sh` holds a 6.0 s wall-clock budget and fails under machine load, so rerun it once before counting it. On `8c2675d` these 33 pass: `cap-resolution`, `dash-reaper`, `auto-retry`, `escalations`, `landing-dispatch`, `envelope-migration`, `gate`, `preserve-failed-work`, `landing-rebase`, `quota-pace`, `local-route`, `requeue-reset`, `model-window`, `reserve-schedule`, `budget-cap`, `phat-controller`, `codex-card-quota`, `preserve-stays-inside`, `quota-window`, `idle-tick`, `recovery-policy`, `network-fault`, `pipeline-pair`, `reserve-default`, `run-worktree-state-symlink`, `silence-kill`, `state-branch`, `session-window`, `vendor-staleness`, `refresh`, `stall-kill`, `tick-profile`, `usage-error` (each `scripts/<name>-smoke.sh`); five fail there for reasons outside this card (below). Smokes added by cards that land before this one dispatches join the set by the same rule.
3. **Verifier:** `bash -n` passes on each of `scripts/budget.sh`, `scripts/tick.sh` and `scripts/requeue-stage.sh`, and `shellcheck -S warning` on the three reports nothing beyond the base's two warnings in `scripts/tick.sh` (SC2034 on `unit`, SC2154 on `autometta_vendor_stamp_name`).
4. **Verifier:** `git status --porcelain -- . ':(exclude)state'` lists only `scripts/budget.sh`, `scripts/tick.sh` and `scripts/requeue-stage.sh`, and `git diff -- scripts/tick.sh` adds no `|| true`, `|| :` or `|| return 0` to an existing call inside `_process_repo_locked`.
5. **Verifier:** `scripts/check-contract-test-gate.sh --worktree` passes.

Baseline, unchanged from base and not criteria (measured on `8c2675d`, 2026-11-15): `scripts/dependency-graph-smoke.sh` and `scripts/superseded-status-smoke.sh` fail with `ModuleNotFoundError: No module named 'jsonschema'` (environment); `scripts/outlier-warning-smoke.sh` fails three heartbeat-warning cases; `scripts/retry-after-reap-smoke.sh` is card 163's frozen smoke and fails at its case (a); `scripts/tick-cost-smoke.sh` exceeded its 6.0 s budget (11.7 s and 9.9 s) at load averages of 47 to 105.

## Contract test

- **Test file:** scripts/budget-fail-closed-smoke.sh
- **Assertions digest:** sha256:e2806e4639dd2ba564242bcebf9cb1940be9fb3e45429c33d28af9d9859979dd
- **Oracle proof:** red on `dev` at `8c2675d`: the first fire dispatches a worker for `a-truncated`, so `(h2) a worker was dispatched for a-truncated, whose budget.json is unreadable` fails first. With failures made non-fatal in a scratch copy, every case is red on `dev` for its own reason (h2 dispatch, rewrite and missing diagnostics; every budget function returning 0; l2 next subscriber never reached; the errexit probe and the failing-step dispatch; l3 renders replacing `state.yaml`), except two assertions green by design: `requeue-stage.sh` under a failing `yq -P` (errexit is already live in that script) and `state_apply_json`'s normal render. A throwaway reference in a scratch worktree passed: a readability predicate with explicit guards in the three budget functions, the tick's `budget-integrity:` guard, `set +e; ( set -e; … ); rc=$?; set -e` around `_process_repo_locked` in `process_repo` and around `process_repo` in `main`, and size-checked renders in `state_apply_json` and `requeue-stage.sh`. Against that reference criterion 2's set matched the base exactly (same five reds), after one fix the worker will need too: the per-subscriber subshell in `main` drops `profile_mark_ns`, so card 114's `scripts/tick-profile-smoke.sh` failed its 10% lap-sum check until `main` re-marked the profile clock after each subshell. Seven wrong implementations each fail at a named assertion: `process_repo … || log` in `main`, and `auto_retry_dead_workers … || return 1` without restoring errexit (both at the errexit probe); budget guards on input only (the failing `jq` filter); `budget_check_caps` returning 1 (its return-code check); a JSON-syntax-only predicate (the array budget); a guard that rewrites the file in place (inode and mtime); a render guard without the empty-output check (`state_apply_json` return). The reference and mutants were scratch only; worktrees removed, nothing delivered.

Resume check (2026-11-15, dispatch baseline `3052ba3`): the unchanged oracle was rerun and is red at `(h2) a worker was dispatched for a-truncated, whose budget.json is unreadable`. Its digest still matches. The earlier reference proof and cross-family cold read above are retained; no scope or assertion changed. Cards 169 and 172 are now completed and merged. Serial dispatch keeps this card behind the already queued 173, 174 and 170; the worker and verifier must run the acceptance regressions on their actual dispatch base.

## Cold read

Read by GPT-6.1 Sol (Codex, read-only sandbox), 2026-11-15, against the first draft of the card and smoke. Every item is folded in:

1. "Starts `budget-integrity:`" was ambiguous against the timestamped logger: Deliverable 2 now says the message after the timestamp begins with it; the smoke matches the substring in the log or stderr.
2. Whether the post-steps run "on every path" even when they fail: Deliverable 3 now says they run whatever `_process_repo_locked` returned, and a failure inside them keeps today's behaviour.
3. The draft claimed `{}` reads as uncapped; it mostly reads as a cap hit through `null >= null`. Out of scope reworded.
4. The draft claimed `scripts/phat-controller.sh` would now stop on an unreadable budget; its stale-halt path never reaches `budget_ensure_window` for one. Out of scope reworded.
5. Writers were only tested from unreadable input, so an input-only guard passed: the smoke now injects a failing `jq` filter, a multi-document `jq` output and a failing window write against a readable budget.
6. The object predicate was untested: whitespace, array and `null` budgets added, and an array budget joins the fleet case.
7. `budget_check_caps` returning 1 or 2 passed: now asserted to return neither.
8. The second fire could pass vacuously: it now runs with fresh logs, must reach a new healthy subscriber, and rechecks every file, diagnostic, `rc=` line, lock and scan.
9. Errexit was not proved, since `auto_retry_dead_workers … || return 1` would pass: a background probe inside `_process_repo_locked` now leaves a marker whenever errexit is suspended there, checked in every healthy repo's fire.
10. Logging of the subscriber's `rc=`, the guard's non-zero return, the escalations scan after a failure, `state_apply_json`'s exact return of 1 and its temp-file cleanup were unasserted: each now has an assertion.
11. "Never move or recreate" could not see a same-bytes rewrite: inode and mtime are now compared as well as bytes.
12. The scope and no-new-suppression constraints had no criterion: criterion 4 added. The "offline only" line described the smoke, not the worker, and moved to Family-specific notes.
13. The template's "All files listed here must be created or modified" sits above Deliverable 7, which forbids editing the smoke: kept as in card 165, with Deliverable 7 saying the smoke is committed with this card.

No criterion was found that the Codex workspace-write seat cannot run. Not re-read after folding: the changes add assertions without changing what the card asks for, and each was proved red on `dev`, green on the reference and able to catch a matching mutant (Oracle proof).

## Out of scope

- Validating `budget.json` beyond "parses as a JSON object": an object with wrong or missing counters keeps today's behaviour (with the caps absent, `null >= null` mostly reads as a cap hit). Schema validation is its own change.
- A backup or automatic restore for `budget.json`; the guard refuses and the operator repairs.
- `scripts/requeue-stage.sh`'s closing budget write (`jq … > tmp; mv`), which already aborts on a `jq` failure because errexit is live in that script.
- `scripts/phat-controller.sh`: its stale-halt path reaches `budget_ensure_window` only for a readable, halted budget (`scripts/phat-controller.sh:844-878`); no edit.
- Every other finding in the review: C1, C2 and L5 (card 166), H3 (card 168), H1, H4, the M findings, L1, L4 and L6.
- Reinstalling the Homebrew keg so the live fleet runs this code.

## Budget

- **Worker wall-clock:** 60 minutes (kill at 90)
- **Verifier wall-clock:** 40 minutes
- **Spend basis:** about 2M tokens across both roles, most of it cached, in line with 161 and 164 (1.2-1.7M per role-pair); three scripts touched, plus criterion 2's regression run of 10 to 15 minutes. Preparation: one orchestrator session with a throwaway reference, seven mutant implementations and one Codex cold read (98k tokens).

## Dispatch envelope

Return the standard envelope: status, the output of criterion 1, criterion 2 as one PASS/FAIL line per smoke on the result (and the base result for any that failed), and the list of changed files.

## Family-specific notes

Readiness amendment (2026-11-15, card 174 recovery): `pipeline-pair-smoke.sh` and `envelope-migration-smoke.sh` leave the real DNS preflight active despite mocking agent dispatch. Both fail identically on the base and preserved candidate when DNS is denied. For these two regression commands only, use the isolated answering-resolver setup in `stage-cards/174-quota-unknown-holds-claude.md`, acceptance criterion 2. It changes only their fixture environment, not the smokes or production gate. Also run `scripts/network-fault-smoke.sh` in a fresh controller home without that override so production preflight rejection remains independently covered. No required assertion or regression is omitted, and all existing base-comparison rules still apply. Evidence and the original failure are retained under `state/uat/174-quota-unknown-holds-claude/attempt-1/`; harness proposal `P-20261115-14cc` records the permanent fixture repair.

None. The smoke builds throwaway fleets under `mktemp -d` with a temporary `AUTOMETTA_HOME`, so nothing touches `~/.autometta`, a live subscriber or a real agent. It needs `git`, `jq`, `yq`, `python3` and `shasum`, writes only under `mktemp -d`, and opens no socket, so it runs inside the Codex workspace-write sandbox. Criterion 2's set takes 10 to 15 minutes end to end, `scripts/idle-tick-smoke.sh` alone about three.
