# memory/ - shared agent memory

This directory is the **in-repo** memory store for every agent working on autometta, regardless of family or harness. It replaces (for this repo only) the per-harness private memory directories:

- Claude Code's `~/.claude/projects/<slug>/memory/`
- Codex CLI's session-local notes
- Any future family's equivalent

The in-repo copy is authoritative. Do not mirror entries into harness-private memory for this project; future sessions in a different harness would not see them.

## Why in-repo

autometta is jointly maintained by Claude Code and Codex CLI sessions (see the `README.md` preamble). If memory lives in one harness's private directory, the other family is blind to it. Committing memory to the repo makes every agent - and every future clone - see the same state.

## File format

Same format as the global auto-memory system, so agents can read and write without learning a new convention:

```markdown
---
name: <short-kebab-case-slug>
description: <one-line summary used for relevance matching>
metadata:
  type: user | feedback | project | reference
---

<body - for feedback/project, structure as: rule/fact, then **Why:** and
**How to apply:** lines. Link related memories with [[their-name]].>
```

## Index

`memory/INDEX.md` is the one-line-per-entry index, equivalent to the global `MEMORY.md`. Keep entries terse (<=150 chars). Add a pointer whenever you add a memory file.

## What belongs here vs. what doesn't

**Belongs in `memory/`:**

- Decisions about autometta's design that aren't yet in `docs/`.
- Open questions and their resolution.
- Cross-family coordination notes (e.g. "Codex hit gotcha X in stage Y on 2026-05-21, see commit abc123").
- Project state that future sessions need but the code/git history doesn't capture.

**Does NOT belong here:**

- Anything already in `README.md`, `CLAUDE.md`/`AGENTS.md`, or `docs/philosophy.md`. Cross-reference, don't duplicate.
- Secrets, tokens, or absolute home-dir paths.
- User-profile memories (Tony's persona, voice rules) - those are global, kept in the harness-private store.
- Ephemeral task state (use a plan or task list, not memory).

## Stale memory

Memories can outlive the code they describe. Before acting on a memory that names a file path, function, or flag, verify it still exists. Update or remove the entry if it's wrong.
