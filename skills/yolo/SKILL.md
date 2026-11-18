---
name: yolo
description: >-
  Attend an Autometta card run with the operator away: agree the caps, the
  stop time and whether to carry on across Claude session windows in one
  prompt before they leave, then work every failure, stall,
  halt and awaiting integration on the queued run under a written standing
  authority, park whatever needs the operator, stop any stage at its third
  failed attempt, and hand back a decision log with the lessons recorded for
  the weekly review. Use ONLY when the operator says "yolo", "YOLO this run",
  "attend the run without me", "run it overnight", "mind it while I'm away",
  or "spend the window down before it resets". Needs an Autometta subscriber
  repo with a run already queued. Not for designing or queueing a run
  (autometta-run-design) and not while the operator is present
  (autometta-escalations).
---

# YOLO: attending a run without the operator

The tick still dispatches, verifies and lands. You are the orchestration chat
left in charge of one run, overnight or while a usage window is spent down
before it resets. `autometta-escalations` is the playbook and its recovery
policy binds in full. This skill changes one thing: where that playbook says
"propose and wait for the operator", nobody is there, so each such decision
is either covered by the standing authority below or it is **parked**. The
operator asked for forward motion, not for a stage to pass by any route.

Script paths are relative to the Autometta checkout. Scope is the one
subscriber repo this chat sits in, unless the operator names more at the
prompt. Another repo's escalation belongs to another chat: leave it alone.

## Before the operator leaves

This is the only time you may ask anything. Do all of it in one go.

1. **Take the picture.** `scripts/phat-controller.sh picture <repo>`,
   `scripts/escalations.sh list`, `autometta status`,
   `python3 scripts/quota-window.py all`, `scripts/drain.sh status`,
   `scripts/phat-controller.sh --print-mandate`, and the caps and counters in
   `<repo>/state/budget.json`. Work any pending escalation with the operator
   now; do not carry an undecided one into the night.
2. **Ask the start questions, once, with the defaults filled in.** One
   prompt, each line showing the default, the value in force and where it
   comes from:
   - **Claude session ceiling:** default 90% used. In force:
     `100 - window_reserve.percent`, or `overnight.percent` inside a declared
     overnight window.
   - **Carry on into the next Claude session window?** Opt-in, default no.
     Yes: the queue stops at the ceiling, waits for the session to reset,
     starts again, and you attend across the gap (see Session holds). No:
     the first hold at the ceiling ends your attendance. Tell the operator
     before they answer that no does not yet keep the queue stopped: the
     tick restarts dispatch at the reset whoever is watching, until the
     per-repo hold in proposal `P-20261116-4c12` lands.
   - **Codex ceiling:** default whatever the host already resolves:
     `window_reserve.codex_admit_percent` (100 when unset) and the pace gate
     if it is on. YOLO sets no figure of its own.
   - **Repo token cap:** the resting cap and the headroom left in this UTC
     day. Offer a drain only if the queued cards' spend basis exceeds it.
   - **Stop time:** default the end of the declared overnight window, else
     eight hours from now. Spending a window down, it is that window's
     reset. Never later than twelve hours after this prompt: the wake-up
     lease ends then and only a human prompt renews it. With carry-over,
     say how many session resets fall before it.
3. **Apply the answers while the operator is still there.** Where an answer
   differs from the value in force, state the exact change, make it and
   record before and after: a mandate edit for a reserve or ceiling (say that
   it is host-wide and stays until changed back), `scripts/drain.sh start
   --cap N --hours H --repo <repo> --reason "yolo <date>"` for a token cap.
   Carry-over works only if the reserve holds: `action: hold`, and
   `claude_window: 5-hour` so a weekly window is not what stops the queue.
   Once the operator has gone the caps are fixed.
4. **Check that events can reach you.**
   `scripts/install-escalation-hook.sh --check --family all` reports both
   families installed. `scripts/wakeups.sh status` shows this chat as the
   live owner of the repo scope, with a lease that outlasts the stop time, no
   latched error, and fewer than 24 attempts in the last 24 hours. Wake-ups
   are best effort: the fleet shares six an hour and 24 a day, routine starts
   spend the same allowance as failures, and an event more than 15 minutes
   old is dropped. Say what you found.
