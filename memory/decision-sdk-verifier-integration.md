---
name: decision-sdk-verifier-integration
description: Why spawn-verifier.sh uses a manifest flag + env override to select the SDK vs CLI route, and why this card does not mutate the autometta repo's own manifest.
metadata:
  type: project
---

# Decision: SDK verifier integration into spawn-verifier.sh (card 15c)

**Decision:** `scripts/spawn-verifier.sh` adds an SDK route for the claude family, selected by a per-repo manifest flag `verifier.claude.transport` (values: `sdk` | `cli`, default `cli`). An env override `AUTOMETTA_CLAUDE_TRANSPORT` takes precedence over the manifest.

**Why manifest flag rather than per-card:**

Per-card transport would require a new field in the stage card schema and a parser in every dispatch script. The manifest is already the operator's per-repo config surface. Transport is an infrastructure choice, not a stage-level choice: all stages in a repo benefit from the same route once the operator opts in, and rolling it back is a single manifest edit. Per-card flags also complicate the verifier handoff: the verifier would need to know which route to invoke, leaking transport concerns into the card format.

**Why `cli` is the default fallback:**

Zero behavioural change for any repo that does not opt in. The existing `claude -p` path is tested, budget-accounted, and observed by the heartbeat. Defaulting to `sdk` would silently change the dispatch for every subscribed repo without the operator installing the SDK package or configuring api mode. The fallback also activates when `verify-sdk.py` is missing, guarding against partial deploys.

**Why no per-family flag for codex:**

Codex workers and verifiers already use `codex exec`, which is the Codex equivalent of a subprocess dispatch. There is no Codex Agent SDK that parallels the Claude Agent SDK; the only available mechanism is `codex exec`. Introducing a codex transport flag would add dead configuration surface with no implementation path.

**Why this card deliberately does NOT mutate the autometta repo's own manifest:**

The autometta repo's `.autometta.local.yaml` is gitignored and operator-controlled. If the card mutated it to set `verifier.claude.transport: sdk`, then the verifier dispatched to verify 15c would itself run via the SDK route, creating a circular dependency: the thing being verified is the SDK route, and the verification of that thing uses the SDK route. A failure in the SDK implementation would produce a FAIL artefact via the SDK, making it impossible to distinguish an implementation bug from a verification bug. The card is verified by Codex (cross-family), and the claude-family verifier (if used) is explicitly instructed to use the default `cli` route via env override. The operator may opt the autometta repo into `sdk` transport after 15c is committed and independently validated.

**How to apply:**

When a repo opts in by setting `verifier.claude.transport: sdk`, it must also set `auth.claude.mode: api`. These two flags travel together. The fail-closed check in `spawn-verifier.sh` enforces this pairing at dispatch time.

**Related:** [[decision-sdk-verifier-prototype]], [[decision-auth-route-toggle]]
