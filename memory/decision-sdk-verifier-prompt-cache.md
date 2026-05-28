---
name: decision-sdk-verifier-prompt-cache
description: Why and how prompt caching was added to the SDK verifier route — ephemeral TTL, static/variable split, anthropic library switch.
metadata:
  type: project
---

Prompt caching (Anthropic `cache_control: {type: "ephemeral"}`) was added to `scripts/verify-sdk.py` in stage 16.

**Why ephemeral (5 min) not 1-hour:** The 1-hour TTL requires an `extended-cache-ttl-2025-04-25` beta header and a higher minimum block size. The 5-minute TTL covers the phat-controller's tick interval (300 seconds) without requiring a beta opt-in, making it the safe default for a pattern library that needs to work out of the box.

**Why the schema is cached alongside the rubric:** `schemas/verifier.json` is stable within a session and required by every verifier call. Including it in the cached block raises the block above Sonnet's ~1024-token minimum and means the schema is not re-charged on repeat calls. Schema changes automatically bust the cache.

**Why the per-stage card is the cache-bust boundary:** The stage card and artefacts vary per dispatch, so they live in the variable (non-cached) block. The static block contains only content that is identical across all stages in a session. This gives the best hit rate on multi-stage tick runs.

**What changes invalidate the cache:**
- `templates/verifier-prompt.md` content changes
- `schemas/verifier.json` content changes
- Model change (cache is model-scoped in the Anthropic API)
- More than 5 minutes between calls (TTL expired)

**Why the switch to the `anthropic` library:** `claude_agent_sdk` does not expose `cache_control` on message content blocks. The `anthropic` library gives direct control over the messages array and usage response. `anthropic` is already a transitive dependency of `claude-agent-sdk`, so no new system dependency is introduced.

**Related:** [[decision-sdk-verifier-integration]] [[decision-sdk-verifier-prototype]]
