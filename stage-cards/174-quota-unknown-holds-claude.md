# Stage card 174: an unknown Claude reading holds Claude dispatch

## Metadata

- **Authored:** 2026-11-15
- **Orchestrator:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Worker:** Claude Sonnet 5.5 <claude-sonnet-5-5@local>
- **Verifier:** GPT-6.1 Sol <gpt-6-1-sol@local>
- **Base branch:** dev
- **Run branch:** autometta/174-quota-unknown-holds-claude
- **Worker effort:** medium
- **Verifier effort:** medium
- **Verifier panel:** false
- **Recovery attempts:** 3
- **Recovery attempt:** 2
- **Dispatch:** serial
- **Pairing rationale:** narrow evidence repair under the recorded recovery policy. Claude Sonnet 5.5 restores the preserved Opus implementation; GPT-6.1 Sol independently reruns every original acceptance criterion. Both roles use medium effort, remain cross-family and dispatch serially. Attempt 1 passed the frozen quota behaviour, syntax and scope; only two offline regression fixtures reached the real resolver.
- **Open decisions:** none
- **Cold read:** done 2026-11-15; see Cold read below for the family and findings.

## Surfacing concern

The vibe-menuapp review of 2026-11-15 (`vibe-menuapp/docs/reviews/2026-11-15-review.md`, findings 2 and 6) found two ways Autometta's Claude reserve lets work through exactly when it cannot see the window:

