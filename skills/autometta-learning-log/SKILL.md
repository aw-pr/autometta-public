---
name: autometta-learning-log
description: >-
  Where and how an Autometta orchestration chat records what the harness
  should learn, at the moment it is learnt: halts, failed attempts, dead or
  silent agents, workarounds, late or missing signals, checks that lied, and
  skill guidance that was missing or wrong, each as one line in the
  proposals ledger (memory/proposals.jsonl) for the weekly self-improvement
  review. Use whenever an Autometta run, card, requeue or escalation shows
  the harness itself costing time, attempts or tokens; when the operator
  says "log this", "log an issue", "note it for the weekly review", "record
  a proposal", "where do I log this", "bank the lesson"; and before any
  Autometta orchestration chat hands back or ends. Referenced by yolo,
  autometta-escalations and the other autometta skills. Not for deciding
  proposals (autometta-weekly-review) or for changing the harness mid-run.
---

# Recording what the harness should learn

The weekly review (`autometta-weekly-review`) can only tune out what someone
wrote down. A halt cleared, a workaround applied or a failure repaired in the
moment and never recorded comes back next week. This skill says where each
kind of observation goes and how to write it, for Claude and Codex chats
alike, in the Autometta checkout or any subscriber repo. The contract behind
it is `docs/learning-log.md`.

## Record as you go

Write the line when the diagnosis is in hand, before the next action. Not at
the end: a chat that saves its lessons for the hand-back loses them to a
session limit, a compaction or the next wake-up. It costs one shell command.
Recording never replaces or delays the repair the recovery policy allows;
write the line, then carry on.

## Where each thing goes

| You saw | It goes to | How |
| --- | --- | --- |
| A harness defect, gap or recurring friction | `memory/proposals.jsonl` in the Autometta checkout | `autometta proposals add`, below |
| A `HARNESS:` line in a verifier artefact | the same ledger, citing the artefact | the same command |
| A lesson about attending a run unattended | the same ledger, title prefixed `yolo:`, target `skills/yolo/SKILL.md` | the same command |
| This episode's decision: repair, requeue, amendment | the card's `Recovery log` and the escalation's ack note | `autometta-escalations`, `autometta-requeue` |
| A decision an unattended chat took or parked | the run log under `$AUTOMETTA_HOME/yolo/` | `yolo` |
| The story of a bad run, when it deserves the paragraph | `docs/incidents/<date>-<repo>-run-lessons.md`, with a table of ledger ids | by hand |
| A defect in the subscriber's own code, tests or card | that subscriber: a re-brief, a card or its own backlog | never the Autometta ledger |
| A fact about landed work | `memory/facts.jsonl` | the tick only, never by hand |
| A design decision or cross-family note that asks for no change | `memory/<type>-<slug>.md` and `memory/INDEX.md` (`memory/adopters/<repo>/` for an adopter) | `memory/README.md` |

The ledger is the only list the review decides from. A lesson written only
in an incident file, a yolo log, a handoff or a harness-private memory
directory is never decided. Incident files and yolo logs are evidence; the
ledger line is the item. The ledger is private-tier (held off the publish
head); `docs/incidents/` is published, so an incident file carries no private
data.

## What earns a line

One proposal per cause, when any of these happened:

- **A halt.** Any `halt_reason`, unless a cap stopped the run exactly where
  the operator agreed it should. Say what cleared it and what it cost. A halt
  that behaved as designed but stopped work the operator wanted (a cap below
  the queued cards' spend, a blind hour when the reset time was knowable, a
  failure cap tripped by one shared cause) is a tuning item of kind `policy`.
- **A failed attempt whose cause was not the worker's code**: the card
  template, card review, the oracle, the verifier prompt, a gate, a fixture
  or the tick.
- **A dead or silent agent** beyond the tick's one mechanical retry, or a
  retry that should never have been needed.
- **A workaround.** You or an agent stepped round the harness to get on: a
  fallback path, a step run by hand that the tick should own, a manual state
  edit, an override variable.
- **A signal** that came late, twice or never: a notice, a wake-up, an
  escalation.
- **A check that lied.** Lint passed what `add-stage.sh` refused, a smoke
  printed PASS over an error, a gate checked less than its doc says.
- **A skill that let you down.** Guidance missing, wrong or contradicting
  another skill; a decision you had to reason out from nothing.
- **A recurrence** of something already in the ledger (see Duplicates).

Leave out a plain implementation defect in the worker's diff, a quota hold or
pause that resolved itself as expected, a one-off transient the preflight
caught, and anything the subscriber owns. When you cannot tell whether the
harness is at fault, record it and say so in `--change`: the review rejects a
weak line cheaply, and cannot decide one that was never written.

## How to write it

```sh
autometta proposals add --agent "$(agent-whoami --model '<model id>')" \
  --title "<the change, not the symptom>" \
  --kind <script|skill|template|schema|doc|policy> \
  --target <autometta path>[,<path>] \
  --change "<what happened and what it cost; what to change; why>" \
  --evidence <ref>[,<ref>] \
  [--repo <subscriber basename>] [--stage <stage-id>] [--run <run-id>]
```

