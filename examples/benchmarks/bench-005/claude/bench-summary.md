# BENCH-005 - Claude lane (Opus orchestrator) - bench-summary

Worktree: `<worktree>/fractals-bench-opus` Branch: `bench/u-fix-4-opus` Forked from: `feature/autometta @ bd5b84f` Orchestrator: Claude Opus 4.7 (`claude-opus-4-7`). Run window: 2026-05-23 ~20:00-20:30 BST. Total wall-clock: ~27 min.

## Outcome

**Card status: escalated (2 loops exhausted).** Acceptance command prints `20` (target: `0`); 20/20 FLAP across the full 20-run `xcodebuild` loop. Loop-1 fixed the original U-FIX-3 bookmark-jump assertion (u7:740); loop-2 fixes did not converge the residual persist-vs-live consistency drift at u7:757 + u8:802/836/870/883. Per the brief's stop conditions ("Acceptance green OR 2-loop budget exhausted on the implementation card - then file an escalation note and stop, that is a valid bench outcome"), the bench run ended at the escalation note.

## Dispatches

| # | Step | Worker | Tier | Wall-clock | Tool | Result |
|---|---|---|---|---|---|---|
| 1 | Inventory (read-only Coordinator audit) | Claude Sonnet 4.6 | T2 | ~2:05 | Agent (general-purpose sub-agent) | 186-line `inventory.md`: 24-row async-source table, 18 mutation paths, SSOT shape sketch, 6 risk bullets |
| 2 | Stage card authoring | Claude Sonnet 4.6 | T2 | ~50s | Agent (general-purpose sub-agent) | `docs/stages/U-FIX-4-coordinator-ssot.md`, ~110 lines, follows `STAGE-TEMPLATE.md`, Acceptance command verbatim from brief |
| 3 | Loop-1 implementation | Codex GPT-5.3 (`codex exec`, codex-cli 0.132.0) | T1 | ~2:00 | `codex exec --sandbox workspace-write` | 152-line Swift diff, single `commitMutation` funnel + `pushCurrentSnapshotToHistory` + `committed()`/`settleForTesting()` alias |
| 4 | Loop-1 verification | Claude Opus 4.7 | T1 | ~30s (single-run probe + 1-run baseline stash comparison) | Bash + `xcodebuild` + `xcrun xcresulttool` | RED: u7:757 + u8:802/836/870/883 deterministic; u7:740 PASSED (target fix); baseline-compare confirmed regression, not pre-existing flap |
| 5 | Loop-2 implementation | Codex GPT-5.3 (`codex exec`) | T1 | ~72s | `codex exec --sandbox workspace-write` | 156-line Swift diff: `persist: false` inside init restore/seed (Cause A); single-snapshot capture + `persistSession(scene:)` + persist-before-refresh ordering (Cause B1+B2) |
| 5a | Orchestrator compile-fix patch | Claude Opus 4.7 | T1 | ~5s | Edit | 1-line patch: worker missed updating the dead-code `pushCurrentSnapshotToHistory()` call inside `applySnapshot(.., pushToHistory: true)` branch after renaming the helper signature |
| 6 | Loop-2 verification | Claude Opus 4.7 | T1 | ~4:36 (full 20-run loop) | Bash + `xcodebuild` | **20/20 FLAP. Acceptance FAIL.** |

Six dispatches total (counting the orchestrator compile-fix as a sub-step of dispatch 5, not a fresh dispatch). Four commits on the branch:

```
8221969 Opus      | U-FIX-4 escalation: loop-2 output, card status, HANDOVER swap
8bcc0a7 Codex5.3  | U-FIX-4 loops 1+2: Coordinator SSOT funnel (escalated)
37ffdf7 Opus      | U-FIX-4 loop-1 evidence + loop-2 brief
7c9904c Opus      | card: U-FIX-4 loop-1 brief for Codex implementer
cbced00 Sonnet4.6 | card: U-FIX-4 Coordinator SSOT refactor + inventory
```

Committer on every commit: the operator's canonical git identity (per the per-agent attribution rule in `~/.claude/rules/mcp-hub-dev-rules.md`). Per-agent author attribution preserved.

