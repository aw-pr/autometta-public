# Fractals stage cards: imported artefacts

The files in this directory are imported verbatim from the `fractals-from-the-90s` source project. They predate the autometta templates and are not expected to conform to them. They are kept as historical artefacts: real stage cards from a real project, included here so readers can compare how the dispatch contract pattern looks in production against the templates autometta ships.

The two template files (`STAGE-TEMPLATE.md`, `WORKER-PROMPT-TEMPLATE.md`) are also imported verbatim from the source project. Comparing them with `../../templates/stage-card.md` shows how the autometta template generalised what the fractals project had already evolved to in practice.

---

## The four imported cards

### K1-perturbation-kernel-and-contract-v2.md

Series: **K** (kernel / architect work)

Source: `fractals-from-the-90s/docs/stages/K1-perturbation-kernel-and-contract-v2.md`

**Why chosen.** K1 is the most substantive kernel card in the deep-zoom phase: it carries a `nav.ContractVersion` bump, two new golden scenes, a perturbation evaluator, a glitch-detection pass, and a re-seed loop, all gated behind a byte-stability check on existing shallow scenes. It illustrates the dispatch contract's stage-card authoring step (step 1 in `docs/dispatch-contract.md`) at full complexity: inputs are explicit, deliverables are numbered and concrete, acceptance criteria are machine-checkable commands, and out-of-scope items prevent scope creep.

**What it illustrates about the dispatch contract.** The contract bump escalation note in the Verifier brief is a direct expression of the sandbox-as-role-boundary principle (`docs/dispatch-contract.md`, "Sandbox-as-role-boundary"; `docs/lessons.md`, "Headless gotcha 4: sandbox-as-role-boundary"): the worker cannot self-authorise a version-constant change; it must pause for human sign-off. The two-loop correction cap and the escalation path in the Verifier brief mirror the protocol in step 5 and step 6 of the dispatch contract.

---

### U2-swift-nav-mirror.md

Series: **U** (UI / coder work)

Source: `fractals-from-the-90s/docs/stages/U2-swift-nav-mirror.md`

**Why chosen.** U2 is a tightly scoped UI card: one Go module reimplemented in Swift, with an explicit list of formulas, a single `xcodebuild` acceptance command, and a short verifier brief naming exactly which formula details to check on red. Its brevity makes the card structure easy to read.

**What it illustrates about the dispatch contract.** The non-goals section ("No native gesture recognisers yet (U3). No reading of Go goldens yet (I-1).") shows the principle from step 1 of `docs/dispatch-contract.md` that "anything the worker needs to know that is not in the card is a contract violation" -- but equally, anything not in the card is out of scope. The Verifier brief names specific culprits to check on red (`aspect = height/width`, pixel-centre `(p+0.5)`), illustrating the verifier handoff detail recommended in step 5 of the contract.

---

### I-2-render-golden-parity.md

Series: **I** (integration / cross-cutting work)

Source: `fractals-from-the-90s/docs/stages/I-2-render-golden-parity.md`

**Why chosen.** I-2 is an integration card that spans two tracks (K and U) and two platforms (macOS and iOS), with a mechanical precondition (a branch sync that must have happened before the acceptance command is run). The card records an environmental blockage (CoreSimulator version mismatch) in the Status line rather than silently marking the stage green.

**What it illustrates about the dispatch contract.** The mechanical precondition is a concrete example of the card-sync race (`docs/lessons.md`, "Headless gotcha 2: card-sync race"): running the acceptance command on a stale worktree would fail for the wrong reason. The verifier brief explicitly bans widening the tolerance to buy green, which maps to the acceptance command integrity rule in step 4 of `docs/dispatch-contract.md`. The iOS blocker and the ledger follow-up note illustrate the verifier handoff (step 5) done correctly: a partial green is reported with evidence rather than promoted to a full pass.

---

### U-FIX-2-test-isolation-hardening.md

Series: **U-FIX** (recovery card -- stage that emerged from a prior-stage regression)

Source: `fractals-from-the-90s/docs/stages/U-FIX-2-test-isolation-hardening.md`

**Why chosen.** U-FIX-2 is a recovery card: it exists because earlier conformance stages left a latent test-isolation bug that only surfaced under repeated runs. The card was re-scoped mid-flight after two investigative loops hit the two-correction cap, producing a new card (U-FIX-3) for the residual race. This is the pattern described as gotcha 5 in `docs/lessons.md` ("Headless gotcha 5: prior-gate regressions"): a stage that appeared green broke an earlier gate under load.

**What it illustrates about the dispatch contract.** The re-scoping note in the card body is what step 6 of `docs/dispatch-contract.md` ("Orchestrator integration") looks like when the orchestrator finds that neither the diff nor the verifier report is sufficient to call the stage done -- the scope is narrowed to what was structurally correct, and the residual work is promoted to a new card rather than silently declared out of scope. The "at most 2 self-correction loops then escalate" rule appears verbatim in the card, directly mirroring the failure-budget protocol from step 6 of the contract. The "implementer != verifier holds" note in the Verifier brief is an instance of the cross-family verification default stated in step 5 of `docs/dispatch-contract.md`.
