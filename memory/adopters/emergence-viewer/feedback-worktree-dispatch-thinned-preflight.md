# feedback: dirty-tree halt and sticky budget state replaced by worktree-per-run dispatch (pilot)

---
metadata:
  run:
    adopter: emergence-viewer
    date: 2026-08-14
    stage: 44-cycle-beam-parity
    worker: codex-gpt-5-6-terra
    verifier: claude-fable-5
    category: design
    backport_target: templates/orchestrator-checklist.md, templates/stage-card.md, scripts/tick.sh
---

**What happened:** Nightly runs kept dying on guard state rather than on real defects: the dirty-tree pre-flight halted dispatch over an uncommitted HANDOFF.md, and a `tick-cap` halt from a run three weeks earlier (`clock_ticks_used` 100/100) was terminal for every later window because `--reset-halt` clears the flag but not the counters. Separately, the retired one-shot pinned `expected_head` to a SHA ~50 commits stale, and a stale Codex auth file could kill a run at the worker step with nobody watching.

**Why:** The dirty-tree rule protects a *shared checkout* - the failure it prevents (trampling or dispatching over someone's WIP) disappears if the run never uses the shared checkout. Sticky counters and SHA pins are bookkeeping outliving the run that owned them.

**How to apply (piloted in ai-schedules `routines/emergence-viewer-stage-44.prompt.md`, stage card f6f18ed):**

- **Worktree per run.** Card declares `Base branch` and `Run branch` in its metadata. Dispatch does `git worktree add ../<repo>-run-<stage> -b autometta/<stage-id> <base>` (sibling path so `../emergence-lab`-style card inputs still resolve) and works only there. No dirty-tree check at all. On PASS: ff-merge into the base if it hasn't moved, else push the run branch and note it in HANDOFF. On FAIL: leave branch + worktree standing for inspection. Rollback = branch delete.
- **Budget window auto-reset.** At window start, a halted or at-cap `state/budget.json` is reset (counters zeroed, caps unchanged) with a log line, instead of halting the run.
- **Pin to branch, never SHA.** The run branch is cut from the base branch at fire time; no `expected_head`.
- **Codex seat: probe, don't refresh.** One trivial `codex exec` ping at dispatch; on failure the orchestrator implements the stage itself and records the substitution. Never attempt interactive login unattended. A cheap daytime heartbeat ping keeps the ChatGPT token refreshed while a human is around to see failures.

**Not yet thinned (candidates for the backport):** consolidate the triple enable-switch (subscriber `enabled` + plist `.disabled` + marker files) into one; gate the window on remaining subscription quota (`ai-schedules/bin/quota_claude.sh`) instead of discovering exhaustion mid-run; keep the consecutive-failure cap - it is the one guard that fires on real defects.
