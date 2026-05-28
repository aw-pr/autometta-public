---
name: decision-verifier-rubric-schema
description: Why verifier artefacts now have a JSON Schema and a manual corpus validator.
metadata:
  type: project
---

# Decision: Verifier rubric schema

**Decision:** verifier artefacts are formalised in `schemas/verifier.json`, and SDK output is validated against that schema before being written.

**Why schema now rather than later:**

The SDK verifier is about to become a production dispatch route. At that point malformed verifier output is not just a prototype concern; it can mark a stage complete, failed, or stalled. The schema makes the contract explicit before the route is wired into `spawn-verifier.sh`.

**Why backward-compatible only:**

Historical CLI verifier artefacts are already useful evidence. The first schema must accept them unchanged so the repository can validate the current corpus without rewriting state history. Stricter fields can be added later as optional fields first, then promoted only with a migration.

**Why a separate validator script rather than CI:**

Autometta is a pre-alpha pattern library with no package manifest or test suite. A standalone `scripts/validate-verifier-artefacts.sh` keeps the check local, offline, and easy to run from an operator session without inventing a build system.

**Related:** [[decision-sdk-verifier-prototype]]
