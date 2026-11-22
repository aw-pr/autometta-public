# Stage card 172: agent sandboxes stay scoped

## Metadata

- **Authored:** 2026-11-15
- **Orchestrator:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Worker:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Verifier:** GPT-6.1 Sol <gpt-6-1-sol@local>
- **Base branch:** dev
- **Run branch:** autometta/172-agent-sandboxes-stay-scoped
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Recovery attempts:** 3
- **Recovery attempt:** 1
- **Dispatch:** serial
- **Pairing rationale:** operator asked to maximise Claude spend; cross-family kept by a Codex verifier; serial, so no alternation needed. Opus at high because the change narrows a sandbox grant and pins git hook resolution on the tick's side, where a quiet mistake either breaks agent-home cards or skips the operator's own guard hooks; Sol at high judges it from a workspace-write seat, which is the seat whose grant this card narrows.
- **Open decisions:** none
- **Cold read:** done 2026-11-15; see Cold read below for the family and findings.

## Surfacing concern

The 2026-11-15 dispatch-path review (`docs/reviews/2026-11-15-dispatch-path.md`, findings M4 and M8) found two ways a sandboxed role reaches code that runs outside its sandbox. Both re-verified on `dev` at `8c2675d` the same day:

- **M4.** `codex_agent_home_argv_for_card` (`scripts/models.sh`) answers `- **Requires agent home:** true` with `--add-dir ~/.claude`, the whole Claude home. A codex role on such a card can write `~/.claude/settings.json` (hooks that run in every later Claude session, the operator's included) and `~/.claude/CLAUDE.md` (which steers the same stage's Claude verifier). The grant was added for one directory: card 98's SDK worker died on `EPERM ... mkdir '~/.claude/session-env/<session-id>'`. Measured 2026-11-15 by the orchestrator under `codex sandbox` with `sandbox_mode=workspace-write` and network on (Claude Code 2.1.325, codex-cli 0.169.0): with only `~/.claude/session-env` writable, a writing probe to `~/.claude` is refused (`Operation not permitted`), and a nested `claude -p` session both answers and runs a Bash tool call (`probe-123`). So the narrow grant is sufficient for the CLI path. The SDK path was not measured: `claude_agent_sdk` is not installed for this machine's `python3`.
- **M8.** When a subscriber's `core.hooksPath` is a relative, tracked directory (husky's `.husky/_`, or `.githooks`), git resolves it inside whichever worktree it runs in. `preserve_failed_work` (`scripts/tick.sh`, run on a verifier FAIL, a stall, a kill and from `phat-controller.sh`) runs `git status`, `git add`, `git commit` and `git reset` inside the run worktree as the operator, before or without any passing verdict. Reproduced with this card's smoke on `dev`: a worker that edits `.githooks/` in its worktree had its `post-index-change` hook run 4 times, `pre-commit`, `prepare-commit-msg`, `commit-msg` and `post-commit` once each and `reference-transaction` 7 times, all from one preserve. That is wider than the review's wording (commit hooks only): any hook git runs on an index write or a ref update is reached too. No subscriber sets a tracked `core.hooksPath` today (checked 2026-11-15 across `~/.autometta/subscribers`), so this is latent, not live.

The review's third finding in this group, M5 (every agent can read the 1Password service-account token), is not on this card: closing it needs an operator decision about which routes may see which credentials and where the token lives (see Out of scope).

## Objective

A codex role on a `Requires agent home` card can write only the Claude per-session directory (`<claude home>/session-env`), and no git command the tick runs inside a run worktree while preserving a failed or stalled attempt executes a hook from that worktree's own files; the operator's own hooks still run.

## Inputs (read these in your own context)

