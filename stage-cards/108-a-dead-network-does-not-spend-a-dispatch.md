# Stage card 108: a dead network does not spend a dispatch

## Metadata

- **Authored:** 2026-09-06
- **Orchestrator:** Claude Fable 5.1 <claude-fable-5-1@local>
- **Worker:** Claude Opus 5 <claude-opus-5@local>
- **Verifier:** Codex GPT-5.6 Sol <codex-gpt-5-6-sol@local>
- **Base branch:** dev
- **Run branch:** autometta/108-a-dead-network-does-not-spend-a-dispatch
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/tick.sh, scripts/preflight-network.sh, scripts/network-fault-smoke.sh, docs/tick-loop.md, stage-cards/108-a-dead-network-does-not-spend-a-dispatch.md
- **Pairing rationale:** cross-family. The worker changes the tick's fault classification, which is
  the one place a wrong pattern turns a single outage into a failure-cap
  halt; the verifying seat verifies because it can construct the fault log
  fixtures without having read the worker's regex.
- **Type:** Alarm and guard. Touches `scripts/tick.sh`, so serial.

## Surfacing concern

On 2026-09-03 the machine's resolvers went dead at about 22:35
(`docs/runs/2026-09-03-evening-watch.md:23-25` in emergence-lab). One fault
cost: a worker that sat 50 minutes retrying `Request timed out` until the
wall-clock stall cut it; two dispatches that died at launch on
`op-fetch: error: failed to resolve CLAUDE_CODE_OAUTH_TOKEN (op exit 1)`; and
the quota reader going `unknown (snapshot stale)`. Each launch failure was
counted as a worker stall against `consecutive_failures`, because the
instant-fault pattern at `scripts/tick.sh:446` matches `op-fetch not on
path` and `auth-route resolver failed` but not `failed to resolve`. Three
symptoms, one cause, and the tick treated them as three unrelated worker
failures.

## Objective

The tick refuses to spend a dispatch on a network it has just measured as
dead, and when a dispatch dies on a credential-resolution failure it halts
once with that reason instead of burning the failure cap.

## Inputs (read these in your own context)

- `scripts/tick.sh:414-470`, `is_instant_dispatch_configuration_fault` and
  `halt_dispatch_configuration_fault`, and their two call sites at `:2800`
  and `:2953`
- the worker and verifier dispatch sites in `scripts/tick.sh` (grep
  `spawn_worker_for_stage` and `spawn_verifier_for_stage`), where the
  preflight belongs
- `docs/tick-loop.md`, the section on dispatch-configuration faults
- emergence-lab `docs/runs/2026-09-03-evening-watch.md:23-25` for the
  exact log text of both failure shapes

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. `scripts/preflight-network.sh`: resolves `api.anthropic.com` and
   `api.openai.com` through the system resolver (`dig +short` with no
   `@server`, falling back to `getent`/`host` if `dig` is absent) with a
   short timeout, exits 0 when both resolve, non-zero with a one-line reason
   naming the host and the first resolver tried when either does not.
2. `scripts/tick.sh` runs the preflight immediately before every worker and
   verifier dispatch. On failure it logs
   `dispatch deferred: network preflight failed (<reason>)`, does not start
   an agent, does not consume an attempt, does not count a failure, and
   leaves the stage pending for the next fire. It is a deferral, not a halt.
3. The instant-fault pattern at `scripts/tick.sh:446` also matches
   `failed to resolve` and `op exit [0-9]+`, so a dispatch that dies on
   credential resolution halts the repo once via
   `halt_dispatch_configuration_fault` with the reason in `halt_reason`.
4. `scripts/network-fault-smoke.sh`: (a) with the preflight stubbed to fail,
   a tick against a fixture repo with a pending stage logs the deferral and
   the stage is still pending with zero attempts; (b) a worker log holding the
   exact op-fetch line from the watch is classified as an instant fault and
   the repo halts with that reason and `consecutive_failures` unchanged.
   Frozen block around those assertions.
5. `docs/tick-loop.md`: a paragraph in the fault section stating the two
   rules and the difference between a deferral and a halt.

## Constraints

- The preflight must cost under two seconds on a healthy network; measure
  it and put the figure in the envelope. It runs before every dispatch.
- Do not add a dependency on `dig`; fall back and say which resolver path
  was used in the log line.
- A preflight failure never increments `consecutive_failures`, never marks
  a stage stalled, never writes a WIP branch.
- The existing pattern's other matches must keep matching; extend the regex,
  do not rewrite it.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. With `scripts/preflight-network.sh` replaced by a stub that exits 1, a
   real `autometta tick` against a fixture subscriber with one pending stage
   logs the deferral and starts no process; `attempts` stays 0 and
   `consecutive_failures` stays 0.
2. A worker log containing
   `op-fetch: error: failed to resolve CLAUDE_CODE_OAUTH_TOKEN (op exit 1)`
   with the stage's completion artefact absent and log mtime within two
   seconds of `started_at` is classified as an instant configuration fault;
   the repo halts with that text in `halt_reason`.
3. The preflight passes on the operator's machine in under two seconds and
   the tick dispatches normally.
4. `scripts/network-fault-smoke.sh` passes and both cases fail against the
   pre-change `tick.sh`.
5. `scripts/tick-cost-smoke.sh` and `scripts/budget-cap-smoke.sh` are no more
   red than on clean `dev`.

## Contract test

- **Test file:** scripts/network-fault-smoke.sh
- **Assertions digest:** frame the assertions in a block between the begin
  marker and the end marker, the begin marker naming this card by its
  `card=stage-cards/108-a-dead-network-does-not-spend-a-dispatch.md` field, and replace this line's text with the real
  digest printed by `scripts/check-contract-test-gate.sh print scripts/network-fault-smoke.sh`. Do not
  write a `sha256:` comment inside the block, and do not spell the marker
  tokens anywhere in this card's prose; the card is in your path claims for
  exactly this edit.

## Out of scope

- Correlating the quota reader's staleness with the same fault (watch
  improvement 2b). Record where it would hook in; do not build it.
- Restoring or configuring the operator's DNS.

## Budget

- **Worker wall-clock:** 90 minutes
- **Verifier wall-clock:** 45 minutes

## Escalation

If adding the preflight to the dispatch path requires restructuring
either `spawn_*_for_stage` call site beyond inserting a guard, stop and
report the shape; a refactor of dispatch belongs in its own card.

## Verifier handoff

Build the fixtures yourself from the watch's log text, not from the
worker's smoke. Confirm criterion 1 with a real tick, not a function call:
the deferral must leave state untouched, and the easy mistake is a
deferral that still writes `started_at`. For criterion 2, also run a log
holding an ordinary worker error that is not a credential failure and
confirm it is still not classified as an instant fault; the regex widening
must not swallow real worker failures.

## Family-specific notes

None

## Seat history (2026-09-06)

The Codex subscription closed at 10:31Z and this batch was re-seated onto
Claude alone; when Claude session windows then drained faster than the batch
was sized for, the verifying seat moved to the free local route
(`gpt-oss:120b` via `codex exec --oss`). The Codex window reopened the same
afternoon and the card is back on the seats it was authored with. Nothing
about the work changed across either move.
