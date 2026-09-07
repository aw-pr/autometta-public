# Handover

**Status (2026-09-07 02:45):** Batch 108-131 is at **100 completed, 6
pending**, and the loop is **halted on the token cap** (`state/budget.json`:
`halted: true`, `halt_reason: token-cap`, spent 602984034 against a cap of 600000000). The
23:05 drain that raised the cap to 700M expired and spend is now over the
600M base. Nothing is in flight. Raising the cap is a spend decision and was
left for you.

## Do these first

1. **Merge 108 by hand.** It PASSED and is the only stage still awaiting
   integration. It conflicts with 114 in `scripts/tick.sh` -- one hunk, the
   network gate against the profiling change, both on the dispatch path.
   Branch `autometta/108-a-dead-network-does-not-spend-a-dispatch`, pushed.
   This was deliberately not resolved headlessly.
2. **Decide the token cap.** Six cards remain: 121, 122, 123, 129, 130, 131.
3. **Fix 120's integration record.** State says `awaiting`; it is merged.
   The tick wrote the record before the manual merge. Cosmetic only.

## What happened overnight

- **The state directory was wiped at ~21:16 and recovered.** A `git add -A`
  in a run worktree committed the load-bearing `state` symlink to dev; the
  next checkout replaced the real directory with it, taking `state.yaml`,
  `budget.json`, the verifier artefacts, the cost log and every dispatch
  log. Recovered from the `autometta/state` snapshot branch (`eceb200`,
  21:16:19). **Artefacts, `state/logs/` and `state/cost-log.jsonl` did not
  come back** -- they are not on that branch. Fixed on dev at `4c7327f`.
  Never stage a wildcard in a run worktree.
- **The Codex approval-prompt fix landed and is confirmed in production.**
  `codex exec` has no `--ask-for-approval` flag, so the operator's
  interactive `approval_policy` reached headless dispatches and waited for
  an answer nobody was there to give, surfacing as "timed out negotiating
  with the code-mode host". Every codex route now pins the policy itself.
- **Codex weekly hit 95%** at 01:59 and resets 09:43. Cards 118, 120 and
  122 were re-seated to Claude Opus 5 per standing instruction. **All three
  lost cross-family verification** -- their workers are Claude Sonnet 5.
  Each card says so and marks itself for re-verification on a Codex seat.
- **Four stages failed or nearly failed on one card defect**: 113, 115, 116
  and 118, all on the Contract test section telling the *worker* to author
  its own frozen block and digest, which `docs/dispatch-contract.md:131`
  forbids. **Card 131 fixes it and is the highest-value card left.**
  Note that stage 124 landed with a worker-authored contract test for this
  reason; read its verdict knowing that.
- **115's attempt-2 verdict was destroyed in the wipe.** Its work was on dev
  already; re-checked by hand (gate clean, digest matches, smoke passes) and
  marked completed. It is the one landed stage tonight with no surviving
  verifier artefact.

## Known defects surfaced but not carded

- **A `state_apply_json` write race.** Two verifiers dispatched together
  clobbered one another's `verifier_pid`; unnoticed, the tick would have
  double-dispatched and burned an attempt. Same family as lessons.md
  gotcha 10.
- **The tick never reaches its orphaned-verdict scan while a current stage
  is active**, so a stage whose worker died after writing a PASS envelope
  sits `in_progress` indefinitely. This happened to 108, 110, 114, 116, 118
  and 120 tonight; all were dispatched to their verifiers by hand.
- **`state-branch-smoke.sh` section 8** ("a parked branch leaves the base
  checkout clean") fails on clean `dev` and has done since at least
  `51a3a3a`. It may be reading ambient repository state rather than its own
  fixtures -- probing it across commits in worktrees sharing one `.git`
  gave inconsistent results. Recorded on card 116.
- **Verifier attempt counters are not reliable for tonight.** Manual
  dispatches bypass the tick's accounting, so attempt counts understate
  what actually ran.

## Confirmed by three separate verifiers

Any staged file merely *mentioning* the marker tokens trips the gate's
"more than one frozen block" -- `docs/dispatch-contract.md` carries them in
an example and in prose. Any commit touching that file trips it regardless
of content, and no git hook invokes the gate so it does not block. Card 121
owns the fix; the reproduction is recorded there.
