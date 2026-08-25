# Lessons log: the 2026-08-24 to 25 self-host run

**Repo:** `autometta` (self-host)
**Window:** 2026-08-24 evening to 2026-08-25 morning, still open
**Status:** running log, not a finished incident write-up. Kept while the run is
live so the review at the end has evidence rather than recollection.

This is deliberately one document for the whole run rather than one per
incident. Several of the failures below look unrelated and are not: three of
them are the same mistake about **where a path resolves**, and two more are the
same mistake about **what "idle" means**. That pattern is only visible with them
side by side, which is the reason for the format.

Each entry records what happened, what it cost, and where the fix lives. An
entry with no card is an open hole.

---

## Landed in this run

54 (a warden pass minds the queue), 56 (phat-controller is the minder, not the
loop), 57 (the dash shows its lights, its agents, and its spend), 51 (docs catch
up with the free verifier pattern), 59 (the budget meters both providers), 58
(the controller decides, the scripts are its verbs, PASS at 06:56 UTC, awaiting
integration).

Cards written and not yet queued: 61, 62, 63, 64.

---

## 1. Relative paths, absolute readers, and one symlink holding it together

**What happened.** Every path handed to an agent is relative:
`spawn-verifier.sh` builds `state/verifiers/<stage>.json`, the worker prompt
names `state/handoffs/<stage-id>.json`. The agent resolves those against its own
working directory, which is the run worktree. Every reader resolves them against
`repo_root`. The symlink `ensure_run_worktree` plants at `tick.sh:805` is the
only thing making writer and reader agree.

**What it cost.** Stage 51's verifier returned a genuine PASS on all six
criteria. The artefact landed in the run worktree, the tick looked in the main
repo, found nothing, scored the verifier `aborted` and re-dispatched. Two of
three attempts were burned on a verdict that already existed.

**The compounding error was mine.** Two workers, on cards 54 and 58, different
families and different tiers, both replaced the run worktree's `state/`
directory with a symlink. I read that as a worker defect twice, wrote it into
two re-briefs, and built a watcher that stripped the symlink automatically. That
watcher is what stranded stage 51's PASS. The workers were not blundering; they
were correctly diagnosing a broken path contract and repairing it.

**The general lesson, which is the most useful thing in this log:** when two
independent agents in two different families do the same odd thing, that is
evidence of a shared cause in the cards, the prompts or the mechanism. It is
almost never two coincidental mistakes. Treat the second occurrence as a signal
about the system, not about the agent.

**Fix:** card 62. Assert the symlink at both ends, or make the paths absolute,
but do not leave a relative path whose only guarantee is a symlink nothing
checks.

**Confirmed on teardown.** Stage 58 ran its entire life with the symlink
absent. `state/` in its run worktree was a real directory holding nothing but
`handoffs/`, verified by `test -L` before the worktree was removed. The
verifier recorded the absence in its own `additional_findings` and wrote to the
shared path anyway because it reasoned its way there; the worker's envelope
reached `state/handoffs/` in the main repo as well, byte-identical to the copy
left behind in the worktree.

So the stage passed on two agents' care rather than on the mechanism. That is
not a fix, it is a near miss with a good outcome, and it is the second run in a
row where the symlink's absence was survived rather than prevented. Card 62
stands, and this is the strongest evidence for it: the mechanism failed
silently and the run looked normal from the outside.

---

## 2. Declared gates that nothing enforces

**What happened.** Four cards carry a `Gate:` line. `add-stage.sh:62` extracts
three fields from a card and `Gate` is not among them, so the gate never reaches
`state.yaml`. `tick.sh:1916` then selects on `status == "pending"` and
`head -n1`. Position in the list is the only thing holding a gated stage back.

**What it cost.** Three dispatches, stage 50 twice and stage 60 once. Each one
cut a run worktree, created a run branch, spawned an agent and spent tokens to
learn a fact the tick could have read from a file for nothing. The worker read
`state.yaml`, found the prerequisite unmet, and refused. The agents did the
right thing expensively.

**The worse half is the record.** A worker that refuses exits without a passing
envelope, so the loop marks the stage `failed`. Stages 50 and 60 sat at `failed`
all morning and neither failed at anything. An operator cannot tell "attempted
and did not work" from "was never eligible to start", and those two facts call
for opposite next moves.

**The syntax is not uniform either**, which is part of why nothing parses it.
Card 51 spells it `- **Gate: card 46 completed first.**` with the condition
inside the bold span; cards 58, 60 and 61 spell it `- **Gate:** after 58.` with
the condition outside and the stage named by number rather than by id.

**Fix:** card 64.

---

## 3. A drain that spans the window boundary turns a daily reset into a 24-hour halt