## Acceptance result

```
$ cd apple/FractalApp
$ for i in $(seq 20); do
    xcodebuild -scheme FractalApp -destination 'platform=macOS' -quiet test \
      || echo "FLAP run $i"
  done | grep -c FLAP
20
```

- u7:740 (the original U-FIX-3 bookmark-jump target) now PASSES on most runs - the refactor's intended outcome.
- u7:757 + u8:802 (`encode(session.scene) == c.sceneJSONData()` after captureBookmark): fail deterministically across runs.
- u8:836/870/883 (round-trip / fallback-to-default cases): fail on most runs, varying subset.

Suspected unresolved root cause: a `@Published` observer chain or `renderer.setViewport` interaction mutating `navigator` / `centerXHi` across the `committed()` await suspension point, between the funnel's `persistSession(...)` call and the test's subsequent `c.sceneJSONData()` read. Loop-2's structural fixes (single-snapshot capture; persist-before-refresh; persist: false inside init paths) are correct in themselves but do not cover this remaining surface. A U-FIX-5 follow-up with an explicit Combine-observer / renderer- feedback inventory as prerequisite is the recommended next move.

## Deviations from the dispatch contract

- **None material.** Card-sync race mitigated by committing each card + brief before dispatch. Worker stdin redirected from `/dev/null`. Codex sandbox set to `workspace-write` (cannot run `xcodebuild` or `git commit`) - enforces implementer != verifier as intended. Verifier (Opus) ran Acceptance outside the worker's sandbox. Stable log paths under `/tmp/codex-u-fix-4-loop{1,2}.log`.
- **One reconciliation:** loop-2 worker produced a compile-error diff (one missed call site after renaming a helper signature). Per the contract's step 6 ("orchestrator integration ... reads the diff and reconciles"), Opus applied a 1-line patch in a dead-code branch (`pushCurrentSnapshotToHistory(currentSnapshot())`) rather than re-loop the worker for a trivial mechanical fix. Documented in `loop-2-output.md` and attributed via the Opus co-author trailer on the Swift commit.
- Per-agent author attribution: `agent-whoami` returned `Codex GPT-5.3 <codex-gpt-5-3@local>` on this machine; that is the author of the Swift commit. Cards/briefs authored by Sonnet/Opus get their respective canonical identities.

## Two-family-invariant observations (for autometta memory)

- **Sandboxed worker self-report fidelity:** Codex GPT-5.3 self- reported both loop-1 and loop-2 as success ("no blocker; self-check passed"). Acceptance disagreed in both cases. The contract's load-bearing rule (implementer cannot run xcodebuild -> cannot self-verify -> orchestrator catches the overclaim) held. This is a clean instance of the sandbox-as-role-boundary property doing what it is meant to do.
- **Loop-2 mechanical incompleteness:** the worker renamed a helper signature but missed one call site in a now-dead-code branch. Cheap orchestrator-side patch was the right move (sub-30s) versus a third loop. Note for future briefs: when asking a worker to rename a helper signature, instruct it explicitly to grep all call sites of the OLD signature before returning, and to include the grep output in its self-check.
- **Inventory + card via Sonnet sub-agent was high-leverage:** the 186-line inventory drove loop-1 directly and was reusable verbatim in the loop-2 brief. Total Sonnet wall-clock for both doc steps ~3 min vs ~5-10 min if Opus had done it directly, with negligible quality loss. The established preference (Opus orchestrates, delegates doc/inventory to Sonnet, dispatches implementation to Codex) is corroborated by this run.

## Files of record

- Stage card: `docs/stages/U-FIX-4-coordinator-ssot.md` (status: escalated)
- Run evidence: `docs/agents/runs/hardening-phase/U-FIX-4-coordinator-ssot/`
  - `inventory.md`
  - `loop-1-brief.md`, `loop-1-output.md`
  - `loop-2-brief.md`, `loop-2-output.md`
- Coordinator diff: `apple/FractalApp/FractalApp/FractalMetalView.swift`
- HANDOVER update: `HANDOVER.md` Known-Issues entry swap (U-FIX-3 -> U-FIX-4)
