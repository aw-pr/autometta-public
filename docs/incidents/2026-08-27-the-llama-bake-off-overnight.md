# Run report: the Llama bake-off took four attempts and a night

**Repo:** `autometta` (self-host)
**Window:** 2026-08-26 22:03 to 2026-08-27 05:30 London
**Card:** `stage-cards/76-llama-sits-the-verifier-bake-off.md`
**Landed:** `a0415a6`, with the artefacts at `ffc6007` and the manifest repair at `c6c6ea6`
**Results and method:** [`docs/verifier-bake-off.md`](../verifier-bake-off.md). This file is the story of getting them; the tables live there and are not repeated here.

## Headline

One card, four attempts, three distinct failure classes, none of them
Llama's scoring. Two Sonnet workers abandoned a running batch the same
way against an explicit instruction; the benchmark manifest turned out
to have been quietly broken since card 50 moved the stage cards; and the
local timeout that card 46 shipped was tuned for generation when the
binding constraint on a 67 GB model is prompt ingestion. The batch
itself, once actually run to completion, produced clean results: eight
schema-valid verdicts of ten, two verdict-discipline failures recorded
as findings, 0 of 11 frontier FAILs recalled, and no change to the
standing recommendation.

## Timeline

**22:03.** The scheduled window opens. Ollama is up, `llama4:scout`
(67 GB) is resident, card 76 queues with a fresh run id and a Sonnet
worker seat. The seat is Claude by necessity, not preference: the
harness must reach Ollama at `localhost:11434`, and the codex
`workspace-write` sandbox denies network, the same class that parked
card 36.

**~22:20, attempt 1 stalls.** The heartbeat flags the stage. The worker
log ends with a sign-off: the batch is progressing, "I'll pause here and
pick back up automatically when the full batch finishes". A headless
`claude -p` session is one shot; when the process exits, nothing resumes
it, and the child batch died with the session. Three partial metadata
files were discarded with the worktree.

**22:45, re-brief attempt 2** (`76aeb33`): run the batch as one
foreground invocation and stay with it to completion; backgrounding it
or exiting while it runs is a failed attempt whatever the log says.

**~23:50, attempt 2 stalls the same way.** The worker backgrounded the
batch and exited at 0.8M tokens, with the sign-off almost word for word
the same. Zero artefacts this time. A behavioural instruction had now
been ignored twice by the same model on the same card, and a third
identical dispatch had nothing going for it.

**00:05, the orchestrator takes the batch inline.** The batch is
deterministic bash against a local server; it needs no model to run and
no sandbox exemption in an interactive session. First full run: five
stages error immediately, five time out.

**The manifest was rotten.** The five errors were `stage card not
found`: five benchmark rows pointed at
`/Users/AnthonyWest/repos/autometta-run-46-verifier-bake-off-.../examples/self-host/`,
an absolute path into card 46's own run worktree, torn down long ago.
Card 50 then moved the surviving cards from `examples/self-host/` to
`stage-cards/`, breaking the same rows a second way. Nothing noticed
because nothing had re-run the manifest since card 46's own batch.
Fixed and committed mid-run (`c6c6ea6`).

**The timeout was tuned for the wrong constraint.** The rerun at the
900 second local timeout passed exactly one stage, the one whose prompt
is 369 tokens. A probe against the resident model answered a trivial
prompt in 11 seconds, so generation was never the problem: a full
verifier prompt runs 5,000 to 10,000 tokens, and prompt ingestion on a
67 GB model under memory pressure is what eats the clock. The ladder,
for the record: 420 seconds (card 46's shipped default) timed out all
ten stages; 900 seconds passed one; 2,400 seconds passed eight, with
per-stage wall clocks of 840 to 2,292 seconds.

**Two stages failed verdict discipline, and that is a result.** On
`15c-sdk-verifier-integration` the model echoed the JSON schema back
instead of an instance of it; on `45-a-free-verifier-tier-on-local-weights`
it emitted JSON that does not parse. Both had their one permitted rerun
and failed it the same way. The card's own rule applied: a hole in the
results is a result. The holes are recorded in the metadata and in the
results document, not papered over.

**02:10, artefacts committed** (`ffc6007`), **card re-briefed to
documentation only** (`bd6a86b`): the batch stood done on dev, so
attempt 3's whole brief was the results tables, the methodology, and the
recommendation.

**04:47, attempt 3 passes six of seven.** Every substantive criterion
held: the verifier recomputed the agreement figures independently from
the artefacts and matched the document exactly. The one failure was the
em-dash rule, 41 lines, three of them added by the attempt itself.

**04:55, attempt 4** (`ca3fb7e`) restored the preserved tree, replaced
the em dashes with the punctuation each sentence wanted, and landed
(`a0415a6`) inside its 20 minute budget.

## What it cost

The batch itself cost no API tokens at all; the inference was local.
The spend went on the two abandoned worker attempts (about 2.8M tokens
between them), the docs attempt and its verifier pass, and the em-dash
attempt. The wall clock went on inference: ten stages at a mean of
about 21 minutes each, run twice over because of the timeout ladder.

## Lessons

1. **A worker's behavioural rules cannot be assumed, only briefed and
   then engineered around.** "Do not background the batch" failed twice
   in identical words. The durable fix was structural: move the
   long-running deterministic work to a place where a session exit
   cannot kill it, and leave the model work (writing, judging) to the
   model seats. If a card ever again pairs a one-shot session with a
   long blocking child, that is the defect, not the worker's manners.
2. **Holes are results.** Two discipline failures survived into the
   committed artefacts and the published tables as first-class rows.
   The bake-off exists to find exactly this; an 8 of 10 with named
   causes is worth more than a 10 of 10 that quietly reran until the
   output parsed.
3. **Harness rot has more than one cause.** The known risk was roster
   rotation on the cloud free tiers. The rot that actually bit was
   internal: an absolute path into an ephemeral worktree, then a repo
   reorganisation, neither detected because the manifest is only read
   when a bake-off runs. Anything consumed that rarely needs its paths
   checked by a smoke, not by the next person to run it.
4. **Budget local wall clock for prompt ingestion, not generation.**
   The 420 second default was generous for tokens out and hopeless for
   tokens in. For a local candidate the right sizing input is prompt
   length times ingestion rate at the model's real memory pressure,
   measured with one probe before the batch, not assumed from a
   smaller model's behaviour.

The stage card carries the same history as re-briefs; this report is
the cross-referenced narrative. The results document carries the
figures and the recommendation, which the night did not change.
