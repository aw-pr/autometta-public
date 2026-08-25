# Stage card 61: the controller keeps a record and takes messages

## Metadata

- **Authored:** 2026-08-25
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Verifier:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Base branch:** dev
- **Run branch:** autometta/61-the-controller-keeps-a-record-and-takes-messages
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Gate:** after 58. That card creates the controller; this one makes it
  auditable and reachable.
- **Pairing rationale:** the deliverable is a record a human reads and a
  channel a human writes to, so the family that will be read writes it, and
  the other family verifies that a message cannot widen the mandate.

## Objective

The point of the controller is to run Autometta with no session attached.
That is only safe if two things are true afterwards, and neither is true
today.

**You can see what it did.** Card 58 gives it a decision journal, which
records each decision as structured data before it acts. That is not a
transcript. The journal says what was decided; it does not say what was
read, what was considered and rejected, or why. When a controller does
something surprising at 3am, the journal tells you the verdict and nothing
about the reasoning.

**You can say something back.** Right now there is no way to reach a
running controller at all. Correcting it means stopping it, editing its
seed, and starting again, which loses whatever it was in the middle of.

This card adds a recorded turn history and an inbox, and closes one
concurrency hole found the hard way.

## The concurrency hole

On 2026-08-25 an ad-hoc minder script watched for stranded work and
committed it to a wip branch when it saw no live agent. It was correct that
no agent was running. It was wrong that nothing was happening: the tick was
mid-landing, and the stage fast-forwarded onto dev carrying a `wip(...)`
message with no author and no `Autometta-*` trailers. The work was intact
and the record of it was wrong.

`tick.sh` takes a lock at `state/.tick.lock` before it touches a repo. The
minder did not. "No live agent" is not the same fact as "the tick is not
mid-transaction", and a controller that conflates them will corrupt the
record of correct work. The controller must take the same lock.

## Inputs (read these in your own context)

- `docs/proposals/orchestrator-role-review.md`, particularly the negative
  list and the sentence that governs it.
- Card 58 and whatever it landed: the seed, the mandate, the decision
  journal schema, the verbs.
- `scripts/tick.sh`, the lock helper at the top of the file.
- `memory/README.md` for the append-only convention, which is the closest
  existing thing to a turn record.
- The handoff-envelope docs, for how this repo already models a structured
  artefact an agent writes and another process reads.

## Deliverables

1. **A recorded turn history.** Every controller pass persists its
   transcript at a predictable path, indexed so a human can find the pass
   that made a given decision. Predictable, not harness-generated: gotcha 3
   applies to this as much as to a worker log.
2. **An inbox.** A human, or an interactive session, leaves a message for
   the controller on the filesystem. The controller reads its inbox at the
   start of each pass, before it decides anything, and records both the
   message and what it did about it.
3. **A reply.** The controller's answer goes somewhere a human can read
   without attaching to anything. A message that is read and silently
   ignored is worse than no inbox at all.
4. **The tick lock.** The controller takes `state/.tick.lock` before any
   mutating action and releases it after, so it and the tick cannot both be
   inside the same transition.
5. **Retention and privacy.** Transcripts are bounded, pruned on a stated
   schedule, and private-tier: never on the publish branch, covered by the
   `publishguard.privatefile` guard.

## Constraints

- No daemon, no service, no port. The filesystem is the message bus; that
  is a load-bearing belief of this repo, not a preference.
- **An inbox message is an instruction to consider, not a command to
  obey.** It cannot widen the mandate, lift a prohibition, or authorise
  anything the negative list forbids. A message asking for an acceptance
  criterion to be edited is refused and the refusal is recorded. This is
  the same anti-gaming rule as the negative list, arriving through a new
  door.
- No credential material in a transcript. The verifier is expected to look.
- A transcript is a record, not a queue: the controller never resumes from
  one or treats it as instruction.
- If the lock cannot be taken, the controller waits or skips the pass and
  says which. It never proceeds without it, and it never breaks a lock it
  did not take.

## Acceptance criteria

1. A controller pass writes a transcript at the documented path, and the
   index resolves a decision in the journal to the pass that made it.
2. A message left in the inbox is read at the start of the next pass and
   appears in that pass's record with what was done about it.
3. A reply is readable without attaching to any session. Show it.
4. A message that asks for something the negative list forbids is refused,
   the refusal is recorded with its reason, and nothing changes on disk.
   Show the tree unchanged.
5. The controller blocks when the tick holds `state/.tick.lock`, and the
   tick blocks when the controller holds it. Demonstrate both directions.
6. Replay the 2026-08-25 race: a controller trying to preserve stranded
   work while the tick is mid-landing must wait, and the resulting commit
   must carry the proper stage message and `Autometta-*` trailers rather
   than a `wip(...)` message.
7. No credential material appears in any transcript, inbox entry, or reply.
   Show the grep.
8. Transcripts are pruned per the stated retention, and the publish guard
   refuses a transcript on the publish branch. Show both.

## Contract test

Run two passes with a message left between them. The first pass records its
turns; the message is picked up at the start of the second, answered in its
record, and the answer readable from outside. Then repeat with a message
that asks the controller to soften an acceptance criterion, and show the
refusal recorded and the card untouched.

## Out of scope

- A live attach or streaming interface. Reading a file after the fact and
  leaving a message for next pass is the whole of it.
- A second reviewing controller. Card 58 leaves that seam; this card feeds
  it by making the record richer, and still does not build it.
- Any change to what the negative list contains.

## Budget

- **Worker wall-clock:** 120 minutes
- **Verifier wall-clock:** 60 minutes

## Verifier handoff

Return a transcript and its index entry, the inbox round trip with its
reply, the refused message with the unchanged tree, both directions of the
lock contention, the replayed race with its correct commit message, the
credential grep, and the retention and publish-guard evidence.

## Family-specific notes

None
