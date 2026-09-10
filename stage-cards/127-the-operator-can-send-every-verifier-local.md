# Stage card 127: the operator can send every verifier local

## Metadata

- **Authored:** 2026-09-06
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Verifier:** Codex GPT-OSS 120B <codex-gpt-oss-120b@local>
- **Base branch:** dev
- **Run branch:** autometta/127-the-operator-can-send-every-verifier-local
- **Worker effort:** medium
- **Verifier effort:** medium
- **Verifier panel:** false
- **Gate:** stage-completed: 126-the-verifier-does-not-think-harder-than-it-reads
- **Path claims:** scripts/models.sh, scripts/spawn-verifier.sh, scripts/cost-log.sh, scripts/verifier-route-override-smoke.sh, docs/dispatch-contract.md, stage-cards/127-the-operator-can-send-every-verifier-local.md
- **Pairing rationale:** the local seat verifies the card that makes the local
  seat reachable in bulk, which is the honest test of it: if the route this
  card exercises is broken, this stage cannot be judged at all, and that
  failure is itself the finding.
- **Type:** Dispatch routing override. Gated behind 126 because all three
  cards edit `scripts/models.sh` and `scripts/spawn-verifier.sh`.

## Surfacing concern

The local verifier route exists and nothing can select it in bulk.

`scripts/spawn-verifier.sh:694-699` already dispatches
`codex exec --oss --local-provider=ollama -m "$local_model"` behind
`codex_local_preflight`, and `codex_local_model_for_identity`
(`scripts/models.sh:65-73`) resolves the weights from the card's identity
string. `gpt-oss:120b` is pulled on this machine. The route works. The only
thing that reaches it is a card whose `- **Verifier:**` line names a local
identity, so switching a queue of seventeen stages to local verification means
hand-editing seventeen cards and hand-editing them back afterwards.

That matters right now because both cloud seats are constrained and they are
constrained separately. Since 2026-09-01 `state/cost-log.jsonl` records Codex
Sol verifiers at 38.6M tokens for **$97.14** — the most expensive tokens in the
ledger — and Claude Opus verifiers at 14.1M tokens drawn from the same
subscription window the workers need. Verification is the half of the fleet
that can move to local weights without touching the code that gets written.

There is a known way to get this wrong, and the repo already records it.
`scripts/models.sh` documents that before `codex_cloud_model_for_identity`
existed, "a card naming Luna ran Sol and the cost-log billed a T1 run at the T4
rate `tier_for_identity` read off the identity string." An override that
redirects the dispatch but leaves the card's identity in the ledger reproduces
that defect exactly, and it would do it fleet-wide.

## Objective

One operator-level switch sends every verifier dispatch to the local Ollama
route regardless of what its card names, and every record of that run — log
line, cost-log row, verifier envelope — says which weights actually ran.

## Inputs (read these in your own context)

- `scripts/spawn-verifier.sh:640-710`, the transport selection and the local
  branch, and `:530-545` where the identity and effort are resolved
- `scripts/models.sh:60-110`, `codex_local_model_for_identity`,
  `codex_cloud_model_for_identity` and the comment about the Luna/Sol
  mis-billing
- `codex_local_preflight` and `codex_local_model_for_role` in the same file
- `scripts/cost-log.sh`, specifically how `identity`, `tier` and `auth_route`
  are chosen for a row
- `scripts/validate-envelope.sh`, for whether the verifier envelope carries an
  identity field that must agree
- `docs/dispatch-contract.md`, the section on verifier transports

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. `scripts/models.sh` gains `AUTOMETTA_VERIFIER_ROUTE`, an environment-level
   override with exactly two accepted values: `card` (the default, today's
   behaviour) and `local`. An unrecognised value is a hard error at dispatch,
   not a warning — unlike a mistyped effort, a mistyped route silently spends
   real money on the seat the operator was trying to avoid.
2. When the route resolves to `local`, `scripts/spawn-verifier.sh` dispatches
   the verifier through the existing `--oss --local-provider=ollama` branch,
   on the model from `AUTOMETTA_MODEL_CODEX_LOCAL_VERIFIER` if set, otherwise
   `AUTOMETTA_MODEL_CODEX_LOCAL`, regardless of the identity the card names.
3. The **effective identity** — the one the local weights resolve to, e.g.
   `Codex GPT-OSS 120B <codex-gpt-oss-120b@local>` — is what reaches the log
   line, the cost-log row's `identity`, `tier` and `auth_route` fields, and the
   verifier envelope. The card's named identity is not written anywhere as if
   it had run. Where both are worth keeping, record the card's as an explicitly
   separate field, never as the identity.
4. The dispatch log line names both: what the card asked for and what actually
   ran, so an operator reading a log a week later can see the override was in
   force without reconstructing their shell environment.
