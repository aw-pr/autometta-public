# Task Brief - BENCH-005

> Multi-stage Swift refactor (U-FIX-4 Coordinator SSOT) executed under the
> **autometta dispatch contract**, run twice in two isolated worktrees with
> different orchestrators. The thing being benchmarked is the *orchestrator's
> ability to drive autometta*, not raw single-shot code generation.

---

## Metadata

| Field | Value |
|-------|-------|
| Task ID | BENCH-005 |
| Date | 2026-05-23 |
| Source repo | fractals-from-the-90s (`feature/autometta` @ `bd5b84f`) |
| Source issue / PR | n/a - replaces escalated `U-FIX-3` per `docs/stages/U-FIX-3-bookmark-jump-race.md` |
| Tools to run | claude (Opus-as-orchestrator), codex (Codex-CLI-as-orchestrator) *(cursor + gemini lanes skipped - this is a meta-bench on orchestration, not raw code gen)* |

---

## Spec

Implement **U-FIX-4: Coordinator single-source-of-truth refactor** in the Swift app, by orchestrating one or more worker dispatches via the autometta dispatch contract. The goal is the structural fix U-FIX-3 escalated for: collapse the Coordinator's state-mutation graph (`mutateScene`, `applySnapshot`, `persistSession`, notification observers, Combine publishes) into a single owner with explicit, awaitable commit points, so that `settleForTesting()` reliably drains every transition.

The brief is deliberately multi-stage - a typical run is 3-5 dispatches:

1. **Inventory.** Read the Coordinator (`FractalMetalView.swift`) and enumerate every async work source (`Task { ... }`, `DispatchQueue`, `@Published`, Combine, notification observers). Produce a short note identifying the SSOT shape and the planned `await committed()` contract. *(Worker tier: T2 Sonnet or T2 Codex - doc + reading task.)*
2. **Design card.** Convert the inventory into a stage card under `docs/stages/U-FIX-4-coordinator-ssot.md` with one machine-checkable Acceptance command, deliverables list, non-goals, and verifier brief. *(Worker tier: T2.)*
3. **Implement.** Refactor the Coordinator per the card. Sandbox = workspace-write; worker may not run tests. *(Worker tier: T1 Codex.)*
4. **Verify.** Run the Acceptance command outside the worker's sandbox. If it fails, one re-loop is permitted within card scope. *(Verifier tier: T1 Opus or T1 Codex orchestrator.)*
5. **Commit + evidence.** Orchestrator commits with per-agent author attribution and writes per-loop brief/output under `docs/agents/runs/hardening-phase/U-FIX-4-coordinator-ssot/`.

Stop conditions: Acceptance green, or 2-loop budget exhausted (then file an escalation note like U-FIX-3's and stop - that **is** a valid run outcome and will be scored honestly).

---

## Constraints

- **Implementer != verifier.** No worker may run its own Acceptance command. Verifier runs outside the worker's sandbox. This is the load-bearing rule of the autometta contract.
- **Follow `~/.config/agents/dev-rules.md` for git attribution.** Commits: `git commit --author="$(agent-whoami)" -m "..."`. Committer is `anthonylwest`.
- **Per-loop brief + output archived** under `docs/agents/runs/hardening-phase/U-FIX-4-coordinator-ssot/loop-N-{brief,output}.md`. Sanitise home-dir paths before commit (`<repo>/`, `<home>/`).
- **Do NOT undo U-FIX-2's `settleForTesting()` async drain** - it is correct and load-bearing.
- **No K-track changes.** Go side stays untouched.
- **No new conformance tests.** Reuse the existing suite for Acceptance.
- **No `nav.ContractVersion` bump.** Stay on v2.
- **No publish-gate touching.** Working in private branches.
- **All work on `bench/u-fix-4-{opus,codex}` branch in your worktree.** Do not push. Do not merge to other branches.

---

## Definition of done

- [ ] `docs/stages/U-FIX-4-coordinator-ssot.md` exists, follows `docs/stages/STAGE-TEMPLATE.md`, contains a single machine-checkable Acceptance command.
- [ ] Coordinator refactored: a single owner of `RenderSceneState` + explicit `await committed()` (or equivalent named yield) that drains every transition path including `jumpToBookmark`.
- [ ] Acceptance passes: **zero "FLAP run" lines** over 20 consecutive runs of the full conformance suite - see Acceptance command below.
- [ ] At least one commit on `bench/u-fix-4-{lane}` authored via `agent-whoami` (not `anthonylwest`).
- [ ] Per-loop brief + output files exist under the runs/ path above.
- [ ] HANDOVER.md `Known issues` section: U-FIX-3 entry removed, replaced with a one-line U-FIX-4 done note OR an escalation note if the 2-loop budget was exhausted.
- [ ] A final `bench-summary.md` in your lane directory (`bench-marks/tasks/BENCH-005/{claude,codex}/`) summarising: number of dispatches, worker model(s) used per dispatch, wall-clock per dispatch, Acceptance result, and any deviations from the contract.

---

## Acceptance command

Run from the worktree root:

```bash
cd apple/FractalApp
for i in $(seq 20); do
  xcodebuild -scheme FractalApp -destination 'platform=macOS' -quiet test \
    || echo "FLAP run $i"
done | grep -c FLAP
```

**Pass condition:** prints `0`.

---

## Context paste

### autometta dispatch contract (load-bearing reading)

Read `docs/dispatch-contract.md` (in the autometta repo) end to end before dispatching. The seven steps are:

1. Stage card authoring (orchestrator -> card on disk)
2. Worker prompt assembly (orchestrator -> prompt referencing card)
3. Worker dispatch + sandbox (worker -> deliverables inside sandbox)
4. Acceptance command (verifier -> pass/fail outside sandbox)
5. Verifier handoff (verifier -> structured report)
6. Orchestrator integration (orchestrator -> diff read + reconciled)
7. Commit (orchestrator -> audit trail)

Family-specific notes for the worker live alongside the contract in the autometta repo. The prompt is short and stable; the card carries the variable content.

### U-FIX-3 escalation context (the problem U-FIX-4 inherits)

Pasted verbatim from `docs/stages/U-FIX-3-bookmark-jump-race.md`, escalation note + hypotheses:

> **Escalation note (2026-05-22):** Loop 1 (Codex GPT-5.5):
> notification-observer Task -> MainActor.assumeIsolated + applySnapshot
> one-shot RenderSceneState + persistSession synchronize. Cut suite FLAP
> 19/20 -> 13/20, but the applySnapshot refactor regressed undo/redo
> races. Loop 2: reinstated mutateScene in applySnapshot + added
> restoreSessionOrDefault read-side synchronize. Regressed to 19/20 -
> the mutateScene revert undid loop-1's bookmark fix. Both loops
> reverted; ui-track returned to `9ee6f5a` baseline. Pattern: the
> Coordinator's state-mutation graph (mutateScene, applySnapshot,
> persistSession, notification observers, Combine publishes) is wired
> such that fixes trade one assertion failure for another. A structural
> refactor (single source of truth + explicit `await committed()`
> yielding only when the derived-state graph is up to date) is the right
> move but exceeds 2-loop card scope.