- `docs/reviews/2026-11-15-dispatch-path.md` (sections M4 and M8 only)
- `scripts/models.sh` (the comment block above `codex_agent_home_argv_for_card` and the function itself)
- `scripts/tick.sh` (`preserve_failed_work`, and `ensure_run_worktree` for how a run worktree is cut)
- `scripts/sandbox-grants-smoke.sh` (section 3b)
- `scripts/sandbox-scope-smoke.sh` (the frozen contract test)
- `templates/stage-card.md` (the `Requires agent home` metadata line)

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. `scripts/models.sh`: `codex_agent_home_argv_for_card` grants `--add-dir <agent home>/session-env`, where the agent home is `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` as today. When the agent home exists and `session-env` does not, create `session-env` first. When the agent home itself does not exist, grant nothing and create nothing (as today). Every no-grant case is unchanged and creates nothing: a card that does not ask, and any sandbox other than `workspace-write`. The comment above the function already describes the per-session directory; add one sentence saying why the whole home is not granted (its `settings.json` hooks and `CLAUDE.md` are code execution and verifier steering). The comment is not asserted.
2. `scripts/tick.sh`: every git command `preserve_failed_work` runs inside the run worktree, the rollback `reset --mixed` included, resolves hooks from the operator's checkout, not the worktree. Resolve the hooks directory in `repo_root` (for example `git -C "$repo_root" rev-parse --path-format=absolute --git-path hooks`, which honours an unset, absolute or relative `core.hooksPath`) and pin `core.hooksPath` to that absolute path for those commands (`git -c core.hooksPath=...`, or `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_0`/`GIT_CONFIG_VALUE_0` scoped to the function). Resolve it once per call; a small helper that later cards can reuse at the sites listed under Out of scope is welcome but not required.
3. `scripts/sandbox-grants-smoke.sh`: section 3b computes the agent-home grant with `HOME` pointed at a fixture directory under its `tmp_root` that contains a `.claude` directory, and with `CLAUDE_CONFIG_DIR` unset, so the suite never creates anything in the real Claude home; its first check expects `--add-dir <fixture>/.claude/session-env`. The other 3b checks keep their expectations. This file is a regression suite with an `AUTOMETTA-CONTRACT-NONE` marker, not a frozen block; change nothing outside section 3b.
4. `templates/stage-card.md`: in the `Requires agent home` metadata line, replace `so this grants write access only, to that one directory` with ``so this grants write access only, to the `session-env` directory inside it``. The frozen smoke checks that exact phrase and the absence of `to that one directory` on that line.
5. The frozen smoke `scripts/sandbox-scope-smoke.sh` passes. Do not edit it.

## Constraints

