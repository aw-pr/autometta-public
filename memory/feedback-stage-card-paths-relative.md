---
name: feedback-stage-card-paths-relative
description: Every path in a stage card (Inputs, Deliverables, references) must be relative to repo root. Absolute paths break portability across clones, machines, and operators.
metadata:
  type: feedback
---

Every path written into a committed stage card must be relative to the repo root. Absolute paths (`/Users/YOURNAME/repos/autometta/...`) bake the directory location and the operator's home dir into the repo. They break the moment the repo is cloned elsewhere, re-cloned under a different name, or operated by a different user.

**Why:** Stages 0 through 5b were written with absolute path prefixes in their Inputs sections (46 occurrences across 8 cards). The renames from `autometa` to `autometta` and the directory move both required a sed across all those cards. A second operator cloning the repo into `~/code/whatever/` would have hit the same problem with no remediation path other than a sed they had to invent themselves. The global dev rule at `~/.claude/rules/mcp-hub-dev-rules.md` already states "Use relative paths inside the repo. Never embed `/Users/YOURNAME/...` or other absolute home-dir paths in committed code." The rule covers code; stage cards must be held to the same standard.

**How to apply:** When authoring a stage card, every path is relative to repo root. The stage-card template at `templates/stage-card.md` now carries a comment block above the inputs placeholder reminding the author. The orchestrator checklist at `templates/orchestrator-checklist.md` now carries a checkbox under section 1 that fails the dispatch if any input path is absolute. Workers should `cd` to repo root before reading.

Cross-reference for the external-repo case (stage 2 cited the fractals source repo by absolute path; that is a separate concern because the source repo is genuinely external and cannot be made relative to autometta's tree): mention but defer. If a stage card genuinely needs to reference a different repo, use a placeholder like `<source-repo-root>/path/...` and document the substitution in the card's family-specific notes.

Cross-reference: [[feedback-acceptance-criterion-stage-card-exemption]], [[feedback-verifier-prompt-mirrors-stage-card]].
