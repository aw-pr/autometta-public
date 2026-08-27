# feedback: Codex workspace sandbox cannot reach or bind localhost ports, failing server-dependent verification

---
metadata:
  run:
    adopter: promo-flow
    date: 2026-07-30
    stage: 02-ai-charts-e2e-contract
    worker: claude-sonnet-5
    verifier: codex-gpt-5-6-luna
    category: environment
    backport_target: templates/verifier-prompt.md
---

**What happened:** A Codex verifier failed a Playwright-based acceptance criterion twice, both times as environment blockers, not code defects. Attempt 1: Playwright's `config.webServer` child exited early because a stray `next dev` held :3000. Attempt 2 (after the orchestrator fixed the server): the workspace-write sandbox could neither reach the healthy :3000 server nor bind a replacement (`listen EPERM`), while `curl` from the orchestrator's shell got 200 concurrently. Attempt 3 with `--sandbox danger-full-access` passed 6/6 immediately.

**Why:** The Codex workspace sandbox blocks localhost network access both directions. Any acceptance criterion of the form "test suite passes against a server on :port" is unexecutable for a workspace-sandboxed Codex seat.

**How to apply:** When a stage's acceptance criteria require reaching a local server, dispatch the Codex seat with the widened sandbox from the start and record the widening in the card's family-specific notes, or assign that criterion to a Claude seat. Also pre-flight the port: verify the intended server is the one listening on :3000 before dispatch, and prefer `reuseExistingServer` over letting Playwright spawn its own build.