5. **Arm the backstop.** If your harness has a native timer (Claude Code: a
   session cron or a scheduled wake-up; Codex has none today), schedule one
   check-in every 30 minutes, no faster, ending at the stop time. A check-in
   runs `scripts/escalations.sh list` and `scripts/phat-controller.sh picture
   <repo>` and compares them with the last log entry. Nothing changed: one
   line, no log entry, idle again. This is the one sanctioned exception to
   "no model polling" and it never acts on an unchanged episode. With no
   timer, tell the operator the run is attended only as far as wake-ups reach.
6. **Open the run log and report.** Write the header (see Run log), then tell
   the operator in a few lines: caps in force, stop time, how you will be
   woken, what you will do alone and what you will park.

## Standing authority

The recovery policy in `autometta-escalations` is yours without asking:
diagnose, repair an implementation defect, correct a demonstrated
semantic-preserving oracle or harness defect, preserve, requeue with
`--keep-budget`, record the attempt on the card. A repair may step the pairing
down a tier as `autometta-requeue` describes; it never steps up, changes
family or changes auth route. YOLO adds three things:

- **Act first, report in the log.** The report that policy asks for before a
  retry (diagnosis, changed scope, headroom, attempts left) is written to the
  run log before you act, in place of telling the operator.
- **Clear a halt on the attended repo**, only as the halt table allows.
- **Land clean work.** `scripts/phat-controller.sh merge-awaiting <repo>` for
  a conflict-free awaiting integration; `push` only on a `PUSH` verdict. `ASK`
  is parked, since nobody can answer, and `HOLD` stands.

## Deciding alone

- **Read before deciding.** A notice or a wake-up is a cue, never the
  evidence. Open the envelope, the verifier artefact, the logs and the
  current state, and re-check the episode before any mutation: the tick or
  another chat may have moved it.
- **Classify as the escalations skill does.** If the evidence does not settle
  the class, park. A guess costs a dispatch and one of three attempts.
- **Prefer what git can undo.** A re-brief, a preserved branch and a requeue
  are all revertible. Whatever changes what was asked for, or whether it was
  met, is not yours.
- **Park and move on.** Parking leaves the stage as it stands, preserves its
  work, and writes the decision the operator must make with your
  recommendation. A parked stage costs the morning one answer; a wrong repair
  costs the night. Then attend the rest of the run.
- **One cause, one diagnosis.** Two stages failing in the same odd way share
  a cause. Find it before spending either stage's attempts.
- **No progress twice is a stop.** The same remedy applied twice to one stage
  without movement parks it, whatever attempts remain.
- **Waiting is free.** A quota hold, a pause, a deferral or a curfew resolves
  itself; record it once and go idle. Between events do nothing at all.
- **Watch your own window.** Your diagnosis spends the same session the
  workers do. Read the quota before substantial work; at or past the ceiling
  for your own family, stop working and wait for the reset.

| Episode | Alone, you |
| --- | --- |
| Implementation defect | Repair re-brief through `autometta-requeue`: preserve, archive the attempt, `--keep-budget`, next attempt recorded on the card. |
| Dead or silent agent | Let the tick's single mechanical retry run. A second death is diagnosed as a failed attempt. |
| Oracle or harness defect, criteria unchanged | Correct it under the recovery policy (`autometta-oracle` for a re-freeze), with the proof that policy asks for. |
| Card defect, or a contract that contradicts a criterion | Park. Append `propose-amendment`; never apply it. |
| Claude session at its ceiling | See Session holds. |
| Other quota hold, usage limit, network deferral | Wait. It is not a failure and not an attempt. |
| Awaiting integration | `merge-awaiting` when clean. Any overlap or conflict: park. |
| Evidence does not settle it | Park. |

## Session holds

The tick stops and restarts the queue; this skill only decides how you
behave around it. Under a hold reserve the tick refuses new work that names
a Claude worker or verifier once the session window reaches the ceiling,
pauses the repo until the published reset, and dispatches again on the first
tick after it. The signs are `paused_until` and `paused_reason` in
`state/budget.json` and a tick log line `held in N% reserve on 5-hour ...
paused until <time>`. A process already running finishes and may pass the
ceiling; whatever is not yet dispatched, a verifier included, waits. None of
this is a failure or an attempt, and there is nothing to clear.

