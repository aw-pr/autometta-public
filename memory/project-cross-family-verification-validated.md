---
name: project-cross-family-verification-validated
description: Cross-family verification earned its keep on the first stage. Same-family agents are blind to their own style failures; the other family is not.
metadata:
  type: project
---

Stage 0 of the self-host plan validated the cross-family verification belief on its first dispatch. The worker (Claude Sonnet) wrote prose that violated a stated style constraint; the orchestrator (Claude Opus) read the prose and did not notice; the verifier (Codex GPT-5.3) identified every violation with line-and-file citations.

**Why:** This is the load-bearing belief behind the "implementer != verifier" pattern in `docs/philosophy.md`. The principle was extracted from the agentic-rag-kimble pass-28/29 work but had not been independently re-tested in autometta itself. Stage 0 is the first re-test, and it produced the expected signal on the first try with a non-trivial fault.

**How to apply:** Keep cross-family pairing as the default, not a nice-to-have. Same-family verification can pass criteria the family has a shared blind spot for (in this case, "-" punctuation, where Anthropic models default to em dashes in well-formed prose). The contract should require an explicit rationale in the stage card if same-family verification is ever used.

Cross-reference: [[feedback-style-constraints-pre-check]].
