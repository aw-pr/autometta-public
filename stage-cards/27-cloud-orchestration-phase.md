# Stage card 27-cloud-orchestration-phase: Design - cloud-hosted orchestration as a future phase

## Metadata

- **Authored:** 2026-05-28
- **Orchestrator:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Worker:** (design-only; orchestrator-authored prose)
- **Verifier:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Pairing rationale:** Design-only card. The deliverable is a scoped design memo and a decision on phasing, not code. No worker dispatch; verified by read-through against the load-bearing beliefs in `docs/philosophy.md`.
- **Type:** Design-only, future phase. Explicitly not pass 3. Parked until the card-23 SDK-controller verdict lands.

## Surfacing concern

The current architecture is single-machine by deliberate choice: git is the state store, the filesystem is the message bus, cron or launchd is the heartbeat, and every worker is a local CLI subprocess (`docs/philosophy.md`, "cron + tick > daemon", "no daemons, no databases, no services"). The recurring question is whether an orchestrator or controller could run on hosted infrastructure so a loop survives the laptop being shut, or so several repos share one always-on driver. This card captures that as a bounded future phase rather than letting it leak into pass 3 piecemeal.

## Objective

Produce a design memo that scopes a cloud-hosted orchestration phase without committing to build it. Decide what "cloud" would and would not mean for Autometta, which load-bearing beliefs it pressure-tests, what it shares with the existing hosted-monitoring card (21) and the SDK-controller experiment (23), and the entry criteria that must be met before any implementation card is authored.

## Inputs (read these in your own context)

- `docs/philosophy.md` - the single-machine beliefs being pressure-tested.
- `docs/phat-controller.md` - the current cron-tick loop design.
- `examples/self-host/21-remote-scheduled-monitoring.md` - the existing hosted, PR-only monitoring card (closest neighbour).
- `examples/self-host/23-sdk-controller-experiment.md` - the long-lived-SDK-session experiment whose verdict this phase depends on.

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. `docs/design/cloud-orchestration-phase.md` - the design memo. Required sections: Motivation (what a laptop-independent loop buys); Scope boundary (what stays local vs what moves to a host); State and message bus (how git-as-state and filesystem-as-bus survive, or what replaces them, when the driver is remote); Auth and secrets (how `op-fetch` and the subscription/API routes work off-machine); Relationship to cards 21 and 23 (overlap and seams); Entry criteria (the conditions that must hold before an implementation card is opened); Non-goals.
2. `memory/decision-cloud-orchestration-phasing.md` - decision memo recording why cloud is deferred to a future phase rather than folded into pass 3, links to `[[decision-sdk-controller-experiment]]`.

## Constraints

- Design-only. No scripts, no schema changes, no `bin/autometta` changes.
- The memo must not weaken any load-bearing belief without saying so explicitly and naming the trade-off.
- Entry criteria must be concrete and checkable, not aspirational.
- British English, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. `docs/design/cloud-orchestration-phase.md` exists with every required section.
2. The memo states explicitly which of the `docs/philosophy.md` beliefs cloud orchestration pressure-tests, and the trade-off for each.
3. The memo distinguishes its scope from card 21 (hosted monitoring, PR-only output) and card 23 (long-lived SDK controller) in plain words.
4. Entry criteria are concrete and include a dependency on the card-23 verdict.
5. `memory/decision-cloud-orchestration-phasing.md` follows the decision-memo format and links to `[[decision-sdk-controller-experiment]]`.
6. No code, schema, or CLI files are modified.

## Out of scope

- Building any cloud runtime, hosted controller, or remote dispatch path.
- Choosing a specific cloud provider or hosting product.
- Multi-repo or multi-tenant orchestration mechanics beyond naming them as a non-goal or future concern.

## Budget

- **Worker wall-clock:** n/a (design-only, orchestrator-authored).
- **Verifier wall-clock:** 20 minutes.

## Verifier handoff

Orchestrator authors the memo and decision note, then writes `state/handoffs/27-cloud-orchestration-phase.json`. Verifier reads the memo, the decision note, and `docs/philosophy.md`; confirms the required sections and the explicit belief trade-offs; writes `state/verifiers/27-cloud-orchestration-phase.json`.

## Family-specific notes

None. Design-only card; family-neutral.