A session that runs out altogether looks different. The provider refuses the
worker in one line, the tick rewinds the stage untouched and pauses until the
time that line names (`paused_reason` is then the refusal itself, `You've hit
your session limit · resets 1am`). A refusal with no time the tick can parse
gets a blind pause of exactly one hour, which is a retry interval, not the
reset.

With carry-over agreed:

- **Take the restart time from the record.** Read both sources:
  `jq '.paused_until, .paused_reason' state/budget.json` (an epoch second)
  and the `resets_at` of the `5-hour` window in `python3
  scripts/quota-window.py claude`. They should agree to within a few
  minutes; use the later. Where the pause is the blind hour, use the quota
  reading. Never work the time out from when the session began or from five
  hours of arithmetic. Record the hold once: the window, the utilisation,
  both times in UTC and the one you chose.
- **Schedule one check-in at that clock time plus ten minutes**, which
  allows two ticks at the default interval. If this chat runs on Claude, its
  turns spend the same session: finish the entry in hand, cancel the
  30-minute backstop, and set a single one-shot timer for the absolute time
  (Claude Code: a non-recurring session cron pinned to that minute, hour and
  date, which is host local time, so convert from UTC). Read back the fire
  time the harness reports and log it. Do not chain shorter timers across
  the gap: a turn that fires while the session is exhausted is refused and
  the chain ends there. A chat on another family keeps its backstop and
  adds the one-shot.
- A fleet `quota_window_cleared` notice can arrive before dispatch. If
  carry-over is agreed and you are still attending, check your own run,
  reserve and stop time. Keep the scheduled check-in while dispatch is
  outstanding. Other runs receive the same notice.
- A wake-up on the first dispatch after the reset may reach you sooner. Treat
  it as the same check-in and cancel the timer.
- **At the check-in** confirm `paused_until` has cleared and a dispatch has
  started, then arm the backstop again. If the tick has paused again (a
  second blind hour, or a fresh reading still inside the reserve), take the
  new time the same way and schedule once more; a third pause in a row ends
  the run. A stale or unknown reading makes the tick hold tick by tick until
  a fresh one arrives; the exporter is not yours to repair. Record it, and
  after 30 minutes with no dispatch end the run.
- If the window at its limit is not the session (a weekly window, a
  model-scoped one, or a provider refusal that names either), the reset is
  days away: end the run.
- A hold extends neither the stop time nor the wake-up lease.
- If your own turn is refused at the limit, nothing is lost. The state and
  the log are on disk; read both again at your next turn before acting.

With carry-over declined, the first session hold ends your attendance: hand
back then. The reserve is a host rule, so the tick still restarts dispatch
at the reset; say in the hand-back that the rest of the run is unattended
and give the restart time. You have no verb that keeps one repo stopped, and
you do not improvise one: no halt, no edit to `state/budget.json`, no change
to the mandate.

## Halts

Find the reason in `state/budget.json` (`halt_reason`, `halt_reasons`,
`breaches`) and the tick log before anything is requeued. `tick.sh
--reset-halt` clears every enabled subscriber and is never run from a YOLO
chat; the per-repo routes are `scripts/phat-controller.sh stale-halt <repo>`
and a plain `requeue-stage.sh` (no `--keep-budget`) on the affected stage.

| Halt reason | Alone, you |
| --- | --- |
| A stale halt or an elapsed pause | `stale-halt <repo>`. It clears only what it can prove stale. |
| `token-cap`, `wall-clock-cap` | Never clear, never drain. The budget window resets at the UTC day boundary and dispatch resumes by itself; if that falls after the stop time, end the run. |
| `tick-cap`, `idle-tick-cap` | The same wait. Clearing it sooner needs the fleet-wide reset. |
| `failure-cap` | Diagnose the consecutive failures together. One shared cause, removed by a repair the policy already allows: requeue the failed stages, the first plainly so the halt clears and the rest with `--keep-budget`, once per run. Unrelated causes, no diagnosis, or a second `failure-cap` halt: end the run. |
| `dispatch-configuration-fault` | Read the fault line. A credential or network fault that has passed (`scripts/preflight-network.sh` succeeds, `autometta auth check <family>` passes): requeue the stage plainly, once. A standing fault (unknown option, missing executable, auth route): end the run. Never change a route, a mode or a pairing to get past it. |
| `state-corrupt`, `yq-missing`, `invalid-stage-id`, `controller-escalation`, `operator` | End the run. Never hand-edit state. |