- No `--no-verify`, no empty or `/dev/null` hooks path, no other way of skipping hooks: the operator's hooks (publish guards, `commit-msg` trailers) must still run on the preserve commit.
- A repo whose `core.hooksPath` is unset or absolute behaves exactly as before.
- The pin covers the hook files git itself runs. An operator hook that in turn runs worktree content (husky calling `npx lint-staged`, a hook calling `./scripts/lint.sh`) still runs worker-written code; that is the same exposure as the verifier running acceptance commands and is not this card (see Out of scope). Do not try to sandbox hook bodies.
- No change to the codex sandbox mode, the network grant, the `state/` directory grant, Claude CLI dispatch flags, `spawn-worker.sh`, `spawn-verifier.sh` or `spawn-verifier-panel.sh`. Other cards in this batch own those.
- No other behaviour of `preserve_failed_work` changes: what it stages, the commit author and subject, the `wip/<stage>-attempt-<n>` pin and the state it records (cards 110 and 158).
- Never run anything against the real `~/.claude`: the frozen smoke points `HOME` at a fixture, and any manual check must do the same.
- The live fleet tick runs the installed Homebrew keg, not this checkout. Landing this card changes nothing live until the operator reinstalls the keg (`scripts/install-homebrew-local.sh`), which is a separate operator step and not part of this card.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. **Worker and verifier:** `bash scripts/sandbox-scope-smoke.sh` exits 0 and prints its PASS line. Frozen cases, all against fixture homes and fixture repos with global and system git config ignored: the agent-home grant is exactly `--add-dir <home>/.claude/session-env`, and `--add-dir $CLAUDE_CONFIG_DIR/session-env` when that is set; `session-env` is created under an existing Claude home that lacks it; no grant and no created Claude home when there is none; no grant and no created `session-env` for a card that does not ask, a card with no line, `danger-full-access` or `read-only`; the template line carries Deliverable 4's phrase and not the old one; with a tracked relative `core.hooksPath`, a worker's edits to six hooks in its worktree (`pre-commit`, `prepare-commit-msg`, `commit-msg`, `post-commit`, `reference-transaction`, `post-index-change`) never run during `preserve_failed_work`, the attempt is still pinned on `wip/<stage>-attempt-1` with the worker's file in it, and the operator's own base `pre-commit` and `commit-msg` both still run; when the pin cannot be written (read-only `refs/heads/wip`), the rollback runs none of the worker's hooks, writes no pin and keeps the worker's file; with the default `.git/hooks` layout and with an absolute `core.hooksPath` outside the repo, the operator's `pre-commit` and `commit-msg` still run and the attempt is still pinned. Base: red at the first M4 assertion (`agent-home grant is '--add-dir <home>/.claude', expected only --add-dir <home>/.claude/session-env`); with the M4 section removed, red at the first M8 worker-hook assertion (`preserve: the tick ran worker-edited hooks`, listing the hooks named in the Surfacing concern).
2. **Worker and verifier:** `bash scripts/sandbox-grants-smoke.sh` exits 0, and its section 3b sets `HOME` to a fixture (Deliverable 3; the verifier reads the diff). Base: green, using the real `HOME`; on the reference implementation it turned red at 3b's first check only, which Deliverable 3 fixes.
3. **Worker and verifier:** `bash scripts/preserve-failed-work-smoke.sh`, `bash scripts/preserve-stays-inside-smoke.sh` and `bash scripts/auto-retry-smoke.sh` each exit 0. Base: green.
4. **Verifier:** `bash -n scripts/models.sh scripts/tick.sh scripts/sandbox-grants-smoke.sh` passes, and `git status --porcelain --untracked-files=all -- . ':(exclude)state'` in the run worktree (the worker does not commit, so this is the whole attempt, new files included) lists only `scripts/models.sh`, `scripts/tick.sh`, `scripts/sandbox-grants-smoke.sh` and `templates/stage-card.md`. Base: `bash -n` green.