1. **Unknown fails open.** `scripts/quota-window.py` `read_snapshot` turns a Claude snapshot older than `AI_QUOTA_STALE_SECONDS` (600 s) into `status: unknown, reason: snapshot stale`, and an unparseable one into `snapshot malformed`. `scripts/quota-window.sh` `quota_gate_reading` then returns 0 for every unknown reading ("reading unknown: ..."), and `quota_gate_family_dispatch` in `scripts/tick.sh` logs "dispatch remains fail-open". The exporter can miss its 600 s window after a single failed poll (60 to 120 s gaps at the operator's 60 s poll), so a Claude card can start inside the reserve during that gap.
2. **Over 100 is unknown.** `read_snapshot` calls `sanitise_windows(..., allow_overage=family == "codex")`, so a Claude window reported above 100% rejects the whole snapshot as `snapshot malformed`, which then fails open as in 1: the reading is lost precisely when the window is exhausted. Codex already keeps over-100 figures (card 138, `codex-card-quota-smoke.sh` asserts 105 survives).

Re-verified on `dev` at `8c2675d` with the frozen smoke below: a 700 s old snapshot admits the Claude worker (rc 0), and a fresh snapshot with the 5-hour window at 105 reads `unknown`. The only Claude unknown reasons that exist are `snapshot absent`, `snapshot malformed`, `snapshot stale (...)` (`read_snapshot`) and `reader failed` (`quota_refresh_tick`'s fallback); the smoke exercises each.

**How this interacts with the operator's settings today (read 2026-11-15 16:42 UTC, read-only).**
- Mandate `window_reserve`: `percent: 10`, `action: hold`, `claude_window: 5-hour`, `overnight` 22:00 to 09:00 also at 10% with `stop_outside: false`, pace `observe` for codex only. The Claude reserve is therefore in force day and night.
- Drain (`~/.autometta/drain.json`): token caps lifted until 22:25 GMT (its reason names a one-shot that extends it to 03:00 GMT 2026-11-16), `ignore_reserve: false`. The drain lifts token caps only; it does not bypass the quota-window check. Only an `--ignore-reserve` drain, `percent: 0`, `action: observe` or `off`, `AUTOMETTA_IGNORE_RESERVE=1` on a manual spawn, or a stage's `reserve_exempt` would admit through an unknown reading, and this card keeps all five.
- Live Claude snapshot: fresh (62 s old), 5-hour 18%, Weekly 64%, Weekly (Fable) 43%. The tick logs for 2026-11-01 to 11-15 (16 files, about 3,500 readings) contain no Claude `unknown` reading at all, so no dispatch in that period would have been held. After landing, behaviour changes only while the exporter's snapshot is stale or malformed: Claude dispatch waits a tick or two instead of proceeding. If the exporter stops altogether (app quit, token expired), every Claude dispatch holds until it resumes, with a log line each tick.

**Deployment is separate from packaging.** The orchestrator checks the effective fleet root independently of the Homebrew package. This card changes neither root selection nor host configuration.

**One judgement taken without the operator.** `snapshot absent` keeps admitting. The frozen blocks of cards 124 (`session-window-smoke.sh`), 135 (`reserve-schedule-smoke.sh`) and 138a (`quota-window-smoke.sh`) assert that a Claude `snapshot absent` reading admits, and an absent file means a host with no exporter (a fresh host, a fixture home), not an exporter that has gone quiet. Holding on absent as well would need those three contracts amended, which is an operator decision outside this card.

## Objective

When the Claude reserve is on (`percent` above 0, `action: hold`), a Claude reading that is stale, malformed or unreadable holds Claude dispatch for that tick with a log line naming the reason, instead of admitting it; a Claude window above 100% is a known, exhausted reading that holds and pauses to its reset like any other window inside the reserve; everything else about the gate is unchanged.

## Inputs (read these in your own context)

- `scripts/quota-window.py` (`sanitise_windows`, `read_snapshot`)
- `scripts/quota-window.sh` (`quota_gate_reading`, `quota_spawn_permits`, `quota_spawn_family_reserve_permits`, and the comments above `quota_spawn_permits` and `quota_schedule_permits_dispatch`)
- `scripts/tick.sh` lines 195 to 360 (`quota_log_tick_readings`, `quota_gate_family_dispatch`, `quota_gate_role_dispatch`)
- `docs/tick-loop.md` lines 650 to 790 (the quota reader, the Claude reserve paragraph and the curfew rationale)
- `scripts/quota-unknown-hold-smoke.sh` (the frozen oracle)
- `scripts/quota-window-smoke.sh`, `scripts/session-window-smoke.sh`, `scripts/reserve-schedule-smoke.sh` (frozen blocks that pin `snapshot absent` admitting)

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. `scripts/quota-window.py`: `read_snapshot` keeps a Claude window above 100% as Codex does (overage allowed for both families); the figure is kept, not clamped. Negative, non-finite and non-numeric utilisation stay `snapshot malformed`.
2. `scripts/quota-window.sh`: in `quota_gate_reading`, after the existing `reserve off` check, a reading whose `family` is `claude`, whose status is not `known` and whose reason is anything but `snapshot absent` returns 1 when `action` is `hold`, with `QUOTA_GATE_REASON` beginning `reading unknown: <reason>` and containing `held`, and `QUOTA_GATE_RESET` empty. `observe` and `off` still return 0. Codex readings keep today's behaviour on this path. The manual path (`quota_spawn_permits`) inherits the hold through `quota_spawn_family_reserve_permits`. Update the comments that say every unknown reading fails open (above `quota_spawn_permits`, above `quota_schedule_permits_dispatch`, above `quota_gate_reading`) to the new rule.
3. `scripts/tick.sh`: `quota_gate_family_dispatch` treats a refusal that carries no reset (the unknown hold) as a hold for this tick only: one log line containing the reason (`reading unknown: snapshot stale (...)` and so on) and `held`, never `fail-open`, then return 1 without calling `budget_pause_until`. Known readings inside the reserve still pause to the window's reset exactly as today. `quota_log_tick_readings` no longer says `dispatch remains fail-open` for a Claude unknown other than `snapshot absent`.
4. `docs/tick-loop.md`: the Claude reserve paragraph (the sentence "unknown Claude readings retain the existing fail-open behaviour") states the new rule: stale, malformed or unreadable holds under a hold reserve, only `snapshot absent` admits, reserve off, observe and an `--ignore-reserve` drain still admit, and over-100 counts as exhausted. The curfew rationale ("an unknown reading fails open by design") is brought into line so the two passages do not contradict each other.
5. The frozen smoke `scripts/quota-unknown-hold-smoke.sh` passes. Do not edit it.

## Constraints

- A Claude `snapshot absent` reading still admits (frozen in cards 124, 135 and 138a).
- Codex is unchanged: the default card policy (`codex_admission`, which already holds on unknown) and the legacy `AUTOMETTA_CODEX_QUOTA_POLICY=reserve` path, whose unknown codex reading still fails open (frozen in card 137, `reserve-default-smoke.sh` acceptance 5).
- Unchanged: `quota_reserve_settings`, the drain and its `ignore_reserve` field, the curfew (`quota_schedule_permits_dispatch` logic), pace (`pace_admission` keeps "pace not applied" on an unknown reading; `quota-pace-smoke.sh` asserts it), `reserve_exempt`, `AUTOMETTA_IGNORE_RESERVE` and `AUTOMETTA_RESERVE_GATED`.
- Do not restructure the family routing in `quota_gate_role_dispatch` or `quota_spawn_permits`. Card 148's first attempt failed on exactly that (`scripts/facts-query.sh --predicate failed-criterion`, 148 acceptance 7).
- No change to `AI_QUOTA_STALE_SECONDS` (default 600), the snapshot path, its source, or vibe-menuapp.
- Offline only. Nothing reads or writes the operator's `~/.local/state/ai-quota`, `~/.autometta` (mandate, drain, logs) or any subscriber's `state/`: the smoke points every path at a fixture directory.
- No git commands on the repository or the run worktree: the tick commits on PASS. Smokes that run `git` inside their own `mktemp -d` fixtures are fine.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. **Worker and verifier:** `bash scripts/quota-unknown-hold-smoke.sh` exits 0. Its frozen cases, against a fixture mandate copied from the operator's live `window_reserve`: a fresh 18% snapshot admits the Claude worker with no pause; a 700 s old snapshot holds it (rc 1), records no pause, and its log line names `reading unknown: snapshot stale` and `held` without `fail-open`; the per-tick summary for that reading does not say `fail-open`; a non-exempt Claude verifier is held the same way and a `reserve_exempt` one proceeds; the manual `quota_spawn_permits` refuses with a reason naming `snapshot stale`, and `AUTOMETTA_IGNORE_RESERVE=1` still admits; an unparseable snapshot holds and logs `snapshot malformed` with `held`; a crashing reader (`reader failed`) holds with no pause; a fresh snapshot with the 5-hour window at 105 reads `known`, keeps `105.0`, holds the worker and pauses to the 5-hour reset (`2000008800`) with no `reading unknown` in the log; a codex-only card dispatches while the Claude snapshot is stale and consults no Claude gate; an absent snapshot still admits; `percent: 0`, `action: observe`, `action: off` and an `--ignore-reserve` drain each admit on a stale snapshot, while a drain with `ignore_reserve: false` (today's live shape) still holds; `docs/tick-loop.md` no longer says unknown Claude readings retain fail-open or that an unknown reading fails open by design, and the passage naming `snapshot absent` names stale, malformed and hold; negative and non-numeric utilisation still read `snapshot malformed`, the default staleness limit is still 600 s and the default snapshot directory is unchanged. Base: red at `stale snapshot holds the Claude worker: expected 1, got 0`.
2. **Worker and verifier:** each of these regression smokes exits 0, run from the worktree root with a throwaway controller home and working directory, so none writes to the operator's `~/.autometta` or leaves files in the worktree:

   ```sh
   root="$PWD"
   failed=0
   for s in quota-window session-window reserve-schedule reserve-default model-window \
            codex-card-quota codex-live-quota quota-pace budget-cap pipeline-pair \
            landing-dispatch envelope-migration phat-controller spend-authority-dropped \
            subscription-usage; do
     smoke_home="$(mktemp -d)"
     smoke_path="$PATH"
     case "$s" in
       pipeline-pair|envelope-migration)
         mkdir "$smoke_home/resolver"
         printf '#!/bin/sh\necho 192.0.2.1\n' > "$smoke_home/resolver/dig"
         chmod +x "$smoke_home/resolver/dig"
         smoke_path="$smoke_home/resolver:$PATH"
         ;;
     esac
     if ( cd "$smoke_home" && env -u AUTOMETTA_HOME \
           PHAT_CONTROLLER_HOME="$smoke_home" PATH="$smoke_path" \
           bash "$root/scripts/$s-smoke.sh" ) >"$smoke_home/result.log" 2>&1; then
       echo "PASS $s"
     else
       echo "FAIL $s (evidence: $smoke_home/result.log)"
       cat "$smoke_home/result.log"
       failed=1
     fi
   done
   test "$failed" -eq 0
   ```

   The answering resolver is scoped only to the two offline fixture smokes that mock dispatch but leave the real preflight active. It uses a reserved documentation address, makes no network call and changes neither smoke nor the production preflight. Also run `bash scripts/network-fault-smoke.sh` in its own isolated controller home without this resolver override; it must pass its existing positive and negative production-preflight cases. Every original regression must still exit 0.

   The throwaway home goes in `PHAT_CONTROLLER_HOME`, not `AUTOMETTA_HOME`: `budget-cap-smoke.sh` sets its own `PHAT_CONTROLLER_HOME` fixture and reads its tick log there, which an inherited `AUTOMETTA_HOME` would override (it then fails "tick log records the completed-worker exemption" on the base). Base: all fifteen green this way (about three minutes in total). Not a criterion: `dependency-graph-smoke.sh` is red on the base with `ModuleNotFoundError: No module named 'jsonschema'`, an environment gap unchanged from base.
3. **Verifier:** `bash -n scripts/tick.sh scripts/quota-window.sh` passes; `python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' scripts/quota-window.py` passes; `shellcheck scripts/quota-window.sh` reports nothing beyond the base's four notes (SC1091 twice on the `source` lines, SC2015, SC2034; line numbers may move).
4. **Verifier:** reading the diff, no remaining comment in `scripts/quota-window.sh` or passage in `docs/tick-loop.md` says that every unknown Claude reading fails open, and the diff touches no file outside Deliverables 1 to 4.

## Contract test

- **Test file:** scripts/quota-unknown-hold-smoke.sh
- **Assertions digest:** sha256:5ec45abfa16632764ef037041b9a527d068c1ec2454438401156b3e2fc4f78da
- **Oracle proof:** red on `dev` at `8c2675d`: case 2 fails first with `stale snapshot holds the Claude worker: expected 1, got 0`, the gate admitting a 700 s old snapshot. Green against a throwaway reference in a scratch worktree (deleted after): `read_snapshot` with `allow_overage=True`, a Claude non-absent unknown branch in `quota_gate_reading` under `action: hold`, a no-reset branch in `quota_gate_family_dispatch`, a Claude-specific summary line and two rewritten doc passages, 21 changed lines in all. The fifteen regression smokes of criterion 2 stayed green on that reference, and `dependency-graph-smoke.sh` stayed red for the same missing module. Mutation checks on the reference, each failing at the named case: absent also held (case 9), hold regardless of `observe` (case 10), Claude overage still rejected (case 7), hold without the no-reset branch, so it pauses or logs no `held` (case 2), summary still saying `fail-open` (case 2), the old doc sentences restored (case 11), the negative-utilisation guard dropped (case 12), and `reader failed` exempted from the hold (case 6). Re-proved red at case 2 after the cold-read additions. Trap for the worker: `tick.sh`'s `log` tees to stderr and the smoke reads `$AUTOMETTA_HOME/log/tick-*.log`, so the hold must go through `log`, not `printf`.

## Cold read

Read by GPT-6.1 Sol (Codex, read-only sandbox), 2026-11-15, against the first draft. Every item is folded in:

1. "No git commands" read as forbidding the smokes' own fixture `git`: the constraint now names the repository and run worktree only.
2. `envelope-migration-smoke.sh` sources `tick.sh` with no fixture home, so run with `AUTOMETTA_HOME` unset it logs into the operator's controller home (confirmed: fixture lines from several runs are in the live tick log for 2026-11-15), and `phat-controller-smoke.sh` writes into its working directory. Criterion 2 now runs each smoke with a throwaway controller home (through `PHAT_CONTROLLER_HOME`, see the criterion) and working directory; all fifteen re-baselined green that way on the base and the reference.
3. The unchanged reader guards (negative and non-numeric utilisation), the 600 s default and the default snapshot directory were unasserted: case 12 asserts each.
4. The unknown hold's empty `QUOTA_GATE_RESET`, `action: off`, and the reader-failed budget were unasserted: now asserted in cases 4, 10 and 6. Case 6 now reaches `reader failed` through a real reader crash (an unparseable clock), not a hand-written reading. Every Claude unknown reason that exists is covered (Surfacing concern).
5. The docs check accepted any page naming `snapshot absent`: it now also requires the curfew sentence gone and the passage around `snapshot absent` to name stale, malformed and hold.
6. Metadata said the cold read was done while this section was pending: filled.

The reader found no frozen block of another card that the change breaks, and nothing a Codex workspace-write seat without network cannot run.

## Out of scope

- Holding on `snapshot absent`; it needs the frozen contracts of cards 124, 135 and 138a amended.
- Raising an escalation when Claude dispatch has been held on an unknown reading for a long time.
- The exporter side of findings 2 and 6 in vibe-menuapp (retry cadence, clamping).
- Pace on unknown readings, and the weekly windows the operator's `claude_window: 5-hour` leaves outside the reserve.
- Codex quota behaviour of any kind.
- Reinstalling the Homebrew keg; that is the operator's step after landing.

## Budget

- **Worker wall-clock:** 30 minutes
- **Verifier wall-clock:** 25 minutes
- **Spend basis:** similar to card 148 (one gate branch plus docs), about 0.6M tokens across both roles, most of it the verifier's regression run. Preparation spent on this card: one orchestrator session (about 40 minutes, including the reference and mutation checks) plus one Codex cold read.

## Recovery log

- **Attempt 1:** worker dispatched 2026-11-15T19:14:18Z on `da249c7bd1f059ae0450df3e0ac7c276487a194d`; verifier FAIL at 19:25:47Z. One worker dispatch, 743,421 worker plus 1,011,521 verifier tokens, 1,754,942 total. Work is pinned at `3d6c47d4fd9e9e06ed9b1554e3d5e373b43eda96` on `wip/174-quota-unknown-holds-claude-attempt-1`. Envelope, FAIL artefact, both logs, original card, state row and source patch are preserved at `state/uat/174-quota-unknown-holds-claude/attempt-1/`.
- **Diagnosis:** card/test-environment defect, not an established implementation regression. On both the exact dispatch base and preserved candidate, `pipeline-pair` and `envelope-migration` fail with a resolver stub returning exit 10 and pass with an answering fixture resolver. Every frozen assertion and the quota oracle digest are unchanged. Criterion 2 now supplies that local resolver only to these two fixture tests; the separate `network-fault` smoke still checks production rejection and admission. No production network bypass is added.
- **Next attempt:** 2 of 3, Sonnet worker and Sol verifier at medium effort; plan about 1.5-2M cached-inclusive tokens and 15-25 minutes including the tick cadence. Existing caps, quota, pause and failure gates apply; no halt or failure counter is cleared. A further failure must be diagnosed before the final allowed attempt. No changed success threshold, omitted evidence or widened implementation scope is authorised.

## Repair re-brief (2026-11-15, attempt 2)

Restore the preserved implementation before doing any new design. The orchestrator archived its four-file diff as `state/uat/174-quota-unknown-holds-claude/attempt-1/source.patch`; the dispatch-owned state symlink makes that readable in your new worktree. Run `patch -p1 < state/uat/174-quota-unknown-holds-claude/attempt-1/source.patch`. This edits only the four original deliverables and retains intervening non-overlapping work. If a hunk cannot apply, stop with a partial envelope naming the conflict; do not overwrite current-base changes or alter the oracle. Do not run git mutations.

No new production behaviour is requested. Rerun the frozen quota smoke, the corrected fifteen-smoke loop, the separate network-fault smoke, syntax and ShellCheck, and review the full scoped diff. All original criteria still need independent evidence, even where attempt 1 passed. Do not edit regression smokes or their frozen blocks to make them pass. The verifier reads the archived FAIL and confirms the fixture-only DNS correction before judging the unchanged implementation.

## Dispatch envelope

Return the standard envelope: status, the outputs of criteria 1 to 3, and the list of changed files.

## Family-specific notes

Codex verifier: the frozen smoke writes only under `mktemp -d` and reads fixture quota files, and criterion 2's loop gives every regression smoke a throwaway controller home and working directory, so the workspace-write sandbox with no network is enough. Use the loop as written: with no controller home at all, `envelope-migration-smoke.sh` logs into the operator's `~/.autometta`, and with `AUTOMETTA_HOME` set, `budget-cap-smoke.sh` misses its own log.
