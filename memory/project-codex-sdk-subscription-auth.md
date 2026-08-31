---
name: project-codex-sdk-subscription-auth
description: The official Codex SDK runs on ChatGPT-plan auth and returns per-turn usage; the openai and openai-agents libraries are key-only and the wrong surface
metadata:
  type: project
---

OpenAI ships an official Codex SDK that wraps the codex agent harness as a
library: `openai-codex` on PyPI (0.147.0, 2026-08-18) and
`@openai/codex-sdk` on npm (0.151.0, 2026-08-29). It reuses codex's own
auth resolution ("Existing Codex authentication is reused automatically"),
so a chatgpt-mode `$CODEX_HOME/auth.json` bills the plan exactly as
`codex exec` does; it also exposes `login_chatgpt_device_code()` for
headless boxes. `thread.run()` returns `ThreadTokenUsage`;
`runStreamed()` emits `turn.completed` with usage, and the app-server
surface underneath streams `thread/tokenUsage/updated` mid-turn.

**Why:** cards 28, 90 and 91 were first written against the `openai`
library, which is API-key-only, and nearly baked "codex SDK requires api
mode" into the transport matrix. The operator's instinct that the
subscription route existed was right (researched 2026-08-31, sub-agent
report in the session; sources: learn.chatgpt.com/docs/codex-sdk,
github.com/openai/codex sdk/ trees, pypi.org/project/openai-codex).

**How to apply:** for SDK-transport codex dispatches use `openai-codex`,
never `openai` or `openai-agents` (both key-only, no auth.json). Billing
mode is selected by CODEX_HOME: normal `~/.codex` bills the plan, the
api-only sibling bills the key - the inverse of [[lessons]] gotcha 8, so
verify the selected auth.json's `auth_mode` matches the resolved mode and
fail closed on mismatch. Usage caveats: SDK/exec-json usage objects are
cumulative session totals (diff, do not sum; openai/codex#17539), and
mid-turn passthrough of `thread/tokenUsage/updated` through
`TurnHandle.stream()` is unverified - check empirically before promising
live burn. Related: [[decision-per-role-family-sdk-transport]] (written by
card 28 when it lands).
