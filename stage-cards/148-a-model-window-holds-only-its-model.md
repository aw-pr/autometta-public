# Stage card 148: a model window holds only its model

## Metadata

- **Authored:** 2026-10-09
- **Orchestrator:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Base branch:** dev
- **Run branch:** autometta/148-a-model-window-holds-only-its-model
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/quota-window.sh, scripts/tick.sh, scripts/model-window-smoke.sh, docs/tick-loop.md
- **Pairing rationale:** Terra for the plumbing: one optional argument on a
  pure gate and two callers that already hold the identity. Opus verifies
  because a fault here either stalls the queue for days or spends a window
  the operator asked to keep, and the verifier can run the real reader
  against the live snapshot, which a Codex sandbox cannot see. Not Fable:
  the card exists because the Fable window was the one past its line.

## Surfacing concern

On 2026-10-09 the 145-147 batch stopped after 145's worker passed. The
Claude reading carried `Weekly` at 46% and `Weekly (Fable)` at 73%, the
mandate holds at a 30% reserve, and `quota_gate_reading` takes the
most-used window of the family. So the Fable window held 145's Opus 5.5
verifier, which never draws on it, and the tick paused the whole repo
until the Fable reset three days out. The operator opened a watched
`--ignore-reserve` drain to get past it, which also lifted the hold on the
family `Weekly` window the reserve exists to protect.

A window scoped to one model belongs only to the seats that run that model.
The family windows still bind everyone.

## Objective

The reserve gate consults a model-scoped window only for a seat that runs
that model. Both callers that can name the seat do so: the tick's role gate
from the stage identity, and the manual spawn gate from the card's Worker
line. A caller that cannot name its seat sees every window, exactly as
today.

## Inputs (read these in your own context)

- `scripts/model-window-smoke.sh`: the frozen contract; read it first.
- `scripts/quota-window.sh`: `quota_gate_reading` and `quota_spawn_permits`.
- `scripts/tick.sh`: `quota_gate_family_dispatch` and
  `quota_gate_role_dispatch`.
- `scripts/models.sh`: `claude_model_for_identity`, which turns an identity
  into the model id the dispatch actually runs. Read it; do not edit it.
- `docs/tick-loop.md`: the paragraph "Claude retains the provider-window
  reserve".

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `quota_gate_reading <reading> <reserve> <action> [model]`: with a
   non-empty model, a window is skipped when it is scoped to a model that
   is not this one. A window is scoped when its `key` is `<period>-<name>`
   for a period the reader already emits (`weekly`, `5-hour`) and a
   non-empty name; it is this model's when the model id contains `<name>`
   as a hyphen-delimited segment (`claude-fable-5-1` matches `fable`). An
   unscoped window binds every model. With no model, or an empty one,
   every window binds, as today. The most-used binding window is still the
   one reported in `QUOTA_GATE_WINDOW` and `QUOTA_GATE_RESET`.
2. `quota_gate_family_dispatch <repo> <family> <what> [model]` passes the
   model through, and its hold log line names the model when one was given.
3. `quota_gate_role_dispatch` resolves the role's model with
   `claude_model_for_identity` for a claude identity and passes it on.
   Codex seats are unchanged: their reading carries no scoped windows.
4. `quota_spawn_permits <repo> <family> [card]`: for the claude family with
   a card, the model comes from the card's Worker line. Without a card,
   every window binds, as today.
5. `docs/tick-loop.md`: the reserve paragraph says a model-scoped window
   holds only the seats that run that model, names the key shape, and says
   an unnamed seat sees every window.

## Constraints

- The frozen block in `scripts/model-window-smoke.sh` is read-only to you.
  A blocker with an assertion is reported in the envelope, not edited away.
- `scripts/phat-controller.sh` is not claimed: its pass names a family, not
  a seat, and stays conservative.
- No change to the reader (`scripts/quota-window.py`), the mandate shape,
  the codex card policy, drains, the schedule or curfew.
- A hold still pauses the repo to the binding window's reset; this card
  changes which windows bind, not what a hold does.
- British English in prose, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. `bash scripts/model-window-smoke.sh` passes on the run branch, run by the
   verifier, and `scripts/check-contract-test-gate.sh print
   scripts/model-window-smoke.sh` prints the digest recorded below.