Failure shape on a 20-run macOS baseline (before U-FIX-4):

- `u7StateConformance_macOS` ~17/20 fails on `c.sceneJSONData() == bookmarkScene` after `captureBookmark -> pan -> jumpToBookmark -> settle`. The bookmark-jump path is not draining through the same Task graph the loop-2 settle drains.
- `u8PersistenceSchemaVersionConformance_macOS` ~12/20 fails on `restored.sceneJSONData() == expectedScene` round-trip. UserDefaults cross-process state suspected, OR the schemaVersion v0/v1 migration is racing.

### Where the code lives in the worktree

- Coordinator: `apple/FractalApp/FractalApp/FractalMetalView.swift` (the `Coordinator` nested class - contains `settleForTesting()`, `jumpToBookmark`, `persistSession`, `mutateScene`, `applySnapshot`, Task fields like `inertiaTask`, `zoomTask`, `hudFadeTask`, `controlsDismissTask`).
- Conformance tests: `apple/FractalApp/FractalAppTests/FractalAppTests.swift` (`u7StateConformance_macOS`, `u8PersistenceSchemaVersionConformance_macOS` are the flapping ones).
- Stage cards live in `docs/stages/`. Template: `docs/stages/STAGE-TEMPLATE.md`. Existing fix-track cards (U-FIX-2, U-FIX-3) are the closest precedent.
- Run-evidence path: `docs/agents/runs/hardening-phase/<STAGE-ID>/loop-N-{brief,output}.md`.
- HANDOVER.md (repo root) "Known issues" needs updating at the end.
- Adopted autometta orientation: `AUTOMETTA.md` (repo root). The dispatch contract canonical source is the autometta repo above.

### Worker tier guidance

Per `~/.config/agents/dev-rules.md` and `docs/HEADLESS-ORCHESTRATION.md`:

| Tier | Typical worker | Use for |
|---|---|---|
| T2 Sonnet / T2 Codex | Sonnet 4.6, Codex 5.2 | doc reading, card authoring, inventory writing |
| T1 Codex | Codex 5.3-codex | mechanical implementation against a card |
| T1 Opus | Opus 4.7 | verifier when judgement is on the line |
| Reserve | GPT-5.5 | design-reasoning side calls only |

The orchestrator chooses which tier to dispatch per step. Recording which tier you chose per dispatch is part of the bench-summary deliverable.

---

## Notes for the scorer

This is a **meta-bench**: we're not scoring whether the Coordinator refactor itself is good (any honest engineer can score that against the FLAP-rate Acceptance). We're scoring whether the orchestrator can drive autometta's dispatch contract cleanly.

Score using `rubric.md` with these per-dimension hints:

- **Correctness** - primarily the Acceptance result (`0` = score 5;
  >=1 = scale down). Also: did the orchestrator follow the contract's
seven steps, or skip / collapse some?
- **Iterations to working** - count loop attempts per stage card. Two loops max per card per autometta's verifier-budget rule.
- **Code / output quality** - the diff itself, but weighted with the *card + brief* quality (both are artefacts of the orchestrator).
- **Failure mode** - autometta says: a worker that hallucinates green is the worst outcome. Did the orchestrator catch any worker overclaim? Did the verifier run *outside* the worker's sandbox?
- **Autonomy** - interventions required from the human operator (you). Zero is the bar.
- **Time to acceptable result** - wall-clock from "orchestrator launched" to "Acceptance green or escalated". Include worker time.

The **two-family invariant** of autometta is also on trial here: asymmetric behaviour between the Opus and Codex orchestrators is a finding worth banking back into the autometta repo (`memory/`).

If one lane escalates and the other ships green, that is still useful data - record the escalation reasoning carefully.
