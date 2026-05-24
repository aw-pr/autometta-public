# Stage U-FIX-2: settleForTesting() synchronicity (was: residual flap)

- Track: U (UI), hardening
- Status: done (re-scoped after loop 2)
- Depends on: U-deep landed; does not block I-4 (I-4 absorbed flap via xcodebuild test retries)

## Re-scoping note (2026-05-21)

Original card aimed for "20/20 consecutive runs green" on the full conformance suite. Two investigative loops were spent (see `docs/agents/runs/hardening-phase/U-FIX-2-test-isolation-hardening/`):

- Loop 1 (Claude Opus 4.7): leaked UserDefaults plists. Disproved
  - fix held plist count steady but did not move the 20-run gate (still 18/20 RED).
- Loop 2 (Codex GPT-5.5): `settleForTesting()` was fire-and-forget cancellation of pending Coordinator Tasks; the test then read state that those Tasks would still mutate after return. Worker lifted the helper to `async`, awaited each cancelled task's `.value`, then forced HUD/renderer refresh and `UserDefaults.synchronize()`. Test sites that read state after settle (u7, u8, uDeep) became `async throws`. **Cut u8 failures from 16/20 -> 12/20**; shifted the remaining u7 failure from the undo-restoration assertion to the bookmark-jump assertion (a deeper, separate race in `Coordinator.jumpToBookmark`).

The loop-2 change is structurally correct independently of the flap count: a fire-and-forget `cancel()` on Tasks the test then races against is a latent bug that was always going to bite. Per card protocol ("at most 2 self-correction loops then escalate") and per user direction, this card is **re-scoped to that structural fix and marked done**; the residual flap (bookmark-jump race) graduates to its own card, **U-FIX-3**.

## Goal (re-scoped)

`settleForTesting()` must not return until every Coordinator-side Task it cancels has actually finished, and any persistence write it triggers has been flushed. The prior fire-and-forget pattern is banned: no production code may schedule async coordinator work that the test helper cannot drain.

## Deliverables

- `settleForTesting()` is `async`. It cancels pending tasks, awaits their `.value`, and synchronises the persistence defaults before returning. (`apple/FractalApp/FractalApp/FractalMetalView.swift`.)
- A private `cancelTransientTasks()` shared by `settleForTesting()` and `Coordinator.close()` (the latter cancels but does not need to await, matching its shutdown role).
- Test sites that read state after a coordinator mutation use `await c.settleForTesting()`. Affected tests: u7, u8, uDeep (and any others that called the helper).
- No K-track changes. No `nav.ContractVersion` change. No new conformance tests.

## Non-goals (re-scoped)

- Not a flap-elimination card - that's U-FIX-3.
- No MTKView lifecycle work.
- No restructuring of `jumpToBookmark`/`undo`/`redo` internals beyond what is needed for the drain.

## Acceptance (re-scoped)

```
# Structural: confirm settleForTesting is async and tests await it
git grep -n "func settleForTesting() async" apple/FractalApp/FractalApp/FractalMetalView.swift
git grep -n "await c.settleForTesting()\|await source.settleForTesting()\|await restored.settleForTesting()\|await bootstrap.settleForTesting()" apple/FractalApp/FractalAppTests/FractalAppTests.swift
! git grep -n "settleForTesting()" apple/FractalApp/FractalAppTests/FractalAppTests.swift | grep -v "await"

# Behavioural: u8 failure rate reduced from baseline 16/20 to <=12/20
# (measured at loop-2 close; further reduction is U-FIX-3 territory)
cd apple/FractalApp
RUNS=20; FAILS=0
for i in $(seq $RUNS); do
  xcodebuild -scheme FractalApp -destination 'platform=macOS' -quiet test 2>&1 \
    | grep -q "u8PersistenceSchemaVersionConformance_macOS()' failed" && FAILS=$((FAILS+1))
done
[ $FAILS -le 12 ]
```

Pass condition:
- `settleForTesting()` is `async`; every call site in the test target is prefixed with `await`.
- u8 failure rate <= 12/20 (loop-2 measurement; structural fix produces this on macOS 26.5 / Xcode 26.5).

## Verifier brief

- Tier: T1 Opus runs the Acceptance commands verbatim.
- On red on the structural check: the change was reverted or only partially applied - fail and escalate.
- On red on the behavioural check: u8 rate above 12/20 indicates the loop-2 changes regressed (e.g. await missing on a critical settle) - fail and inspect.
- Implementer != verifier holds. Loop 2 implementer (Codex GPT-5.5) does not verify.

## Definition of done

- Both Acceptance checks green, one focused commit on `feature/ui-track` authored as Codex GPT-5.5, card Status set to `done` with multi-line "Verifying evidence" note pointing at the loop-1 and loop-2 archives.
- HANDOVER known-issues list: U-FIX-2 entry removed; **U-FIX-3 added in its place** (residual u7/u8 flap via bookmark-jump race).
- U-deep stage card "Verifying evidence" note unchanged for now (the "known residual flap" wording stands until U-FIX-3 lands).
