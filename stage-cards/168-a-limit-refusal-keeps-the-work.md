# Stage card 168: a limit refusal keeps the work

## Metadata

- **Authored:** 2026-11-15
- **Orchestrator:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Worker:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Verifier:** GPT-6.1 Sol <gpt-6-1-sol@local>
- **Base branch:** dev
- **Run branch:** autometta/168-a-limit-refusal-keeps-the-work
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Recovery attempts:** 3
- **Recovery attempt:** 1
- **Dispatch:** serial
- **Pairing rationale:** operator asked to maximise Claude spend; cross-family kept by a Codex verifier; serial, so no alternation needed. Two branches of `scripts/tick.sh` on the worker-exit and re-dispatch paths, proved offline against throwaway git fixtures; Opus at high because a wrong bound either loses work or walks genuine refusals into the failure cap.
- **Open decisions:** none
- **Cold read:** done 2026-11-15, GPT-6.1 Sol read-only; see Cold read below for the findings and how each was folded in.

## Surfacing concern

Finding H3 of the 2026-11-15 dispatch-path review (`docs/reviews/2026-11-15-dispatch-path.md`, private tier), re-verified on `dev` at `8c2675d` (the dispatch scripts are unchanged since the review's snapshot `fc2929f`).

When a worker exits without a dispatch envelope, `_process_repo_locked` in `scripts/tick.sh` asks `handle_limit_refusal` whether its log is a provider limit refusal. `usage_limit_hit` (`scripts/usage-limit.sh`) greps the whole log for a deliberately broad pattern (`session limit`, `rate limit`, `too many requests`, `429` and others). On a match the stage is rewound to `pending` with `worker_pid` and `started_at` cleared, a pause is set, and no failure is recorded. Nothing checks that the exit was in fact immediate, and nothing preserves the worktree. The next dispatch then calls `ensure_run_worktree`, which always calls `remove_run_worktree`, that is `requeue-stage.sh --worktree-only`: `git worktree remove --force`, `rm -rf` and `git branch -D`. The uncommitted work goes with them. Nothing bounds the loop either.

This has already happened. On 2026-10-22 promo-flow stage `35-concept-surface-production` dispatched a codex worker at 21:44:45Z. It worked for 72 minutes and exited at 22:56:55Z without an envelope. Its log carried a line from its own output, `- when the user asked for "30% session limit saved" by day ...`, so the tick logged `worker was refused by the provider, not failed` and rewound it. The reaper then logged `uncommitted work in .../promo-flow-run-35-concept-surface-production, left standing (status=pending)` every minute until 23:57:02Z, when the stage was re-dispatched and `ensure_run_worktree` force-removed the worktree and its branch. The whole first attempt was lost.

The pattern is common in ordinary output: 24 of the 278 worker logs on this machine match it, including completed autometta stages 159, 161 and 162a. Only the envelope they wrote kept them off this path.

Why the bound is elapsed time and not log size: a codex dispatch log begins with codex's echo of the whole worker prompt, several kilobytes, before any model output (see the head of any codex worker log, for example `state/logs/165-one-tick-agent-for-the-fleet-worker.log`). The 512-byte ceiling of `is_instant_dispatch_configuration_fault` would therefore classify every codex refusal as mid-run, including the 2026-09-06 `ERROR: You've hit your usage limit` refusals. The preservation below makes the bound safe to get slightly wrong: a misclassified exit still keeps its work.

Deployment is orchestrator work: verify the effective fleet root separately from the Homebrew package; this card changes neither.

## Objective

A worker that exits without a dispatch envelope and whose log matches a provider limit message is rewound untouched only when its log was last written within `USAGE_LIMIT_INSTANT_SECONDS` (60) of its `started_at`. A later exit first has its work pinned on a `wip/<stage>-attempt-N` ref, and only then is rewound. At most two such rewinds happen per stage before the exit takes the ordinary missing-envelope path. The next dispatch never removes a run worktree or run branch holding work it could not pin. That covers uncommitted changes, an unreadable status, a real `state/` directory, and run-branch commits that no base or wip ref reaches.

## Inputs (read these in your own context)

- `scripts/usage-limit.sh`
- `scripts/tick.sh`, these parts only:
  - `is_instant_dispatch_configuration_fault` (about lines 700 to 750)
  - `handle_limit_refusal` (about lines 939 to 975)
  - `remove_run_worktree` and `ensure_run_worktree` (about lines 1990 to 2085)
  - `preserve_failed_work` (about lines 2220 to 2340)
  - the worker-exit block of `_process_repo_locked` (about lines 3740 to 3830, from `if [[ -n "${worker_pid:-}" ]] && kill -0` to the missing-envelope stall)
  - the `ensure_run_worktree` caller in `dispatch_pending_stage_if_available` (about line 3128)
- `scripts/usage-error-smoke.sh` (it calls `handle_limit_refusal` directly)
- `scripts/limit-refusal-keeps-work-smoke.sh` (the frozen oracle)
- `scripts/reap-worktrees.sh` (lines 100 to 200, read only: how a preserved worktree is judged)
- `schemas/state.yaml.json` (the strict stage-field schema)
- `docs/lessons.md` (the last two "Headless gotcha" sections, for style)

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. `scripts/usage-limit.sh`: add `USAGE_LIMIT_INSTANT_SECONDS=60` and `USAGE_LIMIT_MAX_REWINDS=2` beside the other limits, each with a comment saying what it bounds. `USAGE_LIMIT_PATTERN`, `USAGE_LIMIT_EXCLUDE`, `usage_limit_hit` and `usage_limit_reset_epoch` are unchanged.
2. `scripts/tick.sh`, the worker-exit refusal branch of `_process_repo_locked` (the one that calls `handle_limit_refusal` for role `worker` when no envelope exists):
   - **Instant.** The worker log's mtime minus the stage's `started_at` is at most `USAGE_LIMIT_INSTANT_SECONDS`, measured the way `is_instant_dispatch_configuration_fault` measures it. Log size is not part of this bound. Rewind exactly as today: pause through `handle_limit_refusal`, set `pending`, clear `worker_pid` and `started_at`. Record no failure, and do not count the exit toward the rewind bound.
   - **Not instant.** Here 60 seconds is still instant and 61 is not. If the stage record's new `limit_rewinds` field (absent means 0) is below `USAGE_LIMIT_MAX_REWINDS`, call `preserve_failed_work` with a reason naming the provider limit and the elapsed seconds. Only when it returns 0: increment `limit_rewinds`, then pause and rewind as for an instant refusal.
   - **Otherwise** (the bound is reached, or preservation failed): log one line saying why the exit is not rewound and fall through to the ordinary path. That path does the token accounting, then the `worker_envelope_missing_after_exit` stall with its own preservation and one recorded failure.
   - Correct the comment above the branch: the run worktree is not reused.
3. `scripts/tick.sh`, `ensure_run_worktree`: before `remove_run_worktree`, when the stage's run worktree exists, apply these checks in this order:
   1. If `<worktree>/state` exists and is not a symlink (the link this function installs was replaced), refuse.
   2. If `git status --porcelain -- . ':(exclude)state'` in the worktree fails, refuse.
   3. If that status is non-empty, call `preserve_failed_work` on the worktree, with a reason such as "unpreserved work found at re-dispatch". Refuse if it fails.

   Then, whether or not the worktree exists: if the run branch exists and holds a commit reachable from neither `base_branch` nor any `wip/<stage>-attempt-*` ref (a worker self-commit, which the landing path tolerates), refuse. To refuse is to log one line naming the reason and return non-zero without removing the worktree or the branch. Both callers already handle a non-zero return: the dispatch path stalls the stage as `run_worktree_failed`, and the pipeline path refuses the pair. A clean or absent worktree with no unpinned commits is re-cut exactly as today. On success, stdout still carries only the worktree path, so send any log output from preservation to stderr.
4. `docs/lessons.md`: a new `## Headless gotcha <next free number>: ...` section. It records:
   - the 2026-10-22 promo-flow stage 35 loss;
   - the rule: instant means the log was written within `USAGE_LIMIT_INSTANT_SECONDS` of `started_at`, inclusive; anything later is preserved before a rewind, at most `USAGE_LIMIT_MAX_REWINDS` times;
   - why log size is not part of the bound;
   - that `limit_rewinds` survives a requeue.

   Name both constants in that one section. Use the next free number, since another card may add a gotcha first.

5. `schemas/state.yaml.json`: declare `limit_rewinds` as an optional integer with minimum 0 under stage properties. Keep `additionalProperties: false` and all existing field types unchanged.

## Constraints

- `scripts/limit-refusal-keeps-work-smoke.sh` is frozen: make it pass, do not edit it.
- `handle_limit_refusal` keeps its four-argument contract, and the verifier's refusal branch in `_process_repo_locked` is unchanged. `scripts/usage-error-smoke.sh` calls it directly.
- An instant refusal records no failure, consumes no attempt, does not count toward the rewind bound, and leaves the run worktree standing. That is today's behaviour, and the 2026-08-16 incident it fixed must not come back.
- `preserve_failed_work`'s signature and behaviour are unchanged; reuse it, do not copy its git surgery.
- Do not change `scripts/requeue-stage.sh`, `scripts/reap-worktrees.sh`, the verifier phase, or any `verifier_*` stage field. Card 166 also edits `requeue-stage.sh` and the worker-dispatch path. Keep the two cards independent so either can land first. `limit_rewinds` is therefore not reset by a requeue; say so in the gotcha.
- Token accounting for a rewound exit is unchanged: a rewound exit is still not accounted, which is out of scope here.
- Offline only. The smokes work under `mktemp -d`. Nothing touches `~/.autometta`, a subscriber, or this repo's own `state/`. Do not run `autometta tick`.
- No git commands in the main checkout; the tick commits on PASS. The smokes run git only inside their own temporary repositories.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. **Worker and verifier:** `scripts/limit-refusal-keeps-work-smoke.sh` exits 0. Every exit time is fixed by setting `started_at` and the log's mtime explicitly, and the dead worker pid is above any pid_max. Its frozen cases:
   - **(1)** A codex-identity worker ran 40 minutes, edited the tracked deliverable `docs/partial.md`, left an untracked note, and exited with no envelope after its log named a "session limit". It is rewound to `pending`: `worker_pid` and `started_at` are cleared, no failure is recorded, a pause is set and `limit_rewinds` is 1. Both files are on a `wip/07-limited-attempt-N` ref, and the recorded `wip_commit` holds this attempt's deliverable.
   - **(2)** The next `ensure_run_worktree` re-cuts the worktree at the base tip, with the seed content and no note, and the work survives on the ref.
   - **(3)** A second such exit is rewound and pinned, and `limit_rewinds` becomes 2. The third is `stalled` with marker `worker_envelope_missing_after_exit` and exactly one failure, and its work is pinned.
   - **(4)** Four instant refusals at 0 seconds, one claude-shaped and three codex-shaped (a multi-kilobyte prompt echo, then `ERROR: You've hit your usage limit`). Each rewinds to `pending`, clears `worker_pid` and `started_at`, records no failure, sets a pause, and leaves the worktree at the base tip.
   - **(5)** Three codex refusals at exactly 60 seconds are instant, as in (4). Two limit exits at 61 seconds are pinned and counted. An instant refusal after that is still untouched.
   - **(6)** A mid-run limit exit whose work cannot be pinned (no worker identity) is not rewound to `pending`, and its file survives.
   - **(7)** A standing dirty worktree left by a pre-card rewind is pinned before the re-cut, and the new worktree starts at the base tip with a valid state link.
   - **(8)** `ensure_run_worktree` returns non-zero and removes nothing for each of: unpinnable uncommitted work; a worktree whose `.git` points nowhere; a real `state/` directory. After it runs on a run branch carrying a worker self-commit, that commit is still reachable from some branch.
   - **(9)** `handle_limit_refusal` with four arguments still pauses on a long verifier log.
   - **(10)** `USAGE_LIMIT_INSTANT_SECONDS` is 60 and `USAGE_LIMIT_MAX_REWINDS` is 2.
   - **(11)** One headless gotcha in `docs/lessons.md` names both constants.

   - **(12)** The strict stage schema declares the new `limit_rewinds` counter as an integer with minimum 0.

   Base: red at the first preservation assertion (`(1) the rewind did not pin the attempt's tracked deliverable on a wip/07-limited-attempt-N ref`).
2. **Worker and verifier:** `scripts/usage-error-smoke.sh`, `scripts/auto-retry-smoke.sh`, `scripts/preserve-failed-work-smoke.sh`, `scripts/preserve-stays-inside-smoke.sh`, `scripts/run-worktree-state-symlink-smoke.sh`, `scripts/landing-dispatch-smoke.sh`, `scripts/requeue-reset-smoke.sh` and `scripts/pipeline-pair-smoke.sh` each exit 0. The last takes under a minute on the base (37 s) and drives the pipeline path's own `ensure_run_worktree` calls. Base: all green.
3. **Verifier:** `bash -n scripts/tick.sh` and `bash -n scripts/usage-limit.sh` pass. `shellcheck -S warning scripts/tick.sh scripts/usage-limit.sh` reports no warning beyond the base's two: SC2034 `unit` at `tick.sh:652` and SC2154 `autometta_vendor_stamp_name` at `tick.sh:3211`. Line numbers may move; the findings may not. Base: exactly those two.
4. **Verifier:** `scripts/check-contract-test-gate.sh --worktree` passes. It only proves the frozen block and this card's digest still agree, so the verifier also runs criterion 1 itself rather than relying on the gate. Base: green once the card and smoke are committed, which happens before the card is queued.

Baseline note, unchanged from base and not a criterion: `scripts/retry-after-reap-smoke.sh` (card 163's oracle) is red on `dev` at `(a) a preserved and reaped attempt was not retried`. Do not try to fix it here.

## Contract test

- **Test file:** scripts/limit-refusal-keeps-work-smoke.sh
- **Assertions digest:** sha256:cc319b2d9266f7ee641145c543fb126b33b8e1d1eab178ae729899af5d5e66eb
- **Oracle proof:** red on `dev` at `8c2675d`. Status `pending`, no failure and the pause all hold today, so the first failure is `(1) the rewind did not pin the attempt's tracked deliverable on a wip/07-limited-attempt-N ref`. A non-fatal diagnostic run showed 25 red assertions across (1), (2), (3), (5), (6), (7), (8), (10) and (11). (4), (9) and the 60-second cases of (5) are regression checks and are green on the base. A throwaway reference in a scratch worktree passed every assertion, three runs in a row. It added the two constants, an elapsed-only instant check, preserve-then-rewind with a `limit_rewinds` counter, the ordered refusal checks in `ensure_run_worktree`, and a stub gotcha. With it, the eight smokes of criterion 2 stayed green. Two mutants of that reference were each caught. One also required a log of at most 512 bytes and failed at `(4) an instant codex refusal was not rewound to pending (status stalled)`. The other used `<` for the bound and failed at `(5) a codex refusal 60s after dispatch was not rewound to pending`. The reference worktree was then removed. Refusal lines carry no reset clock, so every pause is the one-hour fallback and no assertion depends on the time of day.

Resume check (2026-11-15, dispatch baseline `3052ba3`): the unchanged oracle was rerun and is red at `(1) the rewind did not pin the attempt's tracked deliverable on a wip/07-limited-attempt-N ref`. Its digest still matches. The earlier reference proof and cross-family cold read above are retained; no scope or assertion changed. Cards 169 and 172 are now completed and merged. Serial dispatch keeps this card behind the already queued 173, 174 and 170; the worker and verifier must run the acceptance regressions on their actual dispatch base.

Readiness correction before first dispatch (2026-11-15): Codex claims closure found that stage objects use `additionalProperties: false`, but the draft omitted the new counter from the schema. Deliverable 5 and frozen case (12) now require its typed declaration without relaxing schema strictness. The original preservation assertions are unchanged; the old digest is retained in commit `49b2fc5`. The added check is red against the production schema and separately green against a minimal copy declaring the counter; wrong type, negative minimum and a permissive stage schema are rejected. The prior full-reference and Codex cold-read evidence still cover the unchanged preservation core.

## Cold read

Read by GPT-6.1 Sol (Codex, read-only sandbox), 2026-11-15, against the first draft. Every material item is folded in:

1. **Unsafe bootstrap.** A failed `mktemp` made `tmp` the checkout path, which the EXIT trap would delete. The smoke now refuses unless `mktemp` returned a directory named `limit-refusal-smoke.*`. Other smokes share the old pattern; that is noted for the orchestrator, not fixed here.
2. **Wrong fixture.** The "tracked deliverable" was untracked. `docs/partial.md` is now committed in the seed, and (2) checks the re-cut has the seed content.
3. **Boundary and coverage gaps.** Each gap is now asserted: the 60 and 61 second boundary, an instant refusal after the allowance is spent, preservation failure on the worker-exit path, `limit_rewinds`, the cleared `started_at`, the stall marker, and `wip_commit` holding this attempt's work.
4. **Flakiness.** Exit times are now set through `started_at` and an explicit log mtime instead of the live clock. The dead pid is 99999999, above any pid_max. A non-zero tick return now fails the smoke instead of being swallowed.
5. **Deliverable 3 left cases open.** It did not protect an unreadable status, a real `state/` directory, or run-branch commits no ref keeps, so Deliverable 3 now refuses on each, with an assertion apiece in (8). The reader's question 1 is answered by the same change.
6. **Docs check too loose.** It now requires one gotcha section naming both constants, heading included.
7. **Gate passes vacuously.** Criterion 4 now says the gate only proves digest agreement and the verifier runs criterion 1 itself; its baseline note is corrected.
8. **Frozen file listed as a deliverable.** Moved to Constraints.

Not folded, with reasons:

- (9) still calls `handle_limit_refusal` directly rather than driving the verifier's refusal branch. The branch is unchanged code under a Constraint the verifier judges from the diff, and driving it would need the verifier phase that card 166 is changing.
- The test does not assert diagnostic log wording, so the worker may phrase its log lines freely.

Sandbox evidence: the reader could not create temp directories in its read-only seat. The verifier's workspace-write seat can (`$TMPDIR` is writable), and no criterion needs the network.

## Out of scope

- Token accounting for a rewound limit exit (today a rewound exit is never accounted; a separate card if wanted).
- The verifier's refusal path. A long verifier that matches the pattern still returns its attempt and pauses, with no work at risk.
- Resuming the next attempt from the preserved work. The next dispatch starts from the base branch; the wip ref is for the operator or a re-brief.
- Resetting `limit_rewinds` on requeue (`requeue-stage.sh` is untouched, see Constraints).
- Narrowing `USAGE_LIMIT_PATTERN` or scanning only the log's tail.
- `scripts/retry-after-reap-smoke.sh`, red on the base (see the baseline note).
- Ignored files in a run worktree that are not card deliverables: `preserve_failed_work` force-adds only deliverables, as today.

## Budget

- **Worker wall-clock:** 45 minutes (kill at 70)
- **Verifier wall-clock:** 25 minutes
- **Spend basis:** `state/cost-log.jsonl` on 2026-10-23: autometta role median 1.0M tokens, p95 3.7M. Cards 161 and 163, the nearest precedents (the same preserve and worktree machinery in `tick.sh`), planned 5M per stage. Plan 5M here.

## Dispatch envelope

Return the standard envelope: status, the outputs of criteria 1 to 3, and the list of changed files.

## Family-specific notes

Codex verifier: every smoke in criteria 1 and 2 builds its fixtures under `mktemp -d` (`$TMPDIR`) and needs no network, so it runs inside the workspace-write sandbox. The new smoke sources `scripts/tick.sh` from the worktree under test, not from the Homebrew install.