2. `bash -n` passes on every changed shell file, and
   `scripts/reserve-default-smoke.sh`, `scripts/session-window-smoke.sh`,
   `scripts/codex-card-quota-smoke.sh` and `scripts/quota-window-smoke.sh`
   still pass; record any failure that already exists on the base commit
   separately, and any new failure fails this card.
3. Against the live reading (`python3 scripts/quota-window.py claude`), the
   verifier sources the candidate gate and records the result of
   `quota_gate_reading` at the mandate's reserve for `claude-opus-5-5`,
   `claude-fable-5-1` and no model, and says whether each matches the rule
   in deliverable 1 for the utilisations it read.
4. Every call to `quota_gate_reading`, `quota_gate_family_dispatch` and
   `quota_spawn_permits` in `scripts/` either passes a model or is one of
   the conservative callers named in this card; the verifier lists them.
5. `docs/tick-loop.md` describes the rule and nothing in it still says the
   most-used window of the family always binds.
6. `git diff --stat` on the run branch touches only the claimed paths.

## Contract test

- **Test file:** scripts/model-window-smoke.sh
- **Assertions digest:** `sha256:c32a4d6f0d0eca632ff420cd5c66518d8bdfb5aee4e99554094ade3d5904f1f2`

The orchestrator authored the frozen block on 2026-10-09 from the reading
`quota-window.py` printed that day. It fails today at its first assertion,
because the Fable window holds Opus, which is the defect. With the
assertions softened every block is reached, and the only assertions that
fail are the ones that name the defect: the conservative cases (Fable held,
no model held, family window holds Opus) already pass and must keep
passing.

## Out of scope

- Ending or reshaping the 2026-10-09 drain; it expires by itself.
- The phat-controller pass naming a seat.
- A per-model reserve percentage in the mandate.
- Reading which windows a provider scopes from anywhere but the key.

## Budget

- **Worker wall-clock:** 25 minutes
- **Verifier wall-clock:** 20 minutes
- **Spend basis:** one median pair from `state/cost-log.jsonl` (worker
  0.9M, verifier 1.0M tokens on the heartbeat baseline of 2026-10-09);
  planning allowance 4M tokens, subject to live admission. No cap change
  or drain is authorised by this card.

## Dispatch envelope

Write `state/envelopes/148-a-model-window-holds-only-its-model.json` using
`schemas/envelope.json`. List changed deliverables, the exact smoke commands
and their results, and any criterion you could not satisfy with why. Do not
self-verify or land your own branch. The verifier writes
`state/verifiers/148-a-model-window-holds-only-its-model.json` under the
existing verifier contract, giving a criterion-by-criterion verdict.

## Family-specific notes

The worker is a Codex seat under `workspace-write`: the smoke is offline and
needs no network grant, but the worker cannot read the operator's live quota
snapshot, which is why criterion 3 belongs to the verifier. `tick.sh` runs
under `IFS=$'\n\t'`; keep any multi-token argument list in an array (gotcha
12). macOS `date` has no `-d`; the smoke already falls back for both.

## Re-brief after attempt 1 (2026-10-09)

Attempt 1 passed criteria 1-6 and failed on one regression the verifier
found. Its work is pinned at `d08063587b5a04736ba17d1736506f241a0ebf64` on
`wip/148-a-model-window-holds-only-its-model-attempt-1`. Start from that
commit (`git cherry-pick` or read it) rather than from scratch: the gate,
the role-gate wiring and the doc paragraph were judged correct.

The defect: `quota_spawn_permits` gained `[[ "$family" == codex ]] &&` in
front of `quota_codex_card_policy`. That skips the Codex admission check for
a manual spawn of a Claude worker whose card names a Codex subscription
verifier, which `CLAUDE.md` documents ("This also checks a Codex verifier
before admitting its Claude worker"). Leave that branch exactly as it is on
`dev`; the model only feeds the Claude reserve check further down.

Added constraint: no change to the Codex card-admission branch of
`quota_spawn_permits` or `quota_gate_role_dispatch`.

Added acceptance criterion 7: the regression block after
`AUTOMETTA-CONTRACT-END` in `scripts/model-window-smoke.sh` passes. It was
added by the orchestrator on re-brief, sits outside the frozen block (the
digest is unchanged), passes on `dev` and fails on the attempt-1 commit.