- **Identity.** Claude: `agent-whoami --model '<model id from your
  preamble>'`, quoted. Codex: `agent-whoami` with no argument. A non-zero exit
  means the helper does not know your model: stop and tell the operator,
  never type an identity by hand. Pass it inline as above; an exported
  variable does not survive between tool calls in every harness.
- **Which ledger.** `autometta proposals` runs the checkout named by
  `autometta_root:` in `$AUTOMETTA_HOME/config.yaml`; inside the checkout,
  `scripts/proposals.sh` is the same thing. Without that line the Homebrew
  copy writes into its own `libexec`, which the next upgrade deletes. Check it
  once per session: `grep '^autometta_root:'
  "${AUTOMETTA_HOME:-$HOME/.autometta}/config.yaml"`.
- **title**: the change in under about 80 characters ("Pause a limit refusal
  to the window reset, not a blind hour"), not the symptom ("worker paused
  for an hour"). The `yolo:` prefix is only for lessons about attending a run
  unattended.
- **kind**: `policy` for caps, gates, allowances and anything that widens
  what a chat may do alone; those need the operator's quoted yes at review.
- **target**: repo-relative paths in the Autometta checkout, never absolute
  and never the subscriber's files. If you do not know the fix, name the
  surface you would open first and say so in `--change`.
- **change**: lead with what happened and its cost (time lost, attempts
  used, tokens spent, a run stopped), then the change and why. A reviewer
  who never saw the run must be able to decide from this and the evidence.
  No secrets, tokens, customer figures or home paths.
- **evidence**: what a reviewer can open: a stage id, an escalation id, a
  yolo log id with its entry (`20261116T1955Z-contract-crawler#4`),
  `state/verifiers/<stage>.json#additional_findings`, an archived attempt
  under `state/uat/<stage>/attempt-<n>/`, a `memory/facts.jsonl` subject, a
  commit SHA, a path with an anchor. A requeue purges the live envelope and
  verifier artefact, so record after the attempt is archived and before the
  requeue, citing both the live artefact (which marks its `HARNESS:` lines as
  lifted) and the archive (which survives the purge).
- **repo, stage, run**: `--repo` whenever the observation came from a
  subscriber; `--stage` when one stage shows it; `--run run-YYYYMMDD-HHMMSS`
  when you know it.

The command prints the new id. Quote it wherever the lesson is mentioned:
the yolo log entry, the ack note, the incident table, the hand-back.

## Duplicates and recurrence

Look before adding: `autometta proposals list` prints every open item's
title, and `autometta proposals list --status all | grep -i '<word>'` finds
closed ones. The ledger has no event that adds evidence to an existing item,
so:

- **Same cause, still open:** record it again. Repeat the change as the
  title and open `--change` with `Recurrence of P-YYYYMMDD-xxxx:`, giving
  only the new occurrence and its cost. The review merges it into the
  survivor and counts it; a recurring item is the first one it recommends.
- **Same cause, already landed or rejected:** record it again and say so. A
  fix that did not hold, or a rejection the new evidence overturns, is what
  the review most needs to see.
- **The same thing twice in one session:** one line, both pieces of
  evidence.

## Before the chat ends

At a yolo hand-back, when an escalation batch is done, when a design or card
session closes, or when the operator says they are leaving:

1. **Sweep.** What cost an attempt, a halt, a workaround, or a question no
   skill answered? Record whatever is not yet in the ledger.
2. **Lift.** `autometta proposals unlifted` lists uncited `HARNESS:` lines
   across the fleet. Lift those from stages you worked; leave the rest to
   the review.
3. **Lint.** `autometta proposals lint` must print PASS.
4. **Commit, path-limited, on `dev` only.** In the Autometta checkout, and
   only when `git -C <checkout> branch --show-current` prints `dev`:

   ```sh
   git -C <checkout> commit --author="$(agent-whoami --model '<model id>')" \
     -m "memory(proposals): <ids> <what they are about>" -- memory/proposals.jsonl
   ```

   Never `git add -A` or `git commit -a` there; the tick may be landing in
   the same checkout. Lines other chats left uncommitted go in the same
   commit, and each keeps its own `agent` field; say so in the message. On
   another branch, or if the commit is refused, leave the lines and say so
   in the hand-back: the weekly review commits what it finds.
5. **Report the ids** you recorded in the hand-back or your last message.

## Boundaries

- A proposal is a note to the weekly review, never authority. Recording one
  does not license a harness edit, except a repair the recovery policy
  already allows for this stage (`autometta-escalations`). When the operator
  asks for a change directly in the chat, record `approve` with their words,
  make it, then `land` it with the commit.
- Only `autometta proposals` writes the ledger. Never edit, reorder or
  delete a line; the next legal event corrects a wrong one.
- The tick, the workers and the verifiers never write it. A verifier writes
  `HARNESS:` lines; an orchestration chat lifts them.