**What happened.** The repo halted at 01:34 on `token-cap`, 205,702,516 tokens
against a resting cap of 150,000,000. It did not self-heal.
`budget_ensure_window` zeroes the counters only when the stored window is not
today **and** the budget is already halted or at cap. At the 01:00 UTC boundary
the drain was still in force, so the budget looked healthy, nothing was zeroed,
and `window_started_at` was stamped `2026-08-25`. The next automatic reset was
therefore 2026-08-26, not that morning.

**What it cost.** The run was dead from 01:34 until a human zeroed the counter
at 06:05.

**Fix:** none. **This is an open hole and it is card-shaped.** The trap is that
the healthy state at the boundary is exactly what suppresses the reset.

---

## 4. "No live agent" is not the same fact as "the tick is not mid-transaction"

**What happened.** My `queue-minder.sh` preserved stranded work when it saw no
live agent. The tick was mid-landing at that moment. Stage 51 fast-forwarded
onto dev carrying a `wip(...)` message with no author and no `Autometta-*`
trailers.

**What it cost.** The work was intact; the record was wrong. Dev was unpushed so
the commit was amended to `19289d9` with the correct author and trailers. Had it
been pushed it would have stood.

**The lesson.** `tick.sh` takes `state/.tick.lock`. Anything that writes to the
same state must take it too. An absence of agents says nothing about whether a
transaction is open.

**Fix:** card 61 carries the lock criterion. Preservation is disabled in the
re-armed minder, and the thing worth rebuilding is a tick-staleness kickstart,
never a preserver.

---

## 5. `current_stage` drives everything, and manual status edits orphan it

**What happened.** After a hand edit of stage 58's status, `.current_stage` was
left null. The tick looked for a pending stage, found none, and did nothing for
an hour while 58 sat `in_progress`.

**What it cost.** An hour of a run window, and a stretch of debugging aimed at
the agents rather than at the pointer.

**The lesson.** If the queue looks alive but nothing is happening, read
`.current_stage` first. It is one line and it is almost always the answer.

**Fix:** none yet. Related in shape to entry 2: the loop has several pieces of
state that must agree and nothing that checks they do.

---

## 6. Panel mode is unusable on this repo and fails closed loudly

**What happened.** Setting `Verifier panel: true` on card 58 halted the repo with
`dispatch-configuration-fault` before any agent started.
`spawn-verifier-panel.sh` requires `auth.claude.mode: api` and this repo runs
Claude on subscription.

**What it cost.** Nothing but time. It failed closed and burned no attempt,
which is the correct behaviour and worth recording as a thing that went right.

**Also stale:** the panel roster still names **Claude Opus 4.8** and **Claude
Sonnet 4.6**, both superseded identities since 2026-07-26.

**Fix:** none. Open hole, card-shaped. Panel stays `false` until then.

---

## 7. A stage that passes can still fail to land, and the merge is not mechanical

**What happened.** Stage 58 was dispatched from `19289d9`. While it ran, stage 59
landed and moved dev to `4320a6d`. 58 then passed at 06:56, committed as
`7bc8bf7` on its run branch, and the tick correctly declined to fast-forward:
`dev moved since dispatch; autometta/58-... left standing, pushed to origin for
manual integration`. The tick has logged `still awaiting integration` every five
minutes since.

**Why it is not mechanical.** 58 and 59 both touch `scripts/tick.sh`,
`scripts/phat-controller.sh` and `docs/cost-log.md`. A dry-run merge conflicts in
one place, `scripts/phat-controller.sh`, and the conflict is a false alignment
caused by 58's `warden_*` to `pc_*` rename sitting next to 59's edit of
`warden_record_triage_spend`.

**The hazard, which a careless resolution walks straight into.** 59's change adds
a `family` argument to `budget_account_tokens_from_dispatch` so a Codex
controller's tokens are parsed from a Codex transcript. 58's branch still has the
five-argument call at its line 1189. Resolving by "take 58's side" is the
obvious move and it **silently reverts 59**: `family` defaults to `claude` and a
Codex controller is mis-metered. The stage that fixed the meter would be undone
by the merge of the stage that renamed the file around it.

**The lesson.** The loop assumes one stage in flight at a time, and mostly that
holds. It does not guarantee that dev is unchanged across a long stage's
lifetime, and the ff-only landing is the only thing that notices. A run that
lands a short stage while a long one is out will keep producing these.

**How it was resolved**, 2026-08-25 08:12, by hand and with Tony's approval.
Cherry-picked `7bc8bf7` onto dev in a scratch worktree, resolved
`phat-controller.sh` by taking 58's structure and re-applying 59's `family`
argument to the renamed `pc_record_spend`, then confirmed 59's plumbing survived
in the auto-merged files too: `local family="${8:-claude}"`,
`budget_parse_dispatch_tokens_from_transcript` with its third argument, and the
`verifier_family_acct`, `worker_family_acct` and `stale_verifier_family_acct`
locals are all present in the merged `tick.sh`. All twenty offline smokes pass.
Dev is `0ae4a95` and pushed; the pre-rebase head is kept at
`refs/heads/backup/58-preintegration`.

