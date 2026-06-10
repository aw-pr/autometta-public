---
name: decision-advisor-verifier
description: Fable-as-advisor verifier is design-only and deferred; SDK-only, opt-in, an addition not a replacement for cross-family verification.
metadata:
  type: project
---

We will document, not yet build, a Fable-as-advisor verifier variant: a cheap request model (Sonnet) consults Claude Fable 5 as an advisor at the decision point instead of running a frontier model for the whole verification. Decision: advisor over a full Fable verifier; SDK-only; opt-in and default off.

**Why:** The advisor confines frontier price to the one judgement that needs it, while the bulk read-heavy prompt runs at workhorse cost. `scripts/verify-sdk.py` already owns the Anthropic API path, the cacheable block, and cost-log output, so the variant is one request parameter plus a guard rather than a new transport. The #66714 ordering trap means Fable must be the advisor and never the request model, so the guard is load-bearing. Cross-family-by-default stays the gate; the advisor is internal to a verifier and does not replace the worker-against-verifier family split.

**How to apply:** See [`docs/design/advisor-verifier.md`](../docs/design/advisor-verifier.md). Implement only behind a flag, default off, with the ordering guard that rejects an advisor weaker than the request model before any API call. Gate to `auth.claude.mode: api`. Never propose this as the default verifier route.

**What would make us not do it:** advisor round-trip latency dominating tick budgets, or a cheap-request-plus-advisor pass proving less reliable than a single strong pass.
