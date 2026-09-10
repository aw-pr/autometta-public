# Dispatch envelope

A worker writes a JSON file to `state/envelopes/<stage-id>.json` as its final action. `tick.sh` treats this file as the sole completion signal. Process exit and log-tail inspection are fallback stuck-worker signals only, not success signals.

A subscriber still vendoring the pre-card-104 `worker-prompt.md` writes to the legacy `state/handoffs/<stage-id>.json` path instead. `tick.sh` reads both; see [Envelope path migration](#envelope-path-migration) below.

## Not the session handoff

This document describes the **dispatch envelope**: a worker's completion signal to `tick.sh`, scoped to a single dispatch. It is a different artefact from `HANDOFF.md`, the **session handoff**: dated prose for the next chat, governed by `git config handoff.mode`, which is `tracked` in this repo.

| | Dispatch envelope | Session handoff |
|---|---|---|
| File | `state/envelopes/<stage-id>.json` | `HANDOFF.md` |
| Read by | `tick.sh`, once | the next agent, in a fresh chat |
| Scope | one dispatch | the whole working line |

The two used to share the word "handoff". Conflating them is what put `handoff.mode` on `envelope` in this repo until 2026-09-01. Card 104 dropped "handoff" from this artefact's name and path for exactly that reason; see [Envelope path migration](#envelope-path-migration).

## Shape

```json
{
  "stage_id": "17-structured-worker-handoff-envelope",
  "status": "pass",
  "deliverables": [
    "schemas/envelope.json",
    "templates/worker-prompt.md"
  ],
  "notes": "All seven deliverables written. Acceptance criteria 1-9 believed satisfied.",
  "worker_identity": "GPT-5.6 Sol <gpt-5-6-sol@local>"
}
```

Required fields: `stage_id`, `status`, `deliverables`, `notes`. Optional: `failed_acceptance`, `worker_identity`. Full schema: `schemas/envelope.json`. Validator: `scripts/validate-envelope.sh`.

## Why a file, not a tool call or log pattern

A file on disk is the only completion signal that works identically for both worker families (Codex in `workspace-write` sandbox, Claude in headless `claude -p` mode). Tool calls are family-specific; log patterns are fragile: a worker that prints "done" mid-stream can be falsely classified. A file written as the last action is atomic on POSIX and inspectable without re-running the worker.

## tick.sh outcomes

The five outcomes tick.sh implements once a worker process exits:

### 1. status=pass, valid envelope

tick.sh proceeds to verifier dispatch as normal. The worker's working tree changes remain dirty for the verifier to inspect. No log file is read for the completion decision.

### 2. status=fail, valid envelope

tick.sh marks the stage `failed` immediately and does not dispatch a verifier. The envelope's `notes` field is written verbatim to the stage's `stall_marker` in state.yaml so the operator can read the reason without opening the envelope file. No verifier runs over a run its own author disowns.

### 2a. status=partial, valid envelope

tick.sh takes the same path as `pass`: it dispatches the verifier, and additionally stamps `worker_envelope: partial` on the stage stanza as the audit trail.

`partial` is a worker-side annotation, not a verdict. It means "substantially done, some criteria deferred", and who decides whether that is acceptable is the verifier, not the worker. This matters because of the sandbox boundary: a worker that honestly reports it could not check a criterion from inside its sandbox is describing exactly the condition the boundary exists to create. Closing the stage as failed on that report throws away a build the verifier would have passed, and it teaches workers that honesty about a deferred criterion costs them the stage.

`spawn-verifier.sh` reads the envelope back off disk at dispatch time and, on `partial`, substitutes the worker's notes into the verifier prompt's family-specific-notes slot in place of "None", instructing the verifier to treat the deferred criteria as its checklist. The SDK transport (`scripts/verify-sdk.py --worker-notes`) carries the same text in its per-stage variable block, never the cacheable static block.

### 3. Worker exits cleanly, no envelope written

tick.sh marks the stage `stalled` with `stall_marker = "worker_envelope_missing_after_exit"`. The working tree is left intact for operator review. This is the most likely failure mode for workers running on a prompt template that predates stage 17.

### 4. Envelope present but schema-invalid

tick.sh moves the bad file to `<envelope-path>.invalid.json` (alongside whichever of the two paths held it), marks the stage `stalled` with `stall_marker = "worker_envelope_invalid"`, and logs the validation failure. The operator can inspect the invalid file without it being overwritten on the next tick.

## Legacy stages

Stages already recorded as `completed` in state.yaml before stage 17 was shipped are grandfathered. tick.sh does not retroactively require envelopes for them. Envelope enforcement applies only to stages that transition from `pending` to `in_progress` after stage 17 is committed, that is, stages whose worker dispatch goes through the updated `spawn-worker.sh` and worker prompt template.

## Operator checklist when a stage stalls on envelope reasons

- `worker_envelope_missing_after_exit`: the worker was dispatched with a prompt template that predates stage 17, or crashed before its final action. Check the worker log at `state/logs/<stage-id>-worker.log`. Re-dispatch after updating the prompt.
- `worker_envelope_invalid`: inspect `state/envelopes/<stage-id>.invalid.json` (or `state/handoffs/<stage-id>.invalid.json` for a stale subscriber). Correct the prompt or the worker logic, then delete the invalid file and re-queue the stage.

## Envelope path migration

Card 104 (2026-09-01) renamed this artefact from "handoff envelope" to "dispatch envelope" and moved the writer's target from `state/handoffs/<stage-id>.json` to `state/envelopes/<stage-id>.json`. The rename was needed because the shared word "handoff" had already caused this artefact to be confused with the unrelated session handoff (`HANDOFF.md`); see [Not the session handoff](#not-the-session-handoff).

**Why both paths are read.** `tick.sh` is central and updates the moment this change lands in `autometta`, but the worker prompt that tells a worker where to write is a *vendored* file: each subscriber holds its own copy of `templates/worker-prompt.md`, refreshed only by an operator running `autometta refresh-repo` or `autometta refresh-all-repos` (see "Pushing a release to the subscribers" in `docs/dispatch-contract.md`). A subscriber that has not refreshed still hands its worker the old path. A tick.sh that read only the new path would find nothing there, and score every completed stage from that subscriber as stalled, silently, the first time this change reached them. `worker_envelope_path()` in `tick.sh` therefore checks `state/envelopes/<stage-id>.json` first and falls back to `state/handoffs/<stage-id>.json`; when both exist, the new path always wins. `scripts/envelope-migration-smoke.sh` exercises all three path combinations against the resolver directly, then drives a throwaway subscriber through the real tick reactor on the new path and on the legacy path, proving each one lands a stage as `completed`.

**What moved and what did not.** Only the writer moved: the vendored `templates/worker-prompt.md` now names the new path, so every worker dispatched after a subscriber refresh writes there. The 142 envelope files already sitting in `state/handoffs/` across the fleet as of 2026-09-01 were not moved: a stage mid-flight must not have its completion signal relocated underneath it, and the dual read makes that unnecessary.

**When the old path can be retired.** Not on a date, on a condition: every registered subscriber's `.autometta-vendor` stamp records a `vendored_from` sha that is a descendant of (or equal to) the commit that lands this migration. That is checkable by walking the subscriber registry and running `git merge-base --is-ancestor <this-commit> <stamp-sha>` for each enabled entry's stamp; it is not checked automatically today. Until that sweep reports clean, `state/handoffs/` stays load-bearing and the fallback in `worker_envelope_path()` stays in place. Retiring it is a separate, later card.
