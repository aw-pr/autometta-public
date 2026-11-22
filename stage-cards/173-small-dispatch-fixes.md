# Stage card 173: small dispatch fixes

## Metadata

- **Authored:** 2026-11-15
- **Orchestrator:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Worker:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Verifier:** GPT-6.1 Sol <gpt-6-1-sol@local>
- **Base branch:** dev
- **Run branch:** autometta/173-small-dispatch-fixes
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Recovery attempts:** 3
- **Recovery attempt:** 1
- **Dispatch:** serial
- **Pairing rationale:** operator asked to maximise Claude spend; cross-family kept by a Codex verifier; serial, so no alternation needed. Six small, separately asserted fixes in the dispatch path, all testable offline with stubs, which Opus at medium effort can carry in one context.
- **Open decisions:** none
- **Cold read:** done 2026-11-15 by GPT-6.1 Sol (Codex, read-only sandbox); every material item is folded in, see Cold read below.

## Surfacing concern

The 2026-11-15 dispatch-path review (`docs/reviews/2026-11-15-dispatch-path.md`, fix list group H) found five small defects, each re-verified on `dev` at `8c2675d` before this card was written, and the operator added a sixth the same day:

- **M6.** `stage_card_for_id` (`scripts/tick.sh`, the fallback block after the manifest loop) falls back to `stage-cards/*<id>*.md`, `docs/stages/*<id>*.md` and `examples/self-host/*<id>*.md`. Stage `12-fix-auth` resolves to `stage-cards/112-fix-auth.md`, so the tick can dispatch another stage's card. `scripts/requeue-stage.sh` has the same substring match when it kills the live agent of the stage it re-queues (`case "$card_path" in *"$stage_id"*`): re-queueing `12-fix-auth` killed `112-fix-auth`'s live worker and deleted its registration in the reproduction.
- **M7.** `costlog_append` (`scripts/cost-log.sh`) resolves the billing route per family, ignoring the per-role keys `scripts/auth-route.sh` honours. With `auth.claude.verifier.mode: api` the verifier row says `subscription`; with `auth.codex.worker.mode: local` the worker row says `api`. The FinOps view then shows metered spend as subscription.
- **L1.** The three spawn scripts substitute card identities and paths into `sed` replacements unescaped (`render_prompt` in `scripts/spawn-worker.sh` and `scripts/spawn-verifier.sh`, the codex prompt in `scripts/spawn-verifier-panel.sh`). Reproduced: a Worker line `Claude Opus 5.5 R&D\lab|w sedwrite <claude-opus-5-5@local>` renders as `R<<worker-tier>>Dlab` and BSD `sed` writes a file named `sedwrite <claude-opus-5-5@local>|g` into the caller's directory; a card path containing `|` fails the render and the spawn exits 1, which the tick treats as a dispatch-configuration fault. Only `family_notes` in `spawn-verifier.sh` is escaped today.
- **L4.** `scripts/auth.sh` builds Python source from `AUTOMETTA_CODEX_HOME` (`status` and `check codex`, the two `python3 -c "...open('$codex_home/auth.json')..."` lines). A quote in the path makes a valid setup report `auth_mode: ?` and FAIL; a crafted path runs as Python.
- **L6.** On the awaiting-integration path the tick runs `git push origin <run-branch>` unconditionally (`scripts/tick.sh`, the `push_note` block in the PASS landing), bypassing the estate's push policy, which `git-push-check` encodes. `scripts/phat-controller.sh`'s `pc_push` already asks it first.
- **Tick identity.** `commit_state_branch` (`scripts/tick.sh`) authors each `autometta: tick state update` snapshot with whatever `agent-whoami` prints with no model asserted, which falls through to the model in `~/.codex/config.toml`. Every such commit in this repo's history is authored by a Codex identity (Codex GPT-5.6 Luna, Terra, GPT-6 Sol, now GPT-6.1 Sol), or by the human when the helper was absent; none carries a loop identity, so "as earlier ones did" is not borne out by history. The repo already names the loop's own identity: `facts_recorder_identity` in `tick.sh` is `phat-controller <phat-controller@local>`, with the comment that the loop is not the model behind any dispatch and that `agent-whoami` "would report whichever family happened to launch the cron", and `PC_GIT_IDENTITY` in `scripts/phat-controller.sh` is the git form, `Phat Controller <phat-controller@local>`. `docs/dispatch-contract.md` (phat-controller verb commits) accepts the role as author where no model did the work. The global rule is explicit that a wrong-but-plausible author is worse than none. Decision taken (recommended answer, reversible): snapshots are authored `Phat Controller <phat-controller@local>`.

