# Stage card 46-verifier-bake-off-local-against-cloud-free: which free verifier can be trusted, measured against verdicts we already know

## Metadata

- **Authored:** 2026-08-23
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Verifier:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Worker effort:** high
- **Verifier effort:** medium
- **Verifier panel:** false
- **Worker wall-clock:** 120 minutes
- **Verifier wall-clock:** 45 minutes
- **Pairing rationale:** an evaluation harness plus a measurement writeup,
  which is analysis-heavy and wants the Claude side; Codex verifies the
  harness mechanics cross-family. Depends on card 45's local route landing
  first, and on the OpenRouter fallback it documents.

## Objective

Card 45 gives the codex family a free local route and documents a cloud
free route. This card answers the question 45 deliberately deferred: which
of the free options is actually good enough to trust as a verifier, and for
which kinds of stage?

The operator's ask, 2026-08-23: bigger models than the machine can hold run
free in the cloud; compare Qwen, Grok and the rest against the local
weights before betting overnight runs on any of them.

## The candidate table (investigated 2026-08-23)

| Candidate | Where | Size | Cost | Hard limits |
|---|---|---|---|---|
| `gpt-oss:120b` | local Ollama, proven by card 45's probe | 120B MoE | $0 | none; ~66s cold load, fits 96GB |
| `qwen3-coder:30b` | local Ollama, already pulled | 30B | $0 | none; the fast local option |
| `qwen/qwen3-coder:free` | OpenRouter | 480B-A35B MoE, 1M context | $0 | 20 req/min; 50 req/day, 1,000/day after a one-time $10 credit purchase |
| DeepSeek R1 (`:free`) | OpenRouter | 671B MoE | $0 | same free-tier caps; list rotates without notice |
| Grok (any tier) | xAI / OpenRouter | - | paid | no usable free API route found; xAI's coding model is paid on OpenRouter. Drop unless this changes |

Grok is in the table to record the negative result: the operator named it,
and the investigation found no free route worth building against. Puter-style
"free unlimited Grok" proxies exist and are not acceptable: an unofficial
proxy inside the verification path is a supply-chain risk in exactly the
place whose job is to be trustworthy.

The OpenRouter daily caps shape the design: at 50/day an agentic verifier
that burns several requests per criterion exhausts the quota in one or two
verifications, so the cloud candidates are only usable in single-shot mode
(one request: card, diff and evidence in, verdict JSON out), not as
tool-looping agents. That is a different verifier shape from the CLI one,
and this card measures whether the shape loses more than the parameters
gain. The one-time $10 unlock to 1,000/day is the operator's call and
changes the arithmetic if taken.

## Method: retro-grading against verdicts we already trust

The repo already owns the harness shape: `scripts/retro-grade.sh` re-runs
the verifier rubric over completed stages. This card generalises the idea
into a bake-off. The ground truth is the set of stages across the fleet
that already carry a frontier verdict artefact in `state/verifiers/` -
emergence-lab and autometta together hold 40+, including genuine FAILs
(05, 14, 15, 16 among them) and genuine PASSes.

For each candidate x each benchmark stage: reconstruct the verifier's
inputs (card, artefact, diff), obtain a criterion-level verdict, and score
it against the recorded frontier verdict. Report per candidate:

- **FAIL recall** - of criteria the frontier verifier failed, how many the
  candidate also fails. This is the number that matters: a verifier that
  misses real failures merges broken work.
- **PASS agreement** - of criteria the frontier verifier passed, how many
  the candidate passes. Low agreement here is cheap (a false FAIL costs a
  requeue, not a bad merge) but constant false FAILs burn attempts.
- **Artefact discipline** - does it produce parseable verdict JSON every
  time. A verifier whose output cannot be parsed is a stalled stage.
- **Wall clock and, for cloud, requests consumed** per verification.

## Deliverables

1. `scripts/verifier-bake-off.sh` - runs one candidate over one benchmark
   stage and emits a comparable verdict JSON; a batch mode loops the
   matrix and respects the OpenRouter per-minute and per-day caps with
   plain sleeps and a hard daily stop (budget file, not retries).
2. An OpenRouter single-shot caller for the cloud candidates, routed
   through op-fetch with `OPENROUTER_API_KEY` from op-refs, fail-closed
   when the ref is unset. Reuse the card-45 route machinery where it fits;
   do not build a fourth auth path.
3. `docs/verifier-bake-off.md` - the results table, the per-candidate
   recommendation (trust for mechanical acceptance / trust generally / do
   not trust), and the raw verdict artefacts checked in under
   `examples/bake-off/` so the conclusion can be re-derived.
4. A recommendation in the same doc on the default local model for card
   45's `AUTOMETTA_MODEL_CODEX_LOCAL`, now backed by measurement, and on
   whether the $10 OpenRouter unlock is worth taking.

## Constraints

- Read-only on every benchmark repo. Reconstruction of verifier inputs
  must not touch subscriber state.
- The cloud callers never see repo secrets: the card, the diff and the
  evidence go out; nothing from `.autometta.local.yaml`, op-refs or the
  controller home does. State plainly in the doc that cloud verification
  ships the diff to a third party, so private-tier repos stay local-only.
- Free-tier caps are respected as stated limits, not raced: 20/min, and
  stop at the daily cap. No key rotation, no multi-account tricks.
- Spend for the bake-off itself: $0 on codex API, $0 on OpenRouter
  (unless the operator takes the $10 unlock first), subscription-route
  Claude only for the harness work itself.
- British English, no em dashes.

## Acceptance criteria

1. The matrix ran: every candidate in the table (Grok excluded, reason
   recorded) over at least 10 benchmark stages including at least 3 with
   frontier FAIL verdicts, or the daily-cap arithmetic showing why fewer
   cloud runs were possible, with the shortfall named.
2. FAIL recall, PASS agreement, artefact discipline and cost-in-time
   reported per candidate in `docs/verifier-bake-off.md`.
3. Every score is re-derivable from checked-in artefacts.
4. The OpenRouter caller fails closed with no key, and its request count
   per verification is measured and reported.
5. A stated recommendation: which candidate (if any) becomes the default
   free verifier, for which stage kinds, and what stays frontier-only.
6. Existing offline smoke scripts still pass; `sdk-cache-smoke.sh` needs
   live credentials and is not run: say so.

## Out of scope

- Wiring any cloud candidate into spawn-verifier.sh as a dispatch route.
  Measurement first; a route card follows only if a cloud candidate wins.
- Paid Grok, paid OpenRouter tiers beyond the one-time unlock decision.
- Worker bake-offs. Verifiers only, as card 45.
- Fine-tuning, prompt-tuning per candidate beyond one shared verifier
  prompt adapted to single-shot shape.

## Budget

- **Worker wall-clock:** 120 minutes
- **Verifier wall-clock:** 45 minutes

## Notes for the worker

- Depends on card 45: the local candidates dispatch through its route.
  If 45 has not landed, run the local candidates through the probe-style
  direct invocation and say so.
- The frontier verdicts are ground truth with known dirt: cards 14, 15,
  16 were later retired as overtaken (see card 43), yet their FAIL
  verdicts were correct at the time and stay valid benchmark points; the
  criteria they failed were genuinely unmet.
- Single-shot means the candidate cannot gather evidence itself. Package
  the same evidence for every candidate so the comparison is of judgement,
  not of retrieval.
- 20 req/min is per key: the batch loop can interleave candidates but
  must serialise per provider.
