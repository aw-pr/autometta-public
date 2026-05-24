---
name: feedback-stage-5-silent-failure-risks
description: Stage 5 verifier flagged two silent-failure risks in scripts/tick.sh that are within scope (static validation only) but must be addressed before stage 6 (live run). Plus one capability gap against docs/phat-controller.md section (g).
metadata:
  type: feedback
---

Stage 5 PASSED all seven acceptance criteria but the cross-family verifier (Claude Sonnet 4.6) flagged three issues that are out of scope for static validation and in scope for the eventual live run in stage 6. Each is logged here so it cannot be re-discovered the hard way.

**Silent-failure risk 1: `yq` absence aborts mid-tick.** `scripts/tick.sh::state_apply_json` calls `yq -P` unconditionally to write yaml. Under `set -euo pipefail`, an absent `yq` aborts the whole `process_repo` call before `budget_increment_tick` runs, leaving ticks uncounted. Symptom in production: the clock-tick budget never decrements, the loop never halts on `clock_tick_cap`.

**Silent-failure risk 2: `git checkout -B` discards dirty work.** `scripts/tick.sh::commit_state_branch` issues `git checkout -B phat-controller/state` with stderr suppressed. In a dirty working tree this can silently discard uncommitted human changes. Symptom in production: a human edits a file mid-tick and loses it without warning.

**Capability gap: worker-stall detection by elapsed time.** `scripts/tick.sh` does not implement the 1.5x-grace stall detection described in `docs/phat-controller.md` section (g). Stalls fire only when a stage card is missing, not when wall-clock budget is exceeded. Symptom in production: a hung worker is not detected by the tick; it would have to be killed manually.

**Why:** All three are real defects, but the stage 5 acceptance criteria explicitly scope the stage to "implementation + static validation only" and accept stubs for `--repair`. The verifier correctly noted PASS at static-validation scope while flagging the risks for production.

**How to apply:** Before stage 6 (the live run) is approved by the user, three fixes must land:

1. `state_apply_json` must detect missing `yq` and either install it, abort the tick with a clear error written to the budget halt reason, or use a pure-bash yaml fallback. Aborting silently under `pipefail` is not acceptable.
2. `commit_state_branch` must check `git status --porcelain` before `git checkout -B`. A non-empty working tree aborts the tick with a halt reason. Do not silently discard work.
3. `process_repo` must time-compare `last_tick_at` (or per-stage `started_at`) against the stage card's wall-clock budget plus 1.5x grace. Stages exceeding grace are marked stalled.

Cross-reference: [[decision-tick-implementation-parameters]], [[decision-failure-budget-clock-tick]], [[decision-state-dir-per-repo]].