5. When the route is `local` and `codex_local_preflight` fails, the dispatch
   **fails closed to no dispatch**. It must not fall back to the card's cloud
   seat: falling back to cloud is precisely the outcome the operator set the
   override to prevent, and doing it silently would spend the quota they were
   protecting.
6. `scripts/verifier-route-override-smoke.sh` covers: unset and `card` both
   preserving today's behaviour byte-for-byte; `local` redirecting a card that
   names a cloud identity; the per-role model override winning over the shared
   default; an unrecognised value erroring; a failed preflight producing no
   dispatch and no cloud fallback; and the cost-log row carrying the effective
   identity rather than the card's. It must fail against the pre-change tree —
   demonstrate that.
7. `docs/dispatch-contract.md` documents the switch, including the fail-closed
   rule and the attribution rule, and states plainly that it is a temporary
   operator lever rather than a property of any card.

## Constraints

- The worker seat is out of scope and must be untouched. This card moves
  verification to local weights; moving the seat that writes code is a
  different decision with different quality consequences.
- Do not edit any stage card to achieve this. If the override needs a card
  edit to work, it has failed its purpose.
- Do not change `codex_local_preflight`'s checks, only what happens when it
  fails on this path.
- Unset and `card` must be indistinguishable from the pre-change tree. This is
  a switch that is off by default.
- Stages 125 and 126 have landed against these files. Rebase on their result.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. `bash -n` clean across every script touched, and
   `scripts/verifier-route-override-smoke.sh`.
2. With `AUTOMETTA_VERIFIER_ROUTE` unset, an assembled verifier dispatch line
   for a card naming a cloud identity is identical to the one the base branch
   produces. Show both.
3. With `AUTOMETTA_VERIFIER_ROUTE=local`, that same card assembles a
   `codex exec --oss --local-provider=ollama` dispatch on the local model.
4. With the override in force, the cost-log row's `identity` and `tier` name
   the local weights, not the card's seat. Inspect an actual written row, not
   the code that would write it.
5. `AUTOMETTA_VERIFIER_ROUTE=cloud` — a plausible wrong value — errors and
   dispatches nothing.
6. With the override in force and preflight failing, nothing is dispatched and
   no cloud command line is assembled anywhere in the path. Establish this by
   forcing a preflight failure, not by reading the branch.
7. The worker dispatch line is unchanged with the override set and unset.
8. `scripts/turn-cap-smoke.sh`, `scripts/verifier-effort-default-smoke.sh` and
   `scripts/effort-flags-smoke.sh` all still pass.

## Contract test

- **Test file:** scripts/verifier-route-override-smoke.sh
- **Assertions digest:** frame the assertions in a block between the begin
  marker and the end marker, the begin marker naming this card by its
  `card=stage-cards/127-the-operator-can-send-every-verifier-local.md` field,
  and replace this line's text with the real digest printed by
  `scripts/check-contract-test-gate.sh print scripts/verifier-route-override-smoke.sh`.
  Do not write a `sha256:` comment inside the block, and do not spell the
  marker tokens anywhere in this card's prose; the card is in your path claims
  for exactly this edit.

## Out of scope

- A worker-side equivalent of this switch.
- Choosing which local model is best at verification, or any bake-off between
  them. `scripts/verifier-bake-off.sh` exists for that question.
- Per-repo or per-card policy for the override. It is an environment switch
  the operator sets for a window and unsets afterwards.
- Making the local route faster, or anything about Ollama's configuration.

## Budget

- **Worker wall-clock:** 60 minutes
- **Verifier wall-clock:** 30 minutes

## Escalation

If honouring the override cleanly turns out to require the effective identity
to be resolved before a point in `spawn-verifier.sh` where the card's identity
is already baked into other decisions — the transport choice, the sandbox, the
prompt — stop and report where that boundary is. Threading a second identity
through half the script is the kind of change that should be seen before it is
made, not discovered in the diff.

## Verifier handoff

Criterion 4 is the one to be hard about, and it cannot be judged from the code.
Cause a row to be written under the override and read `state/cost-log.jsonl`
yourself. A dispatch that correctly runs on local weights while still logging
the card's cloud identity is the exact defect `scripts/models.sh` already
records from the Luna/Sol case, it would corrupt every spend figure this fleet
reasons from, and it would pass every other criterion here.

Note your own position while judging: you are running on the local route this
card is about. If you cannot complete this verification at all, say so plainly
in the envelope rather than passing thin — that outcome is a finding about the
route's fitness for verification and the operator needs it stated.

## Family-specific notes

Codex only. The Claude verifier route has no local equivalent and is untouched
by this card: a card naming a Claude verifier still dispatches to Claude with
the override set. Say so in the docs, and log it when it happens, so an
operator who set the switch expecting the whole queue to go local is not
surprised by a Claude row in the ledger.
