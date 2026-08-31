---
name: decision-per-role-family-sdk-transport
description: Transport selection is per role and family; Codex verifier SDK support reuses CODEX_HOME auth while orchestrator SDK work remains gated by card 23.
metadata:
  type: project
---

# Decision: per-role, per-family SDK transport (card 28)

**Decision:** verifier transport is selected independently through
`verifier.claude.transport` and `verifier.codex.transport`, each defaulting to
`cli`. The Claude route keeps `scripts/verify-sdk.py`; the Codex route uses
`scripts/verify-sdk-openai.py` and the official `openai-codex` SDK.

**Why:** the SDK wraps the Codex harness and therefore honours its own
authentication resolution. For Codex, the chosen `CODEX_HOME` is the billing
boundary: chatgpt mode for subscription, apikey mode for API billing. The
spawner validates that relationship before dispatch so it cannot silently run
on the wrong route.

**What remains deferred:** `orchestrator.{claude,codex}.transport` is a design
surface only. A production SDK orchestrator is gated behind the card-23 verdict
and is not read by the tick or any spawner.

**How to apply:** set the relevant verifier family to `sdk`, install
`scripts/requirements-sdk.txt`, and use the matching auth route. For a one-off
comparison, use the family-specific `AUTOMETTA_*_TRANSPORT` override. A missing
or mismatched Codex `auth.json` fails closed rather than falling back.

**Related:** [[decision-sdk-verifier-integration]],
[[decision-sdk-controller-experiment]], [[project-codex-sdk-subscription-auth]]
