---
name: feedback-state-yaml-leaks-home-path
description: state.yaml's `repo:` field holds an absolute path, which conflicts with both publish-guard rules and the relative-paths-only contract for committed content.
metadata:
  type: feedback
---

`state/state.yaml` carries a `repo:` field set by `subscribe-repo.sh` to the absolute path of the subscribed repo (e.g. `<home>/repos/<project>`). The publish-guard correctly blocked committing this on its first real use during the stage 6 dry run.

This is a design-vs-policy conflict, not a script bug:

- `docs/phat-controller.md` section (b) states: "The file is created when a repo first subscribes... [it] is mutated only by tick.sh; humans may read but should not edit", implying the file is committed as audit trail.
- The global dev rule and the in-repo [[feedback-stage-card-paths-relative]] lesson both forbid baking absolute home-dir paths into committed content.
- The publish-guard `GUARD_PATTERNS` correctly blocks `<home>` substrings on pre-commit.

The three are individually correct and mutually inconsistent.

**Why:** First time `subscribe-repo.sh` and `tick.sh` had run end-to-end against real disk on a real machine. Static stage-5 / 5b verifiers checked schema validity but not publish-safety of the values that would actually be written. The publish-guard fired on the first attempted commit of state/, exactly its job.

**How to apply (three options, operator decides):**

1. **`state/` is gitignored.** Local-only state. The audit trail lives in the commit history on the `phat-controller/state` branch (the commits themselves carry the per-stage diff, timestamps, and author attribution). Pros: simplest, removes the conflict entirely. Cons: state.yaml is per-machine; a fresh clone has no prior tick history visible from the tree. Requires updating `docs/phat-controller.md` section (b) to describe state.yaml as runtime state, not committed artefact.

2. **Replace the absolute `repo:` field with a placeholder.** Set `repo: ${AUTOMETTA_ROOT}` (or `${PWD}` or a sentinel like `<repo-root>`), resolved at read time by tick.sh. State.yaml becomes committable. Schema update needed. Pros: keeps the audit-trail design intact. Cons: every state-yaml reader has to do the substitution; adds a small protocol.

3. **Drop the `repo:` field entirely.** Tick.sh already knows the subscriber's repo path from `~/.phat-controller/subscribers/<repo-slug>.yaml`; state.yaml does not need to carry it. Pros: removes the leak without needing a placeholder. Cons: schema change, makes state.yaml slightly less self-describing for humans reading it standalone.

**Temporary mitigation in place:** `state/` is gitignored as of this commit. The dry-run state files (state/state.yaml, state/budget.json) are uncommitted and local-only. Pick one of the three options before resuming stage 6.

**Provisional gap also identified:** budget.json holds `halted: true / halt_reason: yq-missing` from the dry run. There is no current mechanism in tick.sh to clear that state. A future `tick.sh --reset-halt` flag is the obvious fit; document under the implementation-parameters entry.

Cross-reference: [[feedback-stage-card-paths-relative]], [[feedback-stage-6-runtime-bugs]], [[decision-state-dir-per-repo]], [[decision-tick-implementation-parameters]].
