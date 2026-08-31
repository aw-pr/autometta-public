# Orchestrator SDK transport design

## Decision boundary

The orchestrator remains a CLI-driven, short-lived controller. No production
orchestrator SDK path is included here. Productionisation is explicitly gated
behind the verdict of the card-23 SDK controller experiment.

## Proposed manifest surface

```yaml
orchestrator:
  claude:
    transport: cli # or sdk, design-pending card 23
  codex:
    transport: cli # or sdk, design-pending card 23
```

`cli` would remain the default. `AUTOMETTA_CLAUDE_TRANSPORT` and
`AUTOMETTA_CODEX_TRANSPORT` have the verifier-role meaning today; an
orchestrator implementation must introduce role-qualified overrides rather
than overload those variables.

## Intended dispatch difference

The CLI orchestrator starts a process for one controller turn, reads and writes
the git-backed state, then exits. An SDK orchestrator would create or resume a
family-specific thread, supply the same stage card and state slice, and perform
one state transition before returning control to the tick. It must preserve the
existing filesystem message bus, verifier handoff, budget checks, and ordered
landing gate. It must not turn the tick into a daemon.

For Claude, the SDK transport would use the same api or subscription auth-route
contract already proven for the verifier. For Codex, the selected `CODEX_HOME`
would remain the billing authority: normal chatgpt-mode home for subscription,
api-only apikey-mode sibling for API billing. Both require the same fail-closed
auth checks as the verifier route.

## Gate before implementation

Card 23 must establish whether a retained SDK thread gives enough controller
benefit to justify its state, prompt-cache, and recovery complexity. Until its
verdict is accepted, these keys are comments in the example manifest only and
no spawner, tick, or controller code may read them.
