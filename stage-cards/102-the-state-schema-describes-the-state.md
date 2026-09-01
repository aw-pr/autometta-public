# Stage card 102: the state schema describes the state

## Metadata

- **Authored:** 2026-09-01
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Verifier:** Codex GPT-5.6 Sol <codex-gpt-5-6-sol@local>
- **Base branch:** dev
- **Run branch:** autometta/102-the-state-schema-describes-the-state
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** schemas/state.yaml.json, scripts/state-schema-smoke.sh, docs/tick-loop.md
- **Pairing rationale:** cross-family, and the verifier is the stricter seat on
  purpose. The deliverable is a schema that must reject as well as accept, and
  a verifier from the other family has no stake in the worker's reading of
  which fields are legitimate.
- **Type:** Correctness of an instrument. No runtime behaviour changes.

## Surfacing concern

`state/state.yaml` fails `schemas/state.yaml.json` with **69 errors**, measured
2026-09-01, and has done since stage 9. Every one is the same shape:

```
 63  Additional properties are not allowed ('tokens', 'verifier_started_at' ...)
  3  Additional properties are not allowed ('notes', 'tokens', ...)
  1  Additional properties are not allowed ('integrated_at', 'note' ...)
```

The tick writes `tokens`, `worker_tokens`, `verifier_tokens`,
`verifier_started_at`, `notes`, `integrated_at` and `note`; the schema declares
none of them and forbids extras. So the file the loop depends on has never
validated, and `docs/tick-loop.md` section (b) states the tick "will validate
`state.yaml` against it on every read".

A validator that always fails is worse than none. It cannot be run in anger, so
nothing runs it, so a genuine corruption -- a truncated write, a bad merge, a
hand-edit -- would be indistinguishable from the 69 errors already there. The
guard exists and protects nothing.

## Objective

Make the schema describe the state the tick actually writes, so validation
passes on a healthy file and fails on a broken one.

**This is a schema change, not a state change.** Do not edit `state/state.yaml`
to fit the schema; the fields it carries are real and load-bearing.

## Inputs (read these in your own context)

- `schemas/state.yaml.json`
- `state/state.yaml`, as the specimen -- but see the constraint about deriving
  the schema from one file
- `scripts/tick.sh`, every `state_apply_json` call, which is the authority on
  what fields exist and when
- `docs/tick-loop.md` section (b)

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `schemas/state.yaml.json` declaring every field the tick writes, with types,
   and a note on each addition saying which code path writes it.
2. `scripts/state-schema-smoke.sh`: validates the repo's own `state/state.yaml`
   and a set of fixtures. It must assert both directions -- a healthy file
   passes, and a deliberately corrupt one fails.
3. A line in `docs/tick-loop.md` section (b) recording that the schema is now
   enforceable, and what to do when the tick gains a field.

## Constraints

- **Do not derive the schema from `state/state.yaml` alone.** That file is one
  repo's state at one moment; a field that happens to be absent today is not
  thereby forbidden. Read the writers in `tick.sh` and declare what they can
  write, including fields that are legitimately null or absent.
- **Keep `additionalProperties: false`.** The point of the schema is to catch a
  field nobody meant to write. Widening it to `true` would make validation pass
  and prove even less than it does now.
- Do not change `state/state.yaml`, and do not change what the tick writes.
- Subscriber state files must validate too, not just autometta's. Check
  emergence-lab's, which carries `wip_commit`, `wip_branch`, `stall_marker`,
  `integration` and `path_claims`.

## Acceptance criteria

1. `state/state.yaml` in this repo validates with zero errors.
2. `~/repos/emergence-lab/state/state.yaml` validates with zero errors. Its
   shape differs, and a schema that only fits the repo it was written in is
   the same defect one layer along.
3. `scripts/state-schema-smoke.sh` passes, and fails against the pre-change
   schema. Record both runs.
4. The smoke proves the schema still rejects: a fixture with a misspelled
   field (`verifer_tokens`), one with a wrong type (`tokens: "many"`), and one
   with a stage missing its `id` must each fail validation.
5. `additionalProperties: false` is still in force at every level it was
   before.
6. No change to `state/state.yaml` in either repo, and no change to `tick.sh`.

## Contract test

- **Test file:** scripts/state-schema-smoke.sh
- **Assertions digest:** both repos' live state files validate clean; a
  misspelled field, a wrong type and a missing id each fail.

## Out of scope

- Making the tick actually call the validator on every read. That is a
  behaviour change on the hot path and needs its own card, and card 100 may
  move the cost floor first.
- The other schemas.
- The two definitions of "tokens" in the aggregator, which is a separate item.

## Budget

- **Worker wall-clock:** 60 minutes
- **Verifier wall-clock:** 30 minutes

## Escalation

If a field the tick writes turns out to have no single type -- for instance if
`tokens` is sometimes a number and sometimes a string -- do not paper over it
with a union to make validation pass. Record it and stop: a field with two
types is a defect in the writer, and the schema is how you found it.

## Verifier handoff

Validate both state files yourself with a real JSON Schema library rather than
reading the worker's report; `jsonschema` is already a dependency in
`scripts/requirements-sdk.txt`.

Two things to disbelieve. First, that the schema still rejects: construct your
own corrupt fixture, not the worker's, and confirm it fails -- a schema
loosened until everything passes would satisfy criteria 1 and 2 while
destroying the instrument. Check `additionalProperties` specifically, at every
level. Second, that `state/state.yaml` is unmodified: `git diff` it. Making
the file fit the schema is the easy wrong answer to this card, and it would
silently discard real accounting fields.
