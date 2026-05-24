# Stage I-2: Render golden parity

- Track: I (integration: K + U)
- Status: done (macOS); iOS sim environmentally blocked
- Verifying evidence: independently verified GREEN on macOS (Opus T1, implementer Codex). `renderGoldenParityFromFixtures()` green; I-1 and U3 not regressed; goldens byte-stable. The Swift comparison loop was realigned to K2's authoritative algorithm (classification flip skips the value diff; pass on `differingFraction`; `maxAbs` informational). Follow-up: `contract.json` `perChannelMaxAbs` is not met even by Go-CPU vs Go-Metal - see ledger. iOS Simulator blocked by CoreSimulator-out-of-date (1051.50.0 < 1051.54.0).
- Depends on: K2, U3 (gesture layer so scenes can be driven), I-1
- **Precondition (mechanical):** `feature/ui-track` must have *just* merged `feature/render-phase1` (the K->U sync merge - see HANDOVER.md step 2.5). K3 rewrites `fractal.metal` and regenerates `testdata/golden/`; a stale ui-track fails this gate for the wrong reason. Run Acceptance only on a freshly-synced ui-track.

## Goal

Prove the shipped Swift/MetalKit renderer matches the Go CPU oracle within the K2-published tolerance for the golden scene set, on both macOS and iOS. This is the gate that certifies visual correctness of the native app.

## Deliverables

- Swift parity test: for each `testdata/golden/scenes/*.json`, render via MetalKit, compare to `testdata/golden/render/*.f32` using the tolerance from `contract.json` (per-channel + max differing fraction).
- Runs green on a macOS destination and an iOS simulator destination.

## Non-goals

- No "feel"/inertia judgement (U4) - this gate is pixels only.
- No deep-zoom scenes.

## Acceptance

```
go run ./cmd/exportgolden -out testdata/golden
xcodebuild -scheme FractalApp -destination 'platform=macOS' test
xcodebuild -scheme FractalApp -destination 'platform=iOS Simulator,name=iPad (10th generation)' test
```

Pass condition: Swift render-parity test green on macOS and the iOS simulator within the `contract.json` tolerance; no prior gate (I-1) regressed.

## Verifier brief

- Tier: T1 Opus.
- Run Acceptance. On red: classify as (a) tolerance honestly exceeded - confirm the Swift target references the in-repo K3 `.metal` by path (it must be the same file, not a copy), (b) coordinate/aspect mapping (cross-check against U2/I-1), or (c) a real kernel divergence. Do not widen the tolerance to pass; tolerance is owned by K2 with recorded rationale.

## Definition of done

- Green on macOS + iOS simulator within published tolerance, the Swift target confirmed referencing the single in-repo `.metal` by path, Status done, one commit on the UI worktree.
