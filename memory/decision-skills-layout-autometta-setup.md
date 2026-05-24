---
name: decision-skills-layout-autometta-setup
description: agent-orchestrator stays as the general orchestration skill. A new sibling skill `autometta-setup` handles autometta-specific repo adoption. Both live in autometta/skills/.
metadata:
  type: project
---

The `skills/` directory inside autometta holds skills, plural. Two concerns, two skills:

1. **`autometta/skills/agent-orchestrator/`** (existing): general multi-agent orchestration pattern. Harness-agnostic, family-agnostic, applies to any multi-agent engineering task. The pass-1 dispatch contract is one specific instantiation of these patterns; the skill itself is broader. **Do not rename.** mcp-hub continues to symlink to it.

2. **`autometta/skills/autometta-setup/`** (to be authored): the autometta-specific repo adoption skill. Triggered by phrases like "set up autometta in this repo", "adopt the dispatch contract", "use autometta patterns here". Walks the operator through: choosing pass-1-only vs pass-1+2, vendoring (copy / symlink / git submodule), running the init scripts if pass 2 is wanted, authoring the first stage card from the template, optionally chaining to `repo-publish-guard-init`. mcp-hub should symlink to this too so it is globally available alongside agent-orchestrator.

**Why:** Surfaced during the handoff conversation at the end of the stage-6 dry run. Tony asked whether agent-orchestrator should be renamed to autometta given they now live in the same repo, and whether a setup skill was needed. The general-vs-specific split is the cleaner factoring: agent-orchestrator describes how to break work apart and dispatch; autometta-setup describes how to adopt this specific repo's contracts in another repo.

**How to apply:** Future stage authors the autometta-setup skill following the same conventions as agent-orchestrator (REFERENCE.md
+ SKILL.md, frontmatter with name + description + trigger conditions, body in the same prose style). Estimated stage 5d or later; not blocking pass-2 hardening.

Cross-reference: [[decision-loop-name-phat-controller]], [[decision-state-dir-per-repo]].
