# Stage card 131: a card carries its own oracle

## Metadata

- **Authored:** 2026-09-06
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Codex GPT-5.6 Sol <codex-gpt-5-6-sol@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Base branch:** dev
- **Run branch:** autometta/131-a-card-carries-its-own-oracle
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/add-stage.sh, scripts/card-template-smoke.sh, templates/stage-card.md, docs/dispatch-contract.md, stage-cards/131-a-card-carries-its-own-oracle.md
- **Pairing rationale:** cross-family. The change is small and the failure it
  guards against is subtle: a refusal that is too broad blocks every prose
  card at queue time, and one too narrow lets the instruction text through
  again. A different family reads the refusal condition without the
  implementer's assumption about what the digest line looks like.
- **Type:** Card contract. Touches no runtime, so it pairs.

## Surfacing concern

`docs/dispatch-contract.md:131` is explicit: "**Orchestrator authors the
assertions (step 1).** They are written from the card's intent, before any
implementation exists, by the session that already owns the acceptance
criteria. The worker does not author its own oracle, so the test cannot be
tautological." `templates/worker-prompt.md:22` says the same from the
worker's side and forbids editing the frozen block.

The shipped `templates/stage-card.md` says the opposite. Its Contract test
section reads, in the card the worker is handed:

> **Assertions digest:** frame the assertions in a block between the begin
> marker and the end marker [...] and replace this line's text with the real
> digest printed by `scripts/check-contract-test-gate.sh print <file>`.

That instruction is addressed to whoever holds the card at dispatch, which
is the worker. So a card generated from the template asks the worker to
write the assertions it will be judged against, and to record their digest,
which is the tautology the contract exists to prevent.

This is not hypothetical and it is not rare:

- **Card 113** was refused before implementation by its Codex worker, which
  cited the worker contract and declined. It cost 822k tokens to discover a
  defect in the template.
- **Card 114** carried the same instruction, pointed at a file whose one
  frozen block already belonged to card 105.
- **Card 124 landed with a worker-authored contract test.** Its worker
  followed the instruction, its verifier recomputed the digest and passed
  it, and nothing in the process noticed. Its verdict should be read
  knowing that.

Nothing catches it. `scripts/add-stage.sh` queues a card whose digest line
is prose, and `scripts/check-contract-test-gate.sh` only compares the card's
recorded digest against the file at commit time, by which point the worker
has written both sides.

## Objective

A card that names a contract test carries its digest when it is queued. The
template stops asking the worker to author its own oracle, and the queue
refuses a card that would.

## Inputs (read these in your own context)

- `templates/stage-card.md`, the Contract test section
- `scripts/add-stage.sh`, the queue-time validation
- `docs/dispatch-contract.md:120-190`, the contract-test design and the
  "not every stage earns one" escape at :172
- `templates/worker-prompt.md:22` and `:74`, the worker's side of it
- `scripts/card-template-smoke.sh`, the frozen assertions for this card

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. `templates/stage-card.md`'s Contract test section is rewritten to address
   the orchestrator, not the worker: it states that the assertions are
   authored before dispatch, that the digest is recorded on the card at
   queue time, and that the worker must not touch the block. The instruction
   telling the reader to replace the line with a computed digest is gone.

2. `scripts/add-stage.sh` refuses a card that names a **Test file** but
   whose **Assertions digest** is not a `sha256:` value, with a message
   naming the card, the test file, and the command that prints the digest.
   A card that declares no contract test still queues: prose-only acceptance
   is permitted by `docs/dispatch-contract.md:172` and this card does not
   narrow it.

3. `docs/dispatch-contract.md` states the queue-time check as part of step 1
   and names what it caught: three cards in the 108-124 batch, one of which
   landed.

## Constraints

- Do not change `scripts/check-contract-test-gate.sh`. The commit-time gate
  is correct; the hole is upstream of it at queue time. Card 121 owns that
  script in this batch and a second claim on it would serialise both.
- Do not retro-fit digests onto already-queued cards, and do not rewrite
  landed ones. Card 124 keeps its history.
- Do not make the digest mandatory for every card. A card with no contract
  test is a legitimate shape.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. A card naming a test file whose digest line is the template's instruction
   text is refused at queue time, and the refusal names the digest.
2. A card naming a test file with no `sha256:` value is refused.
3. A card naming a test file with a real `sha256:` value queues.
4. A card whose Contract test section is `None` queues.
5. `templates/stage-card.md` no longer contains the instruction to replace
   the digest line, and says who authors the assertions.
6. `scripts/card-template-smoke.sh` passes and fails against the pre-change
   `scripts/add-stage.sh`.
7. `scripts/gate-smoke.sh` and `scripts/pipeline-pair-smoke.sh` are no more
   red than on clean `dev`.

## Contract test

- **Test file:** scripts/card-template-smoke.sh
- **Assertions digest:** `sha256:3f08c95c71fec6d90c1628216212a95a6bc5c0dd2d733af94f3e02461abc2784`

The file and its frozen block are **already written**, by the orchestrator,
before any implementation exists -- which is the point of this card. Do not
author, extend or edit the block: satisfy it by changing the implementation.
It currently fails at the first assertion, which is correct. Fixtures and
scaffolding may be added outside the markers. If you become convinced an
assertion is wrong, stop and surface it as a blocker; the verifier
recomputes this digest and fails the stage if the assertions moved.

## Out of scope

- The commit-time gate, `scripts/check-contract-test-gate.sh`.
- Re-verifying card 124 under an orchestrator-authored test.
- Any change to how the frozen block is delimited or digested.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes

## Escalation

If refusing the instruction text cannot be done without also refusing a
legitimate card shape, stop and report rather than widening the refusal. A
queue check that blocks good cards is worse than the defect it replaces.

## Verifier handoff

The trap here is a refusal keyed to the template's exact instruction string.
That passes every assertion and catches nothing the day someone reword the
template. Check what the refusal actually tests: it must be "this is not a
sha256 value", not "this is the sentence I saw". Try a card whose digest
line is some third thing -- a TODO, an empty value, a bare hex string with
no `sha256:` prefix -- and satisfy yourself the rule generalises.

Then check criterion 4 honestly. A `None` contract test must still queue,
and the obvious implementation checks for a Test file line before demanding
a digest; make sure it does not instead demand the section be absent.

## Family-specific notes

None
