# Stage card 09-budget-cap-halt-misattribution: Stop overwriting halt_reason on already-halted ticks

## Metadata

- **Authored:** 2026-05-26
- **Orchestrator:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Worker:** Codex GPT-5.3 <codex-gpt-5-3@local>
- **Verifier:** Claude Sonnet 4.6 <claude-sonnet-4-6@local>
- **Pairing rationale:** Cross-family. Small but load-bearing tick.sh change — Claude verifier confirms the new code paths preserve original halt reasons across the three realistic halt sources (dirty-tree, yq-missing, real cap).

## Objective

`tick.sh` currently does:

```bash
if ! budget_check_caps "$repo_root"; then
  budget_halt "$repo_root" "budget cap exhausted"
  log "halted ${repo_root} due to budget cap"
  return 0
fi
```

`budget_check_caps` returns 1 if **any** of these is true: `halted` is already set, OR `tokens_spent >= token_cap_total`, OR `wall_clock_elapsed >= wall_clock_cap`, OR `clock_ticks_used >= clock_tick_cap`, OR `consecutive_failures >= consecutive_failure_cap`.

The caller treats every failure mode as "budget cap exhausted", overwriting the original `halt_reason` and emitting a misleading log line. Observed during the emergence-lab adoption: a halt that was originally set for `dirty-working-tree` got rewritten to `budget cap exhausted` on the next tick, hiding the real cause and confusing the operator (who saw 29 / 100 ticks used and asked why a "cap" was hit).

Fix: only mutate `halt_reason` when an actual cap is hit. Pre-existing halts must keep their original reason.

## Inputs (read these in your own context)

- `scripts/tick.sh`
- `scripts/budget.sh`
- `docs/dispatch-contract.md` (read-only — for any mention of the halt-reason field)

Do not read anything else.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. `scripts/budget.sh` — change `budget_check_caps` to return one of:
   - `0` (no halt)
   - `2` (already halted; do not re-record the reason)
   - `1` (real cap hit; caller should record the specific cap)
   The function should write the specific cap name (`token-cap`, `wall-clock-cap`, `tick-cap`, `failure-cap`) into a side channel — either a global variable like `BUDGET_CHECK_LAST_HIT` or by printing it on stdout — so the caller can pass it to `budget_halt` without re-computing.
2. `scripts/tick.sh` — replace the single `if ! budget_check_caps` block with a switch on the new return code:
   - `0` → continue.
   - `2` → log `"halted ${repo_root} (reason already recorded: $(jq -r '.halt_reason' "$budget_file"))"` and `return 0` without mutating `halt_reason`.
   - `1` → record the actual cap that fired (the side-channel value, e.g. `token-cap`, `wall-clock-cap`, etc.) as `halt_reason` and log accordingly.
3. `docs/dispatch-contract.md` — short note in the halt-reason section documenting the canonical halt_reason values.

## Constraints

- Backward-compat: existing budget.json files with `halted: false` continue to pass the cap check without behaviour change.
- `bash -n` syntax check must pass on both scripts.
- Bash 3.2 compatible (no associative arrays, no `[[ =~ ]]` extensions beyond what scripts already use).
- No new dependencies.
- Worker does NOT self-commit. Orchestrator commits on verifier-pass per the dispatch-contract update from stage 07.
- Atomic commits with `--author="$(agent-whoami)"`. Subject prefixed `09-budget-cap-halt-misattribution: ...`.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. `bash -n scripts/tick.sh && bash -n scripts/budget.sh` passes.
2. `budget_check_caps` has three return codes documented in a header comment.
3. `tick.sh` no longer contains the literal string `"budget cap exhausted"` as a hard-coded halt reason. The actual cap name (`token-cap`, `wall-clock-cap`, `tick-cap`, `failure-cap`) is written instead.
4. A unit-style scenario test: simulate a budget.json with `halted: true, halt_reason: "dirty-working-tree"`. Run a synthetic `budget_check_caps` invocation. Confirm the return code is `2` (or whatever non-1 sentinel is chosen) and that `halt_reason` is unchanged after the caller path runs.
5. A unit-style scenario test: simulate `clock_ticks_used == clock_tick_cap`. Confirm `halt_reason` is set to `tick-cap` (or the chosen canonical value), not `budget cap exhausted`.
6. `docs/dispatch-contract.md` lists the canonical halt_reason values.
7. No files outside the deliverables set are modified — except this stage card itself.
8. Publish-guard pre-push hook passes.

## Out of scope

- Auto-clearing halts after a configurable cooldown.
- Per-cap-type backoff strategy.
- UI/CLI change to `autometta status` to show the halt reason more prominently (small follow-up, separate card).

## Budget

- **Worker wall-clock:** 25 minutes
- **Verifier wall-clock:** 10 minutes

## Verifier handoff

Worker returns:

- Commit SHA(s).
- The four canonical `halt_reason` strings chosen for the cap-hit paths.
- The two scenario-test outputs (dirty-tree-already-halted vs real-tick-cap).
- One-line confirmation that no `git commit` was invoked from the worker phase.

## Family-specific notes

- Codex worker: `</dev/null` stdin redirect; **do not run `git commit`**.
- Claude verifier: cross-family. Confirm the four halt_reason strings cover all branches reachable from `budget_check_caps`.
