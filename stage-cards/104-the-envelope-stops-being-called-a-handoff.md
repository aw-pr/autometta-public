# Stage card 104: the envelope stops being called a handoff

## Metadata

- **Authored:** 2026-09-01
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Verifier:** Codex GPT-5.6 Sol <codex-gpt-5-6-sol@local>
- **Base branch:** dev
- **Run branch:** autometta/104-the-envelope-stops-being-called-a-handoff
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/tick.sh, scripts/spawn-worker.sh, scripts/validate-handoff-envelope.sh, scripts/envelope-migration-smoke.sh, schemas/handoff-envelope.json, templates/worker-prompt.md, templates/verifier-prompt.md, docs/handoff-envelope.md, docs/dispatch-contract.md
- **Pairing rationale:** cross-family. A rename that spans a vendored contract
  is exactly where a worker's "I updated all the references" needs an
  independent grep, so the verifier comes from the other family and is asked
  to find what was missed rather than confirm what was done.
- **Type:** Rename with a live migration. Behaviour must not change.

## Surfacing concern

Two unrelated artefacts share the word "handoff", and the collision has already
cost real work:

| | `state/handoffs/<stage>.json` | `HANDOFF.md` |
|---|---|---|
| Written by | a worker, as its final action | the agent ending a session |
| Read by | `tick.sh`, once, as the completion signal | the next chat |
| Scope | one dispatch | the working line |
| Nature | machine protocol between two processes | prose for a person |

On the strength of that shared word `handoff.mode` was set to `envelope` here,
which instructs the handoff skill to write **no session handoff at all**. Two
consecutive sessions wrote `HANDOFF.md` in defiance of the config and both
filed it as unresolved. `de863ba` fixed the configuration and `a9d938e` fixed
the fleet rule that justified it. Neither touched the name that caused it.

The operator's question, 2026-09-01: rename the per-stage artefact and let
`HANDOFF.md` be the standard everywhere. That is this card.

## The migration hazard, which is the real content of this card

A subscriber runs autometta's **scripts** centrally through `AUTOMETTA_ROOT`,
but holds its **own vendored copy** of `templates/worker-prompt.md`, which is
what tells a worker where to write the envelope. Measured 2026-09-01: both
`worker-prompt.md` and `verifier-prompt.md` are in the vendored set, and 142
live envelope files exist across six subscriber repos.

So a straight rename breaks every repo that has not refreshed: the central tick
reads the new path, the stale template tells the worker the old one, the worker
writes where nobody looks, and the stage stalls on "exited without an
envelope". That is the exact failure that cost stage 69 its attempt today, and
here it would hit every un-refreshed subscriber at once, silently, one dispatch
at a time.

**Therefore: dual-read, never a flip.** The reader accepts both paths. Only the
writer moves.

## Objective

Rename the dispatch envelope so it no longer borrows the word "handoff", and
migrate the fleet without a window in which any subscriber can lose a
completion signal.

Proposed vocabulary, adjust if you find better and say why:

- `state/handoffs/` -> `state/envelopes/`
- `schemas/handoff-envelope.json` -> `schemas/envelope.json`
- `scripts/validate-handoff-envelope.sh` -> `scripts/validate-envelope.sh`
- `docs/handoff-envelope.md` -> `docs/dispatch-envelope.md`
- the prose term "handoff envelope" -> "dispatch envelope"

"Envelope" is kept deliberately: it is already the vocabulary, it is
unambiguous once "handoff" is dropped, and continuity costs nothing.

## Inputs (read these in your own context)

- `scripts/tick.sh`, every read of `state/handoffs`
- `scripts/spawn-worker.sh` and `scripts/validate-handoff-envelope.sh`
- `templates/worker-prompt.md` and `templates/verifier-prompt.md`, the vendored
  half
- `scripts/vendor-set.sh` and `scripts/refresh-repo.sh`, the push mechanism
- `docs/handoff-envelope.md` and `docs/dispatch-contract.md`

32 files in this repo reference the old name. Grep, do not trust that list.

## Deliverables

1. **The reader accepts both paths.** `tick.sh` finds an envelope at
   `state/envelopes/<stage>.json` or `state/handoffs/<stage>.json`, preferring
   the new one. A stale subscriber keeps working untouched.
2. **The writer moves.** The vendored worker prompt names the new path.
3. **Existing envelopes are left where they are.** Do not move 142 live files;
   the dual read makes that unnecessary, and a stage mid-flight must not have
   its completion signal relocated underneath it.
4. Renames of the schema, validator and doc, with every reference updated.
5. `scripts/envelope-migration-smoke.sh`: proves both paths are read, the new
   one wins when both exist, and a repo with only old-style envelopes still
   completes a stage.
6. A migration note in `docs/dispatch-contract.md`: what changed, why both
   paths are read, and the condition under which the old path may eventually
   be dropped -- **not** a date, but "every subscriber's vendor stamp is at or
   past this commit", which is checkable.

## Constraints

- **No behaviour change.** A stage that completes today completes tomorrow, on
  either path.
- **Do not remove the old path in this card.** It is a compatibility shim with
  a stated retirement condition, and retiring it is a later decision once the
  fleet has refreshed.
- Do not run `refresh-all-repos`. Pushing the vendored change to subscribers is
  an operator action, and the card must be safe to land before it happens.
- Do not touch `HANDOFF.md`, `handoff.mode`, or anything about the session
  handoff. That half is settled.