Re-verified on `dev` at `8c2675d`: all six. Left out after checking, and asked of the operator instead (see Out of scope): the review's second M6 step, "have add-stage refuse a card that `stage_card_for_id` cannot find", because the frozen blocks of cards 113, 131 and 156 queue fixture cards from outside any card glob and expect `add-stage.sh` to accept them.

## Objective

The tick and its spawn scripts dispatch, re-queue, bill, render, authenticate, push and snapshot exactly what they are told: a stage resolves and kills only its own card and agent, the cost-log names the per-role route, prompts carry identities and paths verbatim, `auth.sh` never executes its environment, the awaiting push happens only on a `git-push-check` PUSH verdict, and state snapshots are authored as the loop.

## Inputs (read these in your own context)

- `docs/reviews/2026-11-15-dispatch-path.md` (sections M6, M7, L1, L4, L6 only)
- `scripts/small-dispatch-fixes-smoke.sh` (the frozen contract test; read it before changing anything)
- `scripts/tick.sh`: `manifest_patterns` and `stage_card_for_id`; `commit_state_branch`; `integration_record` and `record_stage_integration`; the PASS landing block in `_process_verifier_artefact` that builds `push_note`; `facts_recorder_identity`
- `scripts/requeue-stage.sh` (the "Kill any live agent working this stage" loop)
- `scripts/cost-log.sh` (`auth_route_for_family`, `costlog_append`)
- `scripts/auth-route.sh` (header comment and the `--print-mode` / `--role` handling)
- `scripts/spawn-worker.sh` (`render_prompt`), `scripts/spawn-verifier.sh` (`render_prompt`), `scripts/spawn-verifier-panel.sh` (the `codex_prompt` render)
- `scripts/auth.sh` (`status` and `check` for codex)
- `scripts/phat-controller.sh` (`pc_push`, for the existing reading of `git-push-check` verdicts)
- `docs/tick-loop.md` (step 6 of the tick, and section (j) "Landing has three outcomes")
- `docs/cost-log.md` (the `auth_route` row of the field table)

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/tick.sh`, M6: `stage_card_for_id` matches exact basenames only. Remove the three `*${stage_id}*` substring fallbacks; the manifest loop already walks `stage-cards/*.md`, `docs/stages/*.md` and `examples/self-host/*.md` by exact basename, so no exact-name fallback needs adding back. A stage whose card does not exist resolves to the empty string, which every caller already handles (`stage card missing`, `card_missing`).
2. `scripts/requeue-stage.sh`, M6: the live-agent kill loop matches a registration only when the basename of its `card_path`, without `.md`, equals the stage id. Nothing else in the loop changes.
3. `scripts/cost-log.sh`, M7: `costlog_append` records the route `scripts/auth-route.sh` resolves for this family and role (`REPO_ROOT=<repo> auth-route.sh <family> --print-mode --role <role>`, or an equivalent that follows the same five-step order including the per-role env var `AUTOMETTA_<FAMILY>_MODE_<ROLE>`). Keep the recorded value one of `subscription`, `api`, `local`, with `subscription` when resolution fails. Remove `auth_route_for_family` if nothing else calls it, and correct the comment that claims it uses "the same resolution order as auth-route.sh".
4. `scripts/spawn-worker.sh`, `scripts/spawn-verifier.sh`, `scripts/spawn-verifier-panel.sh`, L1: every value substituted into a `sed` replacement (identities, card path, artefact path, project name, stage id, family notes) is escaped for `\`, `&` and the `|` delimiter first, reusing the escaping `spawn-verifier.sh` already applies to `family_notes` (a small shared helper is welcome), or the rendering moves off `sed` altogether. The rendered templates are otherwise byte-identical for ordinary values.
5. `scripts/auth.sh`, L4: both reads of the sibling `CODEX_HOME`'s `auth_mode` stop interpolating the path into source code: use `jq -r '.auth_mode // "?"' "$codex_home/auth.json"` as `spawn-verifier.sh` does, or pass the path to Python in `argv`. Messages and exit codes are unchanged.
6. `scripts/tick.sh`, L6: a new function `push_awaiting_run_branch <repo_root> <run_branch>`, the only place in `tick.sh` that runs `git push`:
   - with `git-push-check` not on `PATH`: no push, prints `held: ` followed by a reason naming `git-push-check`, returns non-zero;
   - otherwise runs `git-push-check origin <run_branch>` with the repo root as its working directory and reads the verdict from the first tab-separated field of its last output line, as `pc_push` does;
   - verdict `PUSH`: runs `git push origin <run_branch>`; on success prints `pushed` and returns 0, on failure prints `held: ` and a reason and returns non-zero;
   - any other verdict (`ASK`, `HOLD`, `NOOP`, empty or unrecognised): no push, prints `held: ` followed by the verdict line, returns non-zero.
   The awaiting branch of the PASS landing calls it in place of the inline push: `integration.pushed` is `true` only when it returned 0, and the tick log line says `push held` with the reason otherwise (replacing "push to origin also failed").
7. `scripts/tick.sh`, tick identity: `commit_state_branch` authors every snapshot as `Phat Controller <phat-controller@local>` and no longer calls `agent-whoami`. The committer stays whatever git is configured with; the subject stays `autometta: tick state update`. Update the comment above it to say why (the loop, not a model, writes the snapshot; `agent-whoami` names whichever family's config it falls through to).
8. `docs/tick-loop.md`: step 6 says the snapshot is authored as `Phat Controller <phat-controller@local>`, not "using the per-agent author attribution from the global dev rules"; the awaiting paragraph in section (j) says the run branch is pushed only on a `git-push-check` PUSH verdict and that `pushed: false` with a `push held` log line records any other verdict or a missing helper.
9. `docs/cost-log.md`: the `auth_route` row says the route is resolved per role, the same way the dispatch resolves it (per-role env override, family env override, per-role manifest key, family manifest key, subscription).
10. The frozen smoke `scripts/small-dispatch-fixes-smoke.sh` passes. Do not edit it.

## Constraints

- Do not edit the frozen block of `scripts/small-dispatch-fixes-smoke.sh` or of any other smoke.
- Do not run git commands that change the repository (no add, commit, stash, checkout, branch, push). The tick commits on PASS. The smoke creates its own throwaway repos under `mktemp -d`; that is the only git it needs.
- `scripts/add-stage.sh` is unchanged (see Out of scope).
- `manifest_patterns` is unchanged, including its `// empty` yq expression (see Out of scope).
- `pc_push` and every other `scripts/phat-controller.sh` verb are unchanged.
- `facts_recorder_identity` is unchanged.
- `scripts/auth-route.sh` is unchanged; `cost-log.sh` consumes it, it does not grow a second resolver.
- The template files under `templates/` are unchanged.
- The live fleet tick runs the installed Homebrew keg, not this checkout. Landing this card changes nothing in production until the operator reinstalls the keg (`scripts/install-homebrew-local.sh`), which is a separate operator step after landing and not a deliverable here.
- Behaviour today that must not change: every pending or failed stage across the fleet resolves its card by exact basename already (checked 2026-11-15: every live stage id either has an exact `<id>.md` card or has no card at all, which the substring fallback could not find either), so removing the fallback strands nothing. The LaunchAgent `PATH` includes `~/.local/bin`, where `git-push-check` lives, so a private run branch still pushes on its PUSH verdict; a run branch whose `origin` is a public GitHub remote, or which a pipeline watches, is now held for a human instead of pushed.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. **Worker and verifier:** `scripts/small-dispatch-fixes-smoke.sh` exits 0 and prints `small-dispatch-fixes-smoke: PASS`. Its six frozen groups, one per fix:
   - **M6:** under each of `stage-cards/`, `docs/stages/` and `examples/self-host/`, stage `12-fix-auth` resolves to nothing when only `112-fix-auth.md` and `12-fix-auth-v2.md` exist, then to its own `12-fix-auth.md` once that exists, and `112-fix-auth` still resolves its own card; `requeue-stage.sh --keep-budget <repo> 12-fix-auth` kills and unregisters the live agent registered for `12-fix-auth.md` and leaves the live agent and registration for `112-fix-auth.md` alone.
   - **M7:** with no manifest a Claude verifier row records `subscription`; with `auth.claude.verifier.mode: api` and `auth.codex.worker.mode: local` the Claude verifier row records `api` and the codex worker row `local`, roles without a per-role key fall back to the family mode, `AUTOMETTA_CLAUDE_MODE_WORKER=api` beats `AUTOMETTA_CLAUDE_MODE=subscription` on the Claude worker row, and `AUTOMETTA_CLAUDE_MODE=subscription` beats the per-role manifest key `api` on the Claude verifier row.
   - **L1:** dispatching through a stub `op-fetch`, the worker prompt carries the Worker identity `Claude Opus 5.5 R&D\lab|w sedwrite <claude-opus-5-5@local>` verbatim and the verifier prompt carries the Verifier identity verbatim; with the repository at a directory named `repo R&D|x\y`, the card path reaches the worker, verifier and panel codex prompts exactly, the worker prompt's `- Project:` line and its family notes carry the name and path exactly, and the panel's codex prompt carries the codex identity `GPT-6.1 Sol R&D|x <gpt-6-1-sol@local>` from a stub `agent-whoami` exactly; and no dispatch writes any file into the caller's working directory.
   - **L4:** with `AUTOMETTA_CODEX_HOME` holding a quote, `auth.sh status` reports `(auth_mode: apikey)` and `auth.sh check codex` prints PASS and exits 0; a path crafted as Python creates no file; a `chatgpt` sibling is still refused naming `auth_mode=chatgpt`, with a non-zero exit.
   - **L6:** `push_awaiting_run_branch` is defined and referenced elsewhere in `tick.sh`, and no other line of `tick.sh` runs `git push` in command position; against a local bare `origin`, verdicts `ASK`, `HOLD`, `NOOP`, an empty verdict, an unrecognised one, a `PUSH` line followed by an `ASK` last line, and a missing `git-push-check` each print `held:`, return non-zero and leave `origin` without the run branch, the missing case naming `git-push-check`; a `PUSH` verdict whose push fails prints `held:` and returns non-zero; a `PUSH` last line after a note line prints `pushed`, returns 0, puts the run branch on `origin` at its tip, and `git-push-check` was asked exactly `origin autometta/07-awaiting` from the repo root.
   - **Tick identity:** with a stub `agent-whoami` and `AGENT_WHOAMI` both naming `GPT-6.1 Sol <gpt-6-1-sol@local>`, `commit_state_branch` writes a snapshot authored `Phat Controller <phat-controller@local>`, committed by the fixture's configured identity, with subject `autometta: tick state update`, and never runs `agent-whoami`.

   Base: red in all six groups, each at its first assertion: M6 `stage 12-fix-auth resolved to another stage's card under stage-cards`; M7 `auth.claude.verifier.mode api recorded as 'subscription' on the verifier row`; L1 `the worker prompt does not carry the card's Worker identity verbatim`; L4 `auth status cannot read auth_mode from a CODEX_HOME whose path holds a quote`; L6 `tick.sh defines no push_awaiting_run_branch`; identity `authored as 'GPT-6.1 Sol <gpt-6-1-sol@local>'`.
2. **Worker and verifier:** each of these regression smokes exits 0: `scripts/landing-dispatch-smoke.sh`, `scripts/landing-rebase-smoke.sh`, `scripts/requeue-reset-smoke.sh`, `scripts/auto-retry-smoke.sh`, `scripts/preserve-failed-work-smoke.sh`, `scripts/cost-log-smoke.sh`, `scripts/effort-flags-smoke.sh`, `scripts/local-route-smoke.sh`, `scripts/log-streams-smoke.sh`, `scripts/mcp-isolation-smoke.sh`, `scripts/verifier-route-matrix-smoke.sh`, `scripts/envelope-migration-smoke.sh`, `scripts/sandbox-grants-smoke.sh`, `scripts/pipeline-pair-smoke.sh`, `scripts/phat-controller-smoke.sh`, `scripts/state-branch-smoke.sh`. Base: see the Oracle proof line for the per-smoke baseline.
3. **Verifier:** `bash -n` passes on `scripts/tick.sh`, `scripts/requeue-stage.sh`, `scripts/cost-log.sh`, `scripts/spawn-worker.sh`, `scripts/spawn-verifier.sh`, `scripts/spawn-verifier-panel.sh` and `scripts/auth.sh`; `grep -n "python3 -c" scripts/auth.sh` prints nothing that contains `$codex_home`; `grep -nE '\*"?\$\{?stage_id\}?"?\*' scripts/tick.sh scripts/requeue-stage.sh` prints nothing. Base: the last two print the lines named in Surfacing concern.
4. **Verifier:** reading the awaiting branch of the PASS landing in `scripts/tick.sh` (`grep -n "push_awaiting_run_branch\|push held" scripts/tick.sh`), `pushed` is set `true` only when `push_awaiting_run_branch` returns 0 and the log line otherwise contains `push held` and the function's reason. The smoke cannot reach this call site without the full verdict path, which other cards in this batch may change. Base: neither string exists.
5. **Verifier:** `grep -n "per-agent author attribution" docs/tick-loop.md` prints nothing, `grep -n "Phat Controller <phat-controller@local>" docs/tick-loop.md` and `grep -n "git-push-check" docs/tick-loop.md` each print at least one line in step 6 and section (j) respectively, and the `auth_route` row of `docs/cost-log.md` names the per-role resolution. Base: the first grep prints step 6; the third prints only lines outside section (j).
6. **Verifier:** the constraints hold. In the run worktree, `git status --porcelain` lists changes only to the files named in Deliverables 1 to 9; in particular none to `scripts/add-stage.sh`, `scripts/auth-route.sh`, `scripts/phat-controller.sh`, `templates/` or any other smoke. `git diff -- scripts/tick.sh` has no hunk inside `manifest_patterns` and none on the `facts_recorder_identity` line. `scripts/check-contract-test-gate.sh print scripts/small-dispatch-fixes-smoke.sh` prints the digest recorded below. Base: no changes.

## Contract test

- **Test file:** scripts/small-dispatch-fixes-smoke.sh
- **Assertions digest:** sha256:ba19303a9466642297fd58bf950756a389e94a2dac07a97c8fd25b9f7d9283bf
- **Oracle proof:** red on `dev` at `8c2675d` in all six groups at the assertions listed under criterion 1, each for the card's reason (the L1 capture shows `- Worker: Claude Opus 5.5 R<<worker-tier>>Dlab` and a file `sedwrite <claude-opus-5-5@local>|g` in the caller's directory). Green, 8 s, against a throwaway reference in a scratch worktree (deleted after): the three fallbacks removed, a basename match in `requeue-stage.sh`, `auth-route.sh --print-mode --role` in `cost-log.sh`, `jq` in `auth.sh`, escaping before each `sed` render, a `push_awaiting_run_branch` like Deliverable 6, and a fixed author in `commit_state_branch`. Teeth checked by mutation against that reference, each tripping only its own group: reverting any one of `requeue-stage.sh`, `spawn-verifier.sh`, `spawn-verifier-panel.sh`, `auth.sh`, `cost-log.sh`; leaving the project name unescaped in `spawn-worker.sh`; a push function that ignores the verdict; one that reads the first line instead of the last; an inline push left beside the function; asking `git-push-check` about the wrong branch; an author still taken from `agent-whoami` first; a fixed author that still runs `agent-whoami`; a substring fallback kept for `stage-cards/` only. Re-proved red on the base at the same six assertions and green on the reference after the cold-read changes (digest above is the post-cold-read block). Regression baseline for criterion 2, identical on the base and on the reference: every listed smoke green. Red on the base and unchanged by the reference, so not criteria: `scripts/retry-after-reap-smoke.sh` (card 163's frozen block, `(a) a preserved and reaped attempt was not retried (status stalled)`), `scripts/superseded-status-smoke.sh` (schema validation and a renderer-list check), and `scripts/dependency-graph-smoke.sh` (environment gap: `ModuleNotFoundError: No module named 'jsonschema'`; its frozen block stubs `stage_card_for_id`, so this card cannot affect it).

## Cold read

Read by GPT-6.1 Sol (Codex, read-only sandbox, high effort), 2026-11-15, against the first draft. It had no questions and found every criterion producible from a Codex workspace-write seat without network. Items folded in:

1. The M7 precedence checks used agreeing values, so they proved nothing about order: now the family env (`subscription`) must beat a per-role manifest key (`api`), and the per-role env (`api`) must beat the family env (`subscription`).
2. L1 checked only the identity and card path: the hostile directory now holds the repository, so the project name and the worker's family notes are checked, and the panel's codex identity comes from a hostile stub `agent-whoami`. The artefact path was considered and left out: it is always `state/verifiers/<id>.json` with a validated id. Byte-for-byte rendering of ordinary values is covered by the criterion 2 spawn smokes rather than a new comparison.
3. L4 ignored exit codes: `check codex` must now exit 0 on the valid quoted path and non-zero on the chatgpt sibling.
4. L6 left out empty, unrecognised and multi-line verdicts and a failed push after PUSH: all four are now asserted. The call site's `pushed` and `push held` handling is criterion 4, judged by reading, with the reason given there.
5. The identity check would pass a fixed author that still ran `agent-whoami`: the stub now records calls and none is allowed.
6. The constraints had no check: criterion 6.
7. The smoke leaked its `sleep` processes (the pid list was appended inside a command substitution): pids now go to a file the exit trap reads, and a run leaves none behind.
8. Two false-failure risks: the definition grep required one exact spelling (now any `name() {`, `name () {` or `function name {` form) and the push grep matched `git push` inside quoted text (now only in command position, after `(`, `;`, `&&`, `|`, `$(`, `then`, `do` or `else`, or at line start).

Not folded: a resolver-failure normalisation case for M7 (Deliverable 3 states it; the base already records `subscription` for an unknown mode, so it would not distinguish).

## Out of scope

- **add-stage refusing an unreachable card** (the review's second M6 step). The frozen blocks of cards 113 (`scripts/pipeline-pair-smoke.sh`), 131 (`scripts/card-template-smoke.sh`) and 156 (`scripts/card-template-fields-smoke.sh`) queue fixture cards that live outside any card glob and require `add-stage.sh` to accept them, so a refusal would break three frozen contracts. Left for an operator decision. With the substring fallback gone, an unreachable card is no longer dangerous: the tick logs `stage card missing` and the stage stays pending.
- **`manifest_patterns` ignoring `stage_card_globs`.** Found while writing this card: `yq -r '.stage_card_globs[]? // empty'` is a lexer error under mikefarah yq v4 (`// empty` is jq syntax; `scripts/aggregate-dashboard.sh` already notes this), so manifest globs are never read and only the three default patterns apply. No subscriber declares a non-default glob today, so nothing is lost; a separate card.
- `pc_push`, `phat-controller.sh merge-awaiting` and every other push outside `tick.sh`.
- Hooks that a tick commit or push may run (review finding M8, card 172).
- The sandbox and credential findings M4 and M5 (card 172) and the verdict binding in C1 and C2 (another card in this batch). The L6 seam is a function precisely so this card's oracle does not depend on the verdict format those cards may change.
- Reinstalling the Homebrew keg.

## Budget

- **Worker wall-clock:** 60 minutes
- **Verifier wall-clock:** 30 minutes
- **Spend basis:** six small edits in seven scripts and two doc passages, each under twenty lines in the reference; about 1.5 times card 165's 0.7M tokens across both roles, so roughly 1M. Preparation (authoring, the reference, the mutation checks and the cold read) is recorded separately and was kept to one orchestrator session.

## Dispatch envelope

Return the standard envelope: status, the output of criterion 1, the pass or fail line of each smoke in criterion 2, the outputs of the commands in criteria 3 and 4, and the list of changed files.

## Family-specific notes

Codex verifier: everything here runs offline inside workspace-write. The smoke writes only under `mktemp -d`, starts and kills two `sleep` processes of its own, pushes only to a bare repository it creates in that directory, and puts stub `op-fetch`, `git-push-check` and `agent-whoami` first on `PATH` (it strips any real `git-push-check` or `agent-whoami` from `PATH` first). It sets `AUTOMETTA_HOME` to its temporary directory before sourcing `tick.sh`, so no log or state outside it is touched.
