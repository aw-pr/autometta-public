# Stage U2: Swift viewport/nav mirror

- Track: U
- Status: done
- Depends on: U1

## Goal

Reimplement the thin navigation maths in Swift, mirroring `internal/viewport` and the `nav` contract exactly: normalised anchored zoom, pan-by-fraction, recenter, additive rotation, and a Swift `Navigator` mirroring `EngineNavigator`'s seed/apply/commit lifecycle.

## Deliverables

- Swift `Viewport` value type: `mapNorm`, `zoomAboutPoint`, `panByNorm`, `recenterAtPoint`, `rotate` - same formulas/sign conventions as `internal/viewport`.
- Swift `Navigator` + gesture value type mirroring `nav.Gesture` / `nav.GestureKind`; a `contractVersion` constant.
- Swift unit tests covering the same invariants as `RunConformance` (hand-written here; I-1 later replaces/augments them with the Go-exported golden cases).

## Non-goals

- No native gesture recognisers yet (U3).
- No reading of Go goldens yet (I-1).

## Acceptance

```
xcodebuild -scheme FractalApp -destination 'platform=macOS' test
```

Pass condition: the Swift nav/viewport unit tests pass, including an anchored-zoom point-fixity test at >=2 aspect ratios, pan round-trip, recenter, and additive rotation; `contractVersion == 1`.

## Verifier brief

- Tier: T2 Sonnet.
- Run Acceptance. On red, diff the Swift formulas against `internal/viewport` line by line - sign conventions and the `aspect = height/width`, pixel-centre `(p+0.5)` details are the usual culprits. Escalate if it disagrees with the Go spec rather than the test.

## Definition of done

- Acceptance green, formulas demonstrably match the Go spec, Status done, one commit on the UI worktree.