- Card 100 may be editing `tick.sh`. Check whether it has landed and rebase
  rather than racing it.

## Acceptance criteria

1. A stage whose worker writes to `state/envelopes/` completes normally.
2. A stage whose worker writes to `state/handoffs/` completes normally, with
   no warning that reads as an error. This is the stale-subscriber case and it
   is the one that matters.
3. With both files present, the new path wins and the outcome is deterministic.
4. `scripts/envelope-migration-smoke.sh` passes and fails against the
   pre-change `tick.sh`. Record both runs.
5. `grep -rn "state/handoffs" scripts/ templates/ docs/` returns only the
   deliberate compatibility shim and the migration note. No stragglers.
6. Every existing smoke that mentions the envelope still passes, unchanged:
   `preserve-failed-work-smoke.sh`, `pipeline-pair-smoke.sh`,
   `gate-smoke.sh`, `local-worktree-write-smoke.sh` and the others the grep
   finds.
7. `bash scripts/autometta-vendor-check.sh` behaves correctly in a subscriber
   whose stamp predates this change: stale, not broken.

## Contract test

- **Test file:** scripts/envelope-migration-smoke.sh
- **Assertions digest:** `sha256:feb5456892f03ad9b99f41d31d58ce1fea05f4292c2f4f72cb5b7d17bcaf27fd`

## Out of scope

- Running `refresh-all-repos`, or any change inside a subscriber repo.
- Retiring the old path.
- Moving the 142 existing envelope files.
- `HANDOFF.md`, `handoff.mode`, and the session-handoff half generally.

## Budget

- **Worker wall-clock:** 90 minutes
- **Verifier wall-clock:** 45 minutes

## Escalation

If the dual read cannot be made unambiguous -- for instance if some code path
enumerates the directory rather than looking up a stage id, so "both paths"
means merging two listings -- stop and record it. A rename that half-works
across a fleet is worse than the name collision it fixes, and the collision has
already been defused at the config layer.

## Verifier handoff

Grep for stragglers yourself; do not accept a claim that all references moved.
`grep -rn "state/handoffs\|handoff-envelope\|handoff_envelope"` across
`scripts/`, `templates/`, `schemas/`, `docs/`, `skills/` and `bin/`, and judge
each surviving hit as deliberate shim, migration note, or miss. Thirty-two
files carried the old name, and a rename is the change most likely to be
reported complete while being partial.

Test the stale-subscriber case for real: construct a fixture repo whose
vendored `worker-prompt.md` still names `state/handoffs/`, run a stage through
it, and confirm it completes. That is the case that breaks the fleet if it is
wrong, it is the one a worker is least likely to test because it requires
building the old world on purpose, and it cannot be judged by reading the diff.

## Re-brief 2026-09-01: two real failures, two you did not cause

Attempt 1 scored 5 of 7 and is preserved at
`wip/104-the-envelope-stops-being-called-a-handoff-attempt-1` (`ec153c9`).
Read it before starting; most of the rename is done and re-deriving it wastes
the pass. Three things to fix, and one thing to stop worrying about.

### 1. The old-path grep still returns stragglers (criterion, genuine)

Five files still name `state/handoffs` outside the compatibility shim and the
migration note:

- `scripts/render-controller-seed.sh:213` — declares only `state/verifiers`
  and `state/handoffs` as artefacts
- `docs/tick-loop.md:294` — says snapshots hold `state/handoffs`, omits
  `state/envelopes`
- `docs/lessons.md:411` — describes the current prompt as naming
  `state/handoffs`
- `docs/design/sweep-stage.md:34,57,76` — specifies *new* completion envelopes
  at the old path
- `docs/design/mcp-cards.md:45` — defines emitted message traffic under
  `state/handoffs`

`sweep-stage.md` is the one to think about rather than sed: it specifies new
work at the old path, so changing the string is not the same as changing what
it means.

### 2. Two smokes you did break (criterion, genuine)

`local-route-smoke.sh` (CODEX_HOME route assertions at `:277-290`, `:359-374`)
and `state-writable-smoke.sh` (the verifier `--add-dir` assertion at
`:177-179`). Both **pass on a clean `dev`** and fail against attempt 1, so
they are this stage's to fix.

### 3. The contract gate is not armed

`scripts/envelope-migration-smoke.sh` carries no freeze markers and this card
declares a prose Assertions digest, so the gate exits 1 the way it did for
stage 102. Add the markers and record a real sha256. Stage 102 closed exactly
this and its verifier artefact shows the gate then recomputing a real digest —
copy that shape. Keep the literal marker tokens out of card prose; a card file
containing the begin-token trips the gate on itself when staged.

### What you did not cause

The verifier reported four failing smokes. Two of them fail on a clean `dev`
with nothing of yours applied, measured at `d894ad0`:

- `state-branch-smoke.sh` — the worktree-reaper failure stage 100's worker also
  hit and recorded as unrelated
- `superseded-status-smoke.sh` — the duplicate alert-status enumeration at
  `scripts/lib/tui/render.py:454,491`; it also fails at `e057331`, before stage
  103 touched `render.py`, so 103 did not introduce it either

**Do not fix either one in this card, and do not let them stop you.** They are
pre-existing defects that predate this batch and deserve their own cards. If
your run shows them failing, that is expected; say so in the envelope and move
on. Fixing them here would put unrelated changes in a rename stage and make
this card's diff impossible to review.
