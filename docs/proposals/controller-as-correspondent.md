# The controller nobody wired up

Operator design review, 2026-08-27, after an operator sent the TUI's message
pane two questions and got no answer to either. Extends
[orchestrator-role-review.md](orchestrator-role-review.md); nothing it decided
is reversed here.

## The observation

An operator watching a live run typed a message into the TUI's `[3] messages`
page and expected to be talking to the agent that controls things when the
queue runs headless. The message was accepted and marked `pending`, with the
footer saying `queued for the controller's next pass`. It stayed pending. So
did an earlier one, sent the day before.

Nothing was broken. The write path worked, the pane reported the literal truth,
and the messages sat correctly on disk in
`state/phat-controller-inbox/pending/`. The pass they were queued for never
came, and could not have.

## What already exists

The role the operator reached for is designed and built. Card 58 inverted the
control flow so that phat-controller is an agent rather than a script, and
`scripts/phat-controller.sh` opens by saying so: initiative lives in the agent,
mechanism lives in the file. `templates/phat-controller-prompt.md` begins "You
are phat-controller, minding an Autometta queue for one pass". `pc_pass` reads
a dispatch identity from the mandate, renders that prompt, and launches a real
agent through `op-fetch`. The inbox, the outbox, the journal, the transcript
index and the two reply verbs exist to give that agent a correspondent's
memory across passes.

This proposal is therefore not a design for something absent. It is an account
of why something present has never run, and of the three questions that were
never settled because it never ran.

## The three wires

**No seed.** `~/.phat-controller/phat-controller-seed.md` does not exist, so
`pc_pass` refuses before it does anything: the job has not been configured.
That refusal is correct and deliberate. The seed carries the spend authority,
and `render-controller-seed.sh` has no default for it because there is no right
default for how much money a role may spend unattended.

**No schedule.** No phat-controller LaunchAgent is installed or loaded on this
machine. `scripts/install-launchagent-phat-controller.sh` exists and has never
been run. The fleet tick is scheduled and the controller is not, which is easy
to miss because both are described as "the loop" in conversation while being
different mechanisms: the tick dispatches workers and verifiers, the controller
minds the queue those dispatches move through.

**No agent on the record.** The journal writes an `agent` field fed by
`AUTOMETTA_CONTROLLER_AGENT`, and nothing in the repo ever sets it. Every
journal line therefore records the role as `actor` and `null` as `agent`, which
is exactly the fact the role/model split was introduced to preserve.

None of the three is a design flaw. Together they are the difference between a
role that exists and a role that runs.

## A duplication introduced while investigating this

On 2026-08-27 the controller's git attribution was changed so that a commit's
author names the model driving the pass rather than the role, with the role
moved to an `Autometta-Controller` trailer. A follow-up narrowed that to use the
model identity only when one is asserted for the pass, via a new
`AUTOMETTA_CONTROLLER_IDENTITY` variable.

That variable duplicates `AUTOMETTA_CONTROLLER_AGENT`, which already names the
same concept and predates it. The follow-up should have consolidated onto the
existing name rather than adding a second one.

The duplication also inherits a defect the file itself documents. Both are
environment variables, and the comment above `pc_current_pass_id_path` explains
why that cannot work for a dispatched pass: op-fetch execs the agent with
`env -i` plus an allowlist, so a variable set before dispatch does not survive
into the verb invocations the agent makes as its own tool calls. `pass_id`
solved this with a marker file inside the repo the pass is about. The agent
identity has the same shape of problem and wants the same answer.

The practical effect today is that the new attribution works for a verb called
by hand from an interactive session, and silently falls back to the role for a
genuine dispatched pass, which is the case that matters.

## The questions that were never settled

### Three things are called the orchestrator

The operator asked for "the orchestrator agent that controls things when we run
headless" and meant phat-controller. The word is currently doing three jobs:

| Sense | What it is |
|---|---|
| the interactive orchestrator | a human, or an agent session a human is driving |
| phat-controller | the scheduled queue minder, an agent |
| a card's `Orchestrator:` field | the identity that authored the card, which acts at authoring time and never again |

`CLAUDE.md` lists the first two as separate operational roles and the third is
metadata, so nothing is wrong. But an operator reaching for the headless
decider has no obvious name to reach for, and reached for a word that already
means two other things. Naming this is the cheapest of the changes proposed
here and probably the one that most changes how the system reads.

### Pull or push

The inbox is drained on a pass cadence. A message waits for the next pass
however urgent it is, and if no pass is scheduled it waits for ever, which is
what happened.

There are two shapes and they are not a matter of taste:

- **Pull.** Passes run on a schedule and read whatever has accumulated. Simple,
  bounded, and the spend is a function of the cadence alone. Latency is half
  the interval on average.
- **Push.** An inbound message wakes a pass. Responsive, and it makes the pane
  feel like a conversation rather than a suggestion box. It also means an
  inbound message spends money, so the seed's spend authority has to cover
  operator messages as a category, and a message becomes a thing that needs
  rate limiting.

The choice determines what the spend authority has to say, so it should be made
before a seed is rendered, not after.

### Queue minding and correspondence may not be one job

The mandate defaults the dispatch identity to Claude Sonnet 5. That is a
reasonable choice for mechanical queue minding, where the work is reading a
picture and choosing between enumerated verbs under a negative list.

It is a less obvious choice for answering "what is the status of this run and
should I be worried", which is the question operators actually type. Those are
different tasks with different failure modes: a weak queue minder makes a bad
requeue that the next pass can correct, while a weak correspondent gives a
confident wrong account of a run and the operator acts on it. They are the same
agent today because nobody has had to separate them.

### A pass remembers only what was journalled

Each pass is a fresh agent. Continuity across passes is reconstructed from the
journal, the transcript index and the inbox, not held in a session. That is the
right shape for a cron-driven system and it should not change.

It does mean the thing an operator is chatting to remembers what was recorded
and nothing else, which is a real constraint on how conversational the pane can
honestly be. Better to state it in the pane than to let an operator discover it
by being forgotten.

## What this proposes

In order, smallest first. Each is a card, not a step of one card.

1. **Name the headless decider unambiguously**, and say in `CLAUDE.md` which of
   the three senses of orchestrator each usage means. Documentation only.
2. **Consolidate the controller agent identity** onto
   `AUTOMETTA_CONTROLLER_AGENT`, delete `AUTOMETTA_CONTROLLER_IDENTITY`, and
   carry it the way `pass_id` is carried so it survives into a dispatched
   agent's verb calls. Then the journal's `agent` field stops being null and
   the git author is right for both the scheduled and the interactive case.
3. **Decide pull or push**, and write the answer into the seed template's
   spend-authority prompt so configuring a job forces the question.
4. **Configure and schedule a controller job** on this machine: render a seed
   with an explicit spend authority, install the LaunchAgent, and confirm a
   pass drains the inbox unattended. This is the wire that makes the other
   three observable.
5. **Separate correspondence from queue minding** if, once a pass is actually
   running, the mandate's single dispatch identity proves to be doing two jobs
   badly. Deliberately last: it is the only item here that is speculative, and
   a running controller is the evidence that would settle it.

## What this does not propose

Nothing about the tick loop, the dispatch contract, or the sandbox boundary.
The controller supervises those; this review is about the controller's own
wiring and its conversation with an operator, not about the mechanism it minds.
