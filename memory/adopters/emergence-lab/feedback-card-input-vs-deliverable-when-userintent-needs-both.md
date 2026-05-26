---
name: feedback-card-input-vs-deliverable-when-userintent-needs-both
description: When user-visible intent spans files an orchestrator listed as input-only, the worker correctly stays in scope and the verifier correctly fails a "no files outside deliverables" criterion — but both decisions are individually right and the card is the bug.
metadata:
  type: feedback
  run:
    adopter: emergence-lab
    stage: 02-fractal-defaults-and-cycling
    worker_agent: codex-gpt-5-3
    verifier_agent: claude-sonnet-4-6
    pairing: cross-family
    outcome: verifier-fail-card-scope-contradiction
    operator_repair: orchestrator-hot-patch-claude-opus-4-7
    back_port: stage-card-template
---

Stage card `02-fractal-defaults-and-cycling` had two criteria that
turned out to be mutually impossible in the target codebase:

- **C3:** `paramSchema` of Mandelbrot/Julia kernels must show palette
  default `"inferno"`.
- **C6:** `/#/mandelbrot` and `/#/julia-set` must render in Inferno on
  first load with cleared localStorage.
- **C8:** No files outside the listed deliverables may be modified
  (with the stage-card exemption per
  [[feedback-acceptance-criterion-stage-card-exemption]]).

`docs/INTERFACE.md` in the target repo defines palette as a
renderer-owned concern (kernels emit `Float32Array`, the renderer
maps to colours via `colormap.ts`). The kernel `paramSchema` does
not — by design — carry palette defaults. So:

- The Codex worker correctly stayed within deliverables, shipped the
  kernel-schema changes (cycle speed default 2x, max 5), and skipped
  the palette default change because `src/app/colormap.ts` was listed
  as input but not deliverable.
- The Claude verifier correctly flagged C3 as a literal FAIL (palette
  is not in paramSchema and never could be without an
  `INTERFACE.md` bump) and C8 as a literal FAIL (the orchestrator
  hot-patched `colormap.ts` to land the user-visible intent, which is
  outside the deliverables list).
- The orchestrator hot-patch was the right operator move at runtime
  (the user wanted Inferno default and the verifier's findings make
  good audit trail), but it exposes a card-authoring failure mode
  that future cards in this and other adopter repos can repeat.

**Why:** The orchestrator drafted the card assuming "palette" lived
where similar tunables live (kernel paramSchema), without first
reading `colormap.ts` thoroughly enough to notice it owns the per-sim
palette default. The user-visible intent ("default to Inferno") then
crossed the kernel/renderer boundary, but the deliverables list did
not.

**How to apply:**

1. **Card authoring rule:** when an acceptance criterion is phrased
   in user-visible terms ("renders in Inferno", "shows a counter"),
   trace the rendering path before fixing the deliverable set. If
   the user-visible outcome requires touching files the card frames
   as "inputs", promote those files to deliverables or split the card
   into kernel-side and renderer-side stages.

2. **Verifier framing:** when the verifier finds a card-internal
   contradiction (criterion A requires file X, criterion B forbids
   modifying file X), the artefact should still record FAIL on the
   strict reading, but the `additional_findings` block should call
   out the contradiction so the orchestrator can fix the card rather
   than the worker.

3. **Worker stays in scope:** the correct worker behaviour is to ship
   the deliverables and leave the orchestrator to resolve any
   resulting acceptance gap. Do not interpret-and-expand deliverables
   in the field, even when the user-visible intent is obvious — that
   path leads to scope creep that the verifier cannot police.

4. **Operator-of-last-resort hot-patch is acceptable** but should
   produce a feedback entry like this one. Track it in commit history
   with author `<orchestrator-identity>` so it is distinguishable from
   the worker's commits.

Cross-reference: [[feedback-acceptance-criterion-stage-card-exemption]],
[[project-cross-family-verification-validated]].