## Hard stops

**The third failed attempt ends a stage.** Count every worker dispatch as the
escalations skill does. When a stage's third attempt fails there is no
fourth: not on a card that allows more, not when the diagnosis is certain,
not through a new pairing, a new card, a new stage id or a new chat. A
stricter limit on the card still wins. Preserve the work, park the stage and
everything that depends on it, and go on attending whatever is independent.

Never, whatever the evidence says:

- edit a card's objective, criteria, specification or thresholds, or change
  what a frozen oracle accepts;
- raise, bypass or reset a spend or quota gate: no drain start or replace,
  no `--reset-tokens`, no `AUTOMETTA_IGNORE_RESERVE` or `AUTOMETTA_IGNORE_PACE`,
  no mandate edit after the operator has gone;
- move work onto a metered route, another family or a higher tier;
- pass `--force` or `--discard` to a requeue, resolve a merge conflict,
  force-push, move a publish branch or deploy;
- queue a card the operator did not queue, or dispatch outside the tick;
- renew or re-register a wake-up lease, or clear a delivery error;
- edit this skill, or the harness beyond a repair the recovery policy covers.

End the run, and stop the backstop, when the run finishes, the stop time
arrives, the operator returns, a halt table row says so, a session hold
arrives with carry-over declined, or nothing left in the run can move
without a decision.

## Run log

One Markdown file per run at `$AUTOMETTA_HOME/yolo/<UTC start>-<repo>.md`
(`~/.autometta` by default; for example `20261116T2200Z-promo-flow.md`). The
file name without `.md` is the log id, cited the way an escalation id is. The header records the operator's cap answers in their words, the
stop time, the queue at the start and the delivery check. Then one numbered
entry per decision, **written before you act** and completed afterwards:

- time and trigger (notice, escalation id, backstop check-in);
- evidence opened and the class you settled on;
- options considered, the decision and the line of this skill it rests on;
- outcome, filled in once known;
- `would have asked: <the question>` wherever you would have checked with
  the operator had they been there;
- `proposal: <id>` when the entry taught the harness something, recorded
  there and then (see Recording what the run taught).

## Hand-back

When the run ends, or at the operator's first prompt, put a summary at the
top of the log and give it in the chat: what landed, with commits; what is
parked, each with the decision needed and your recommendation; attempts used
per stage; spend against each cap (`state/cost-log.jsonl`); every halt cleared
and why; any cap change or drain still in force; how each event reached
you (wake-up, backstop or not at all); and the proposal ids recorded.

## Recording what the run taught

Record each lesson in the proposals ledger as it happens, following
`autometta-learning-log`, so the weekly review can tune out the halts and
failures that cost the night. Do not save them for the hand-back: a session
limit or a dropped wake-up can end your attendance first. At the hand-back,
run that skill's sweep, lint and commit, and list the ids in the summary. A
harness lesson is recorded as that skill describes. A lesson about attending
unattended takes a `yolo:` title prefix and cites the log entry:

```sh
scripts/proposals.sh add --agent "$(agent-whoami --model '<your model id>')" \
  --title "yolo: <the change to the guidance, not the symptom>" \
  --kind <skill|policy> --target skills/yolo/SKILL.md \
  --change "<what to change and why>" \
  --evidence <log id>#<entry>,<stage id>[,<escalation id>] \
  --repo <subscriber basename> --run <run-id>
```

Record one per cause, when:

- a decision had no guidance here and you had to reason it out (`skill`);
- guidance here led to a wasted dispatch or a wrong action (`skill`);
- you parked something for want of authority and the answer looks routine.
  That is `policy`: widening what YOLO may do alone is the operator's call;
- a signal arrived late or never, or a cap bound in a way nobody intended
  (`script` or `policy`, targeting the surface at fault).

At the debrief, when the operator overrules a logged decision, record that
too, quoting them. A proposal is a note to the review, never authority: this
skill changes only through `autometta-weekly-review`, and never from inside
a run.