Baseline finding, unchanged from base and not a criterion: `scripts/retry-after-reap-smoke.sh` (card 163's frozen test) is red on `dev` at `(a) a preserved and reaped attempt was not retried (status stalled)` because card 163 has not landed. It also calls `preserve_failed_work`; do not try to make it green.

## Contract test

- **Test file:** scripts/sandbox-scope-smoke.sh
- **Assertions digest:** sha256:00a0366ac11b527ce7bf61c54c70495aaedeea2d293a59aabab00c922ab63dd4
- **Oracle proof:** red on `dev` at `8c2675d` at the first M4 assertion (the grant is the whole `<home>/.claude`); the M8 block run alone on `dev` is red at the worker-hook assertion with the hooks listed in the Surfacing concern. Green against a throwaway reference in a scratch worktree (session-env grant in `models.sh`, the template line, and `preserve_failed_work` wrapped to pin `core.hooksPath` to `git -C "$repo_root" rev-parse --path-format=absolute --git-path hooks` through `GIT_CONFIG_*`), both from a plain shell and under `codex sandbox` with `sandbox_mode=workspace-write`, so the Sol seat can run it. Bad references fail at the intended assertions: pinning the hooks path to `/dev/null` fails `the operator's own pre-commit hook did not run`; granting the whole home alongside `session-env` fails the first M4 assertion; pinning every command except the rollback `reset --mixed` fails `preserve rollback: the tick ran worker-edited hooks` (14 `reference-transaction`, 1 `post-index-change`). Re-proved red on `dev` and green on the reference after the cold-read additions. On the reference, `preserve-failed-work-smoke`, `preserve-stays-inside-smoke` and `auto-retry-smoke` stayed green and `sandbox-grants-smoke` went red only at 3b. The reference worktree was deleted after the run.

## Cold read

Read by GPT-6.1 Sol (Codex, read-only sandbox, high effort), 2026-11-15, against the first draft of the card and its smoke. Verdict NOT READY; every item is folded in:

1. `sandbox-grants-smoke.sh` computed the grant with the real `HOME`, so after the change it would create `session-env` in the real Claude home (and could fail under workspace-write): Deliverable 3 now moves 3b onto a fixture `HOME`, and criterion 2 says so.
2. The template assertion only grepped `session-env`, which the base template already contains: it now checks Deliverable 4's exact phrase on the `Requires agent home` line and the absence of the old one.
3. An operator hook that runs worktree scripts still executes worker code: named as a boundary in Constraints and Out of scope.
4. The rollback `reset --mixed` was untested: a read-only `refs/heads/wip` fixture now forces it, and a reference that leaves it unpinned fails.
5. The absolute `core.hooksPath` constraint was untested: now a fixture.
6. Only the operator's `pre-commit` was checked: `commit-msg` is now checked in every layout.
7. The named helper and the `models.sh` comment were required but unasserted: both are now stated as not asserted (the helper optional).
8. No-grant cases ran against a home that already had `session-env`: they now use a home without one and assert nothing is created.
9. Criterion 4's `git diff --name-only HEAD` missed new files: now `git status --porcelain --untracked-files=all`.
10. The smoke's header claimed `HOME` was a fixture throughout: corrected, and the git fixtures now run with `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1`.
11. Metadata said the cold read was done while this section said pending: filled.

Sandbox evidence: apart from item 1, the reader found nothing a Codex workspace-write seat cannot run, and the orchestrator ran the frozen smoke under `codex sandbox` with `sandbox_mode=workspace-write`.

## Out of scope

- **M5, the service-account token.** Claude roles run with `--dangerously-skip-permissions` and no OS sandbox, and codex `workspace-write` can read all of `$HOME`, so any role can read `~/.config/op/service-account.env` today. Stopping that needs an operator decision (move the token off agent-readable disk, sandbox Claude roles, or a separate uid), and the `env` argv exposure is in `~/Scripts/op-fetch`, outside this repo. Not this card.
- Hooks in a tracked `.claude/settings.json` in the run worktree, which a Claude verifier (bypass permissions, cwd in the worktree) loads and runs. Measured 2026-11-15: `--setting-sources user` stops them but also drops the project `CLAUDE.md`; `--settings '{"disableAllHooks":true}'` keeps `CLAUDE.md` but also disables the operator's user hooks, the mcp-hub workflow guard included. That trade is for the operator; not this card.
- Operator hooks whose bodies run worktree content (husky's `npx lint-staged`, a hook calling a tracked script): the hook file is the operator's, the code it reaches is the worker's, as when the verifier runs acceptance commands.
- The other tick-side git commands that run inside a run worktree: the PASS landing commit (the verifier has judged the tree by then), the pipeline tail rebase in `pipeline_prepare_tail_rebase` (card E's ground for H4) and `reap-worktrees.sh`'s `git status`. A later card can reuse Deliverable 2's hooks-path resolution there.
- Running Claude CLI dispatches with `--setting-sources` or an isolated `CLAUDE_CONFIG_DIR` (the review's second M4 suggestion). Narrowing the grant closes the codex-to-`~/.claude` channel this card is about.
- Re-measuring the SDK route inside the narrowed grant.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 25 minutes
- **Spend basis:** a little larger than 165 (about 0.7M tokens across both roles): one function and its comment in `models.sh`, one wrapped function in `tick.sh`, one regression expectation and one template line.

## Dispatch envelope

Return the standard envelope: status, the outputs of criteria 1 to 4, and the list of changed files.

## Family-specific notes

The frozen smoke builds its fixture repos, run worktrees and fake `HOME` under `mktemp -d` and runs no network, so it works inside the Codex `workspace-write` sandbox (checked with `codex sandbox`). Claude worker: do not probe the real `~/.claude` or run a nested `claude` session to re-measure the grant; the orchestrator's measurement is recorded above.
