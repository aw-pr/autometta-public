---
name: project-branch-archive-2026-11-12
description: Pruned autometta branches, including every wip/* attempt the ledger names, live in a git bundle under ~/.autometta/archive
metadata:
  type: project
---

On 2026-11-12, with the operator's approval, autometta was pruned to three
local branches: `dev`, `publish` and `autometta/state`. Origin keeps `dev` and
`publish`. The 56 deleted local branches were written first to
`~/.autometta/archive/autometta-branches-2026-11-12.bundle`, verified, and
restored in a scratch clone. A sibling `.txt` lists each branch with its sha
and last commit date. The 16 deleted origin branches (15 `autometta/<stage>`
run branches and `phat-controller/state`) were already contained in `dev`.

What the bundle holds that exists nowhere else: 43 `wip/*` earlier attempts of
stages that later landed, `backup/58-preintegration`, and the retired
controller's `phat-controller/state` snapshot history (last 2026-08-24).

**Why:** completed stages in `state/state.yaml` still carry `wip_branch:`
fields naming those attempts. Without this note the branch looks lost.

**How to apply:** to read a pruned attempt, fetch it from the bundle rather
than concluding it was never preserved:
`git fetch ~/.autometta/archive/autometta-branches-2026-11-12.bundle
refs/heads/wip/<name>:refs/heads/wip/<name>`. Never prune `autometta/state`;
it is the tick's recovery path (see `docs/lessons.md` gotcha 10).
