# Design: Fable-as-advisor verifier

Design-only. No code ships with this document. Implementation, if pursued, is a future card gated behind a flag.

## Problem

Verification is a judgement task wrapped in a lot of reading. The verifier prompt is dominated by tokens it must read but not reason hard about: the cached rubric block, the stage card, and the worker artefacts. The expensive part is concentrated at one or two points, namely deciding whether a given criterion is met by the evidence on the working tree. Running a frontier model such as Claude Fable 5 for the whole pass pays frontier price on every read token, most of which buys no extra judgement. The question this design answers is how to put frontier judgement at the decision point without paying frontier price across the entire prompt.

## Advisor tool shape

The `advisor_20260301` strategy lets a cheap request model consult a stronger model mid-task. Two model slots matter and must not be confused:

- **Request model**: the model the `messages.create` call runs on. Here it is a cheap model, for example `claude-sonnet-4-6`. It reads the rubric, card, and artefacts and drafts the per-criterion verdicts.
- **Advisor model**: the model named inside the advisor configuration. Here it is `claude-fable-5`. The request model calls the advisor with its draft verdict and the relevant evidence; the advisor returns a short judgement; the request model finalises the JSON envelope.

This is an Anthropic-only feature. When a GPT or Codex model is the request model there is no native advisor tool, so the variant applies to Claude verifiers only.

## #66714 ordering

The advisor must not be weaker than the request model. The exact failing configuration is a request whose request model is `claude-fable-5` with the advisor pinned to `claude-opus-4-8`: that call returns HTTP 400. Putting the strong model on the request and the weaker model on the advisor is the trap.

The correct ordering inverts it: request model `claude-sonnet-4-6` (cheap, does the reading), advisor `claude-fable-5` (strong, does the judging). The prototype must assert this precondition before the call and reject a request-stronger-than-advisor pairing with a clear local error, so the ordering is enforced by us and never discovered as a 400 from the API.

## Where it lives

Extend `scripts/verify-sdk.py`; do not add a sibling. That script already owns the Anthropic `messages.create` path, the cacheable static block, a `--model` argument, schema validation, and cost-log output. The advisor is one extra request parameter on that existing call plus the ordering guard. A sibling script would duplicate prompt assembly, validation, and cost-log emission for no benefit.

Gate it behind a flag (for example `--advisor claude-fable-5`, or `verifier.claude.advisor` in `.autometta.local.yaml`), default off, so the default SDK route and the CLI route are unchanged. `spawn-verifier.sh` already selects sdk against cli; the advisor sits under the sdk branch only.

## Relationship to cross-family verification

The explicit answer: an Anthropic advisor does not replace cross-family verification, and it does not weaken the Codex-checks-Claude property when used correctly.

Cross-family means worker in family A, verifier in family B, so that no single family both writes and blesses the work (belief 4). The advisor is internal to the verifier. On a Codex-worker stage with a Sonnet-plus-Fable-advisor verifier, the verifier is still a different family from the worker, so the anti-collusion property holds; both verifier slots being Anthropic is irrelevant because the worker is not Anthropic. On a Claude-worker stage, a Claude verifier is already same-family and already needs an explicit rationale in the card per `docs/verification.md`; the advisor does not change that posture, it only makes that same-family verifier cheaper while keeping a frontier opinion in the loop. Conclusion: the advisor is an addition to a verifier, orthogonal to the worker-against-verifier family split. It is not a substitute for cross-family pairing and must not become the default.

## Cost model

Running Fable whole bills every input token (rubric, card, artefacts) and every output token at the T0 rate (10.0 in, 50.0 out per Mtok). The advisor route runs the bulk prompt on Sonnet at T2 (3.0 in, 15.0 out) and bills only the advisor exchange, a few hundred input tokens and a short verdict out, at the Fable rate. For a verifier prompt dominated by artefact reading, that is a large saving while the frontier judgement stays where it earns its cost. Two honest caveats: the advisor adds a round trip and some latency to each verification; and a stage that genuinely needs frontier reasoning across the whole artefact set, which is rare for criterion checks, is better served by the whole-Fable pass.

## Auth and billing route

API-only. The advisor tool is an Anthropic API feature and is not on the subscription CLI route, so it is gated to `auth.claude.mode: api`, the same fail-closed precondition `verify-sdk.py` already requires for the sdk transport. Fable 5 carries the org-wide 30-day data-retention commitment (misuse detection, not training). The advisor sends verifier prompt content, including the stage card and artefacts, to Fable, so that retention note covers whatever a verified repo's artefacts contain. Tooling and public repos are fine; do not point this at a repo whose artefacts carry personal data.

## Smallest prototype outline

**Stage NN-advisor-verifier-proto** (single verifier, opt-in):

- **Objective:** an optional `--advisor MODEL` argument on `verify-sdk.py` that confines the frontier model to the advisor slot.
- **Deliverables:** the argument; an ordering guard that rejects an advisor weaker than `--model` before any API call (the #66714 guard); the advisor config attached to the existing `messages.create`; a cost-log line tagged with the advisor model.
- **Acceptance:** with `--advisor` unset, behaviour is byte-identical to today; with `--model sonnet --advisor fable`, one verification runs and the cost-log shows Sonnet request tokens plus a Fable advisor line; `--model fable --advisor opus` is rejected locally before any call.
- **Out of scope:** panel mode, and auto-selecting which criteria escalate to the advisor.

## Recommendation

Prefer the advisor over a full Fable verifier: the same frontier judgement at a fraction of the cost, with the expensive model confined to the decision point. Keep it SDK-only because the tool is API-only and `verify-sdk.py` already owns that path. Keep it opt-in and default off; it is an addition to a verifier, never a replacement for cross-family pairing. What would make us not do it: if the advisor round trip dominates tick budgets, or if a cheap request model plus an advisor proves less reliable in practice than a single strong pass.
