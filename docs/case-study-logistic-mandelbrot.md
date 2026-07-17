# Case study: Logistic Mandelbrot

On 17 July 2026, one operator prompt became a new interactive simulation in
Emergence Lab. Autometta split the request into five staged builds, paired each
worker with a verifier from another model family, and kept the work moving
through capacity failures, a model outage and one rejected acceptance
criterion. The initial run took about 4.5 hours, including a 50-minute model
availability pause.

The result plots the attracting orbits of `z -> z^2 + c` as height over the
complex plane. Its real-axis curtain is the logistic bifurcation diagram, while
the Mandelbrot set sits below as the ground plane from which the orbit sheets
rise.

## What "one-shot" means here

The operator supplied one creative brief for the initial build. It was not one
undifferentiated model call. The orchestrator translated that brief into five
small requirement cards, each with a named deliverable, an acceptance command
and a verifier from the opposite model family.

That distinction matters. The creative direction was one-shot, while the
delivery was staged and checked:

| Stage | Worker -> verifier | Delivered |
|---|---|---|
| 17 | Claude Fable 5 -> GPT-5.6 Sol | Orbit sampler, CPU reference kernel and 12 mathematical tests |
| 18 | GPT-5.6 Sol -> Claude Opus 4.8 | WebGL orbit point cloud, quality-scaled budgets and 2D fallback |
| 19 | GPT-5.6 Sol -> Claude Opus 4.8 | Orbit camera, picking and the c-plane marker |
| 20 | GPT-5.6 Sol -> Claude Opus 4.8 | Cascade reveal, real-axis sweep and real-slice mode |
| 21 | Claude Fable 5 -> GPT-5.6 Sol | Ground plane, presets, essay, gallery entry and thumbnail |

Fable returned for stage 21 after an outage. Opus filled the Claude verifier
slot for stages 18 to 20, showing that the card contract could survive a model
substitution without redesigning the work.

## What the models built

The simulation combines mathematical and rendering work that could be checked
separately:

- A reference sampler iterates each complex parameter past its transient and
  retains the attracting orbit.
- Tests encode the logistic conjugacy, including the period-two orbit at
  `r = 1 + sqrt(5)` and the mapped period-three window.
- A static CPU build feeds a WebGL point cloud in short slices so the interface
  remains responsive during construction.
- Point budgets scale from about 1.0 million to 4.8 million. The balanced
  profile rendered about 2.4 million points in the recorded browser check.
- The world mapping uses `Re(c)` and `Im(c)` for the ground plane, with orbit
  values as height. This makes the real slice a literal bifurcation curtain.
- The interactive layer adds an orbit camera, zoom, picking, a period marker,
  presets, a Mandelbrot ground texture and period-based colour.

## Verification changed the outcome

The run did more than produce a sequence of green checks.

The stage-17 verifier independently re-derived the period-two mapping rather
than trusting the worker's implementation. At stage 21, the first verification
failed because the card required an essay to render inside the app even though
the repository convention kept essays as documentation. The worker had
followed the codebase correctly. The card was wrong. The orchestrator amended
the criterion, recorded the amendment and ran verification again.

That failure is useful evidence for the pattern. Cross-family verification
checked both the code and the specification, and it refused to turn an
impossible criterion into a ceremonial pass.

The final gate reported all 240 kernel tests passing, a clean TypeScript check
and a successful production build. Browser checks confirmed the 3D renderer,
fallback path and existing simulations. The real-GPU release pass also checked
camera feel, clipping, animation and frame rate.

## Follow-up stages

The first real-GPU view exposed two issues that were hard to judge in a
software-rendered verifier session. Two more cards ran through the same worker
and verifier contract that evening:

1. Stage 22 replaced row-major truncation with deterministic sampling across
   the whole c-plane. The apparent clipping was missing geometry, not a camera
   problem.
2. Stage 23 added period, height and monochrome colour modes, with period colour
   selected as the default.

Their recorded worker and verifier times total about 35 minutes. This is
separate from the 4.5-hour figure for the five-stage initial build.

## Human taste and release pass

Once the staged build was mathematically and technically sound, the operator
asked for a final visual pass. GPT-5.6 Sol then:

- enlarged the bifurcation tracer and gave it a layered gold and white glow;
- fanned the tracer laterally across the complex plane and orbit sheets;
- looped the sweep after a short hold so the relationship remains visible;
- increased the point size and added a hazy halo, bright core and pale sparkle
  in the existing shader pass;
- added in-app guidance for pivoting and zooming in 3D;
- promoted the simulation on the Emergence Lab gallery and Promo Flow home
  page, paired it with the standard Mandelbrot card, and reused the operator's
  screenshot as the release image.

This pass is not included in the original 4.5-hour run time. It is the part
where human judgement moved from "correct" to "spectacular" after the verified
system had earned a stable base.

## Release path

The final source passed the full Emergence Lab verification gate and was moved
through the repository's deliberate release chain:

```text
dev -> main -> publish -> public/main
                    |
                    +-> static Vite export -> Promo Flow -> main
```

Before the public push, the release delta, tracked tree and full Git history
were scanned for credential-shaped values and private-tier files. A complete
Git bundle was created and verified. Promo Flow then passed TypeScript and its
237-page production build before its `main` branch was advanced.

## Figures for a write-up

- One operator prompt for the initial creative brief.
- Five stages in the initial build, plus two same-evening follow-up stages.
- About 4.5 hours for stages 17 to 21, including a 50-minute availability
  pause.
- Three frontier model roles across two families: Claude Fable 5, Claude Opus
  4.8 and GPT-5.6 Sol.
- 240 kernel tests in the final Emergence Lab gate.
- About 2.4 million points on the balanced rendering profile.
- One verifier rejection caused by a faulty requirement, followed by a recorded
  card amendment and a clean re-verification.

## What this case demonstrates

Autometta did not replace creative direction. It converted one piece of
direction into bounded work, made verification independent, and left an audit
trail detailed enough to explain where time went and why decisions changed.

The useful split was:

1. The human chose the object and judged whether it deserved release.
2. The orchestrator turned that intent into cards and handled incidents.
3. Workers implemented one bounded stage at a time.
4. Verifiers challenged the maths, code and acceptance criteria.
5. The human returned for the taste pass once correctness was established.

The full timings, incident record and commit chain are in the Emergence Lab
[run log](https://github.com/aw-pr/emergence-lab/blob/main/docs/runs/2026-07-17-logistic-mandelbrot-run.md).
