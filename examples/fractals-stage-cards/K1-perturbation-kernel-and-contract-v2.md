# Stage K1 (deep): Perturbation kernel + contract v2

- Track: K
- Status: done (loop 2: deep centres extended to >=80 decimal digits; unused perturbation sidecar stats removed)
- Depends on: K0 deep-precision orbit green

## Goal

Land deep-zoom rendering in the Go oracle and the shared Metal kernel per ADR 0006: a perturbation evaluator that takes the K0 reference orbit and computes per-pixel float32 deltas, a Pauldelbrot glitch detection pass, a bounded re-seeding loop, and the **first `nav.ContractVersion` bump since the navigation phase opened**. The contract bump is the headline event; it gates every downstream stage (U-deep, I-4) and is the cross-track break switch per `docs/VERIFICATION.md`. The bump is approved by ADR 0006; the implementer still escalates the actual constant change to the human before commit.

Output: a kernel that renders the existing shallow scenes byte-stably (no behaviour change there) AND renders two new deep golden scenes at 1e30 and 1e100 within the contract-v2 tolerance regime. The kernel single-source rule from K3 is preserved: `internal/render/metal/fractal.metal` remains the only `.metal` file in the repo.

## Deliverables

- **Contract v2 bump.** `nav.ContractVersion` increments from `1` to `2`. `testdata/golden/contract.json` adds high-precision coordinate fields alongside the existing float64 ones. Schema shape (string- based per ADR 0006 sub-decision 3; implementer picks the exact field names and documents them in `docs/contracts/navigation.md`): high-precision centre is encoded as one or two decimal strings (e.g. `centerXHi` + `centerXLo`, or a single `centerX` string with the float64 `centerX` retained as a coarse fallback). The contract doc records the names, encoding, and the JSON-precision audit result (some JSON parsers silently coerce long numeric literals to float64; this is why the field is a string).
- **Scene-schema extension.** `internal/scene` gains the high-precision centre fields; existing scenes round-trip without the new fields defaulting to the float64 centre. New JSON precedence rule documented in the contract: if the high-precision field is present it wins; otherwise the float64 centre is used (so shallow scenes do not regress).
- **Perturbation kernel.** `internal/render/metal/fractal.metal` extended for perturbation evaluation: the kernel takes the reference orbit (as a buffer of `float2`/`packed_float2`) and per-pixel delta seeds and computes the delta iteration. Existing shallow scenes route through the same kernel via a code path that degenerates to the current iteration when the orbit buffer is absent or trivial, so K3's single-source invariant holds.
- **Pauldelbrot glitch detection.** A CPU pass over the rendered tile in `internal/render` that returns a per-pixel glitch mask using the Pauldelbrot criterion (the classic `|Z+δ|² < threshold·|Z|²` style test). Threshold and details are the implementer's call, justified in the commit body. v2 BLA is explicitly out of scope (ADR 0006 defers it).
- **Re-seed loop.** When the glitch fraction over a tile exceeds a tolerance (default **1%**; the implementer may pick a different default if justified in the commit body per ADR 0006's open question), pick a new reference orbit centre from the glitched region, regenerate via K0, and re-render only the glitched pixels. Cap at **3** re-seeds (the implementer may revise with rationale); beyond the cap, mark the residual pixels with a documented sentinel rather than producing silent wrong data.
- **Two new deep golden scenes.** Add `testdata/golden/scenes/` entries at depths 1e30 and 1e100 (suggested names: `deep-elephant-valley-1e30` and `deep-spiral-1e100`; well-known deep-zoom landmark centres - implementer picks and records the centre, the depth, and the iteration cap in the scene JSON). Regenerate the golden render buffers with the new exporter pass. The four existing shallow scenes remain byte-stable.
- **Updated `testdata/golden/README.md`.** Describe the v2 schema additions, the deep-tolerance forward pointer (the actual deep tolerance number is I-4's gate; K1 only records what the perturbation evaluator measured during golden generation).
- **Ledger entry.** A `pivot` record in `docs/metrics/ledger.ndjson` noting the contract v2 bump and citing ADR 0006.

## Non-goals

- No Swift code, no `apple/FractalApp` changes. U-deep consumes v2.
- No I-4 parity work. Cross-language deep parity is its own stage.
- No new fractal kinds (Julia deep zoom optional if it falls out of the Mandelbrot work for free; otherwise defer).
- No editing of the existing shallow goldens beyond what is forced by the schema additions (and any forced rewrite must be byte-stable on a second pass per K1/K2 hygiene).
- No third-party AP dependency; the orbit still comes from K0's `math/big.Float` generator.
- No BLA, no series approximation, no perturbation v2 optimisations.

## Acceptance

Exact commands a verifier runs from the repo root:

```
go run ./cmd/exportgolden -out testdata/golden && git diff --quiet testdata/golden
go test ./internal/render/... -run 'Parity|Perturbation|Glitch' -v -count=1
go test ./internal/precision/... -count=1
go test ./...
```

Pass condition: after the K1 edits settle, the exporter is byte-stable on a second run (`git diff --quiet testdata/golden` clean); the perturbation and glitch tests are green for the two new deep scenes within the tolerance recorded into `contract.json` during this stage; the existing K2 parity tests remain green for the four shallow scenes (no shallow-path regression); the full Go suite is green; `nav.ContractVersion == 2` in source and in `testdata/golden/contract.json` and the two values agree; `docs/contracts/navigation.md` reflects the new fields; the ledger has the `pivot` record for the bump.

## Verifier brief

- Tier: T1 Opus. Numeric and schema judgement: (a) the perturbation tolerance recorded into `contract.json` must be defensible against observed delta drift on the deep scenes, not inflated to buy green; (b) the string-based centre encoding must round-trip through JSON without precision loss (no silent float64 coercion); (c) shallow scenes must be byte-stable, so the new fields must encode with `omitempty` or equivalent.
- Sandbox note (per `docs/HEADLESS-ORCHESTRATION.md`): Codex workspace-write can run `go test` and `go run`; the worker MUST NOT commit and MUST NOT run `xcodebuild` (sandbox blocks DerivedData). The orchestrator runs Acceptance outside the sandbox and commits.
- Contract bump escalation: any change to `nav.ContractVersion` is a human escalation per `docs/VERIFICATION.md`. The bump is approved by ADR 0006; the implementer still pauses for human sign-off on the exact source change before commit.
- On red, classify as (a) shallow goldens drifted -> real regression, reject; (b) deep tolerance too tight -> measure and justify a defensible figure in the commit body, do not relax until justified; (c) re-seed loop not converging within the cap on a known-good centre -> debug the glitch criterion before relaxing the cap; (d) schema field round-trips lossily through JSON -> switch encoding shape and re-audit. At most 2 self-correction loops then escalate.

## Definition of done

- Acceptance green, `gofmt`/`go vet -unsafeptr=false` clean (per K3), no shallow regression, contract v2 in source and goldens, ledger bump record appended, `docs/contracts/navigation.md` updated, card Status set to done, one focused commit on `feature/render-phase1` authored as the implementing agent.
