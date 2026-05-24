# Stage <ID>: <title>

- Track: K (kernel/engine) | U (UI) | I (integration)
- Status: pending | in_progress | done
- Depends on: <stage IDs that must be done first>

## Goal

<One paragraph: the outcome, not the steps.>

## Deliverables

- <concrete artefact>

## Non-goals

- <explicitly excluded so scope cannot creep>

## Acceptance

Exact command(s) a verifier runs; the stage is done iff this passes:

```
<command>
```

Pass condition: <precise, machine-checkable statement>.

## Verifier brief

- Tier: <model/thinking per the orchestrator skill>
- Run the Acceptance command verbatim. On green, mark the stage done.
- On red: <what to inspect>; attempt at most N self-corrections; if still red, escalate with the failing output and a one-line diagnosis. Do not weaken the Acceptance command to make it pass.

## Definition of done

- Acceptance green, `gofmt`/build clean, no regression in prior gates, card Status set to done, one focused commit.