**A second bug found during the resolution.** The integration record is derived
from **branch containment**: `reap-worktrees.sh:161` asks whether the run
branch's tip is an ancestor of the base branch. A rebase produces a new commit,
so the old tip is never an ancestor, and the reaper flips a hand-recorded
`merged` straight back to `awaiting`. It did exactly that on a dry run. The
worktree is then never torn down and the tick logs `still awaiting integration`
for ever, on a stage that has fully landed.

The workaround was to point the run branch at the rebased commit so containment
holds again. That works and it is not a fix: it means the only integration the
loop can recognise is a fast-forward, and a rebase, a squash or a
cherry-pick is invisible to it.

**Fix:** none. Open hole, and now two-part: the loop cannot land a stage whose
base has moved, and it cannot recognise any integration that is not a
fast-forward.

---

## 8. Smaller things, recorded so they are not re-learned

- **A manual `autometta tick` redirected to `/dev/null` writes nothing to
  `tick.err.log`.** Manual passes are invisible in the tick log. Capture them to
  a file or they did not happen as far as the record is concerned.
- **The TCC prompts seen overnight came from the headless `claude` CLI**
  (dialog reported 2.1.241 against a local 2.1.243) reaching iCloud Drive and
  network volumes. This is gotcha 11 territory and the best candidate for the
  22:36 tick freeze.
- **`git show <branch>:<path>` printed the commit rather than the blob** during
  this investigation, which briefly looked like a file full of diff markers and
  a corrupted commit. It was not. `git cat-file blob <sha>` is the reliable read
  when the answer matters.
- **Stale vendor warnings repeat every tick** for `fractals-from-the-90s` and
  `emergence-lab`, both holding the contract from `9630ebb` against `4320a6d`.
  Harmless, and it is four lines of noise in every five-minute tick, which is
  most of what the tick log now contains.

---

## 9. Nothing prunes what a landed stage leaves behind

**What happened.** `reap-worktrees.sh` tears down a run *worktree* once its
branch is contained in the base. Nothing tears down the *branch*, and nothing
tears down the preserved-attempt branches at all. They accumulate silently for
as long as the repo runs.

**Measured on 2026-08-25, after 58 landed**, with the queue idle and every
stage below either completed or superseded:

- 6 remote run branches (`origin/autometta/40, 41, 43, 45, 46, 58`), every one
  of them either fully contained in dev or, in 58's case, an orphan left by the
  rebase. Pure duplicates of commits that had already landed.
- 11 local `wip/*` branches across 7 completed stages, 42 to 58. Unlike the run
  branches these hold **unique commits** that exist nowhere else: preserved
  work from attempts that failed before a later attempt succeeded.
- 17 local branches in total, of which 4 are load-bearing (`dev`, `publish`,
  `autometta/state`, `phat-controller/state`).

**Why it matters more than tidiness.** The two categories look identical in
`git branch` and are not remotely alike. Deleting a run branch whose stage has
landed loses nothing. Deleting a `wip/*` branch destroys the only copy of that
attempt's work. An operator clearing up on a Friday afternoon cannot tell them
apart by name, and the safe-looking bulk delete is the destructive one.

**How they accumulate faster than you would expect.** Entry 7 is the mechanism:
an integration the reaper cannot recognise leaves the worktree standing *and*
the branch behind, and the tick logs `still awaiting integration` for ever
while both sit there. Every rebase, squash or cherry-pick integration adds one
worktree and one branch that nothing will ever collect.

**The rule worth keeping.** A branch containing only commits reachable from the
base branch is disposable. A branch containing unique commits is evidence, and
it needs a decision rather than a sweep. Whatever eventually automates this must
sort on containment, not on name.

**Fix:** none. Open hole. Card-shaped, and it should be the same card as
entry 7, because the reason the litter is not collected is the reason the
integration is not recognised.

---

## Open holes, collected

Entries above with no card, in the order I would write them:

1. The drain that spans the window boundary (entry 3). It kills a whole run
   window and it is invisible until someone reads `budget.json`.
2. Landing a stage when the base has moved, and recognising an integration
   that is not a fast-forward (entry 7). Resolved by hand for stage 58; the
   mechanism is unchanged and will do it again.
3. Panel mode: the api-mode requirement and the superseded roster (entry 6).
4. State that must agree and nothing checking it, `current_stage` first
   (entry 5).
5. Nothing prunes a landed stage's branches or an unrecognised integration's
   worktree (entry 9). Same card as 2, most likely.

## What went right, recorded on purpose

- Panel mode failed closed before spending anything (entry 6).
- The ff-only landing refused to merge a stage whose base had moved rather than
  guessing (entry 7).
- Workers refused ungated stages instead of proceeding, three times (entry 2).
- Two workers independently diagnosed a genuine path bug (entry 1).

Four of this run's most expensive incidents were the system or the agents doing
the right thing, and being misread by me.
