# Worker SDK experiment postmortem

## Hypothesis

A Claude Agent SDK worker might retain the CLI worker's filesystem boundary
while adding per-message usage and a structured handoff without log parsing.

## What was built

`scripts/worker-sdk-experiment.py` starts one Claude Agent SDK session in a
throwaway scoped worktree. It copies in a synthetic stage card, permits only
file tools, sets `CLAUDE_CONFIG_DIR` inside that worktree, and applies a hard
wall-clock cap. Its permission callback refuses any file-tool path outside the
scope and records the refusal in the session log. It also writes a scratch-only
liveness entry with `live_input_tokens`, `live_output_tokens`, and
`live_updated_at`, matching the live-usage fields used by the registry. It has
no tick, LaunchAgent, production state, or installable entry point.

## What was observed

Both sessions were run on 2026-09-01 with the session configuration directory
inside their respective throwaway worktrees. Neither reached a file tool. The
SDK created its worktree-local configuration and session transcript, then
reported that it was not logged in. No subscription OAuth token was present in
the dispatch environment, and the confined configuration directory could not
reuse the operator's login outside the scoped worktree. The apparatus did not
copy credentials or widen the sandbox.

Stage A exited 1 without `deliverable.txt` or a handoff:

```text
SDK worker started model=sonnet cap_seconds=900
assistant: Not logged in · Please run /login
result: error=True turns=1 stop_reason=stop_sequence
handoff invalid: [Errno 2] No such file or directory: '<scratch>/handoff.json'
```

Stage B exited 1 without attempting its required `/tmp` write or writing a
failure handoff:

```text
SDK worker started model=sonnet cap_seconds=120
assistant: Not logged in · Please run /login
result: error=True turns=1 stop_reason=stop_sequence
handoff invalid: [Errno 2] No such file or directory: '<scratch>/handoff.json'
```

Consequently, the out-of-scope refusal criterion is unobserved, and no SDK
message usage reached the scratch registry's `live_input_tokens`,
`live_output_tokens`, and `live_updated_at` fields. The transcript shows the
failure before the first tool call, not a claim that either synthetic
deliverable failed on its own merits.

## Comparison matrix

| Axis | CLI worker | SDK worker experiment |
| --- | --- | --- |
| Sandbox enforcement | Codex applies `workspace-write` outside the worker process and prevents worker self-verification. | The permission callback is ready to refuse file paths outside the throwaway worktree, but the SDK did not authenticate far enough to invoke it. Confining the SDK configuration made the subscription login unavailable. |
| Tool-loop fidelity | The CLI supplies its native agentic loop and broad tool surface. | The SDK started its session and returned an error before the first tool call. File-tool fidelity is therefore unobserved. |
| Observability parity | Registry, heartbeat, predictable role logs, ticker and recent-agent history are available. | The experiment supplies a transcript and scratch-only registry entry. Its log captured the early error, but it has no heartbeat, ticker or durable production registry. |
| Live usage and prompt-cache behaviour | CLI worker logs are the later accounting source and do not provide this per-message registry update. | No message usage was received, so the expected live registry fields remained absent. Prompt-cache behaviour is unobserved. |
| Failure recovery when the process dies mid-turn | Tick, heartbeat and durable state provide an external recovery route. | A killed Python process would lose its SDK transcript and cannot write the handoff. The apparatus does not add a recovery mechanism, and this run did not reach a mid-turn process. |

## Decision and reasoning

**Decision: workers stay CLI.** The bounded worker SDK route did not reach its
first tool call while keeping the Claude configuration inside the worker's
scope. Making the session writable there disconnected it from subscription
authentication; copying credentials or opening the scope would alter the very
boundary under test. The unobserved refusal, handoff and live-usage paths do
not justify a production exception, and the prototype still lacks the CLI
worker's heartbeat and recovery surface.

## Adjudication note: the constraint this Decision rests on has since been lifted

Recorded by the orchestrator on landing, 2026-09-01, because it bears directly
on how much weight the Decision above can carry.

The worker faced a genuine dilemma and read it correctly. Under
`workspace-write` the session could not create its per-session directory in the
real Claude home, so it put the configuration directory inside the throwaway
worktree instead. That made it writable and, in the same move, emptied it: the
subscription OAuth credentials live in the operator's `~/.claude`, so the
session came up `Not logged in`. The postmortem says the apparatus "did not
copy credentials or widen the sandbox", and it was right not to. Which
privileges a dispatched role holds is an operator's decision, not a worker's,
and taking it unilaterally to make its own experiment pass would have been the
wrong call twice over.

The operator has since granted it. `- **Requires agent home:** true` makes the
real `~/.claude` writable to the role while leaving the sandbox at
`workspace-write`, which is precisely the combination the worker could not
reach: credentials present *and* the session directory creatable. Measured the
same day, reads of `$HOME` were already permitted either way, so the grant adds
write access to one directory and no new sight of anything.

**So "workers stay CLI" was reached under a constraint that no longer holds.**
It is retained as this stage's Decision because it is what the run actually
supports, and because the other reasons it gives stand on their own: the
prototype has no heartbeat, no registry entry and no recovery surface, and none
of that depends on the sandbox. But the central claim, that the SDK worker
cannot reach its first tool call, is now untested rather than established. A
re-run with both grants is the honest way to settle it, and this stage was
adjudicated complete at 6 of 8 rather than re-queued because the question was
judged not worth another attempt today, not because it was answered.

Criteria 2 and 3, the two that failed, are exactly the two that needed the
grant: stage A producing its deliverable and stage B's out-of-scope write being
refused. Neither was observed, so nothing is known about the deny callback at
`scripts/worker-sdk-experiment.py` beyond that it was never reached.

## What changes about future design conversations

Future discussion starts from a bounded result: an SDK worker must receive
subscription authentication through the existing `op-fetch` contract while
keeping all of its writable session state in scope, then demonstrate the
out-of-scope refusal, SDK-written handoff, registry usage, heartbeat and
recovery contract. Claude observations do not establish the equivalent Codex
SDK thread behaviour, whose usage accounting differs.
