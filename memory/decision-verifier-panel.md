---
name: decision-verifier-panel
description: Why N=3 panel verifier, majority vote, fixed composition, opt-in default — stage 18 decision memo
metadata:
  type: project
---

Panel verification was introduced in stage 18 as an opt-in route for high-stakes stages. The design choices below are decisions, not preferences — changing them needs an explicit conversation.

**Why N=3 not N=5**

Three panellists already catches the most common failure mode (one verifier with an idiosyncratic rubric reading). Five would triple the cost again for marginal reduction in variance. Quorum of 2/3 is simple to reason about. Expand to N=5 if three-way ties become a recurring problem.

**Why majority not unanimity**

Unanimity blocks on any single over-strict verifier, recreating the same problem the panel is meant to solve. Majority preserves the value of independent opinions while allowing one disagreement.

**Why fixed composition for v1**

Per-card panel composition (choose your own models) adds significant implementation complexity — auth routes, prompt templates, and the aggregation schema all need to be parameterised. Fixed composition ships now; configurable composition is a separate future card if it proves necessary.

**Why opt-in not default**

Panel cost is roughly 3x a single verifier. Applying it by default would triple verification costs across all stages, most of which do not need the extra confidence. The operator knows which stages are high-stakes; the card metadata is the right place to record that judgement.

**Why [[decision-handoff-envelope]]**

The panel treats a missing artefact (panellist crash) as no-vote rather than FAIL because the handoff envelope contract means a completed panellist always writes its artefact. A missing file is therefore a signal of infrastructure failure, not a verdict.

**How to apply**

Set `Verifier panel: true` in the stage card Metadata, or export `AUTOMETTA_VERIFIER_PANEL=1`. For high-stakes stages only.
