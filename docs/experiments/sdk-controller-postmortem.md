# SDK controller experiment postmortem

## Hypothesis

A resident Claude Agent SDK session might simplify a single-repository
controller by retaining its conversation and dispatch context in memory.

## What was built

`scripts/controller-sdk-experiment.py` holds one `ClaudeSDKClient` connection,
polls a synthetic JSON-form YAML state file, and sends each stage's worker then
verifier command through that session. It has no LaunchAgent, heartbeat,
production budget file, or connection to Autometta's real state. Its only
safety control is a 1,500-second wall-clock cap. The controller accepts an
explicit model alias, defaults to `sonnet`, and records a command exit status
only when it appears in a successful Bash tool result. It does not accept an
exit status repeated in assistant prose.

## What was observed

The retained SDK session authenticated with `sonnet` and dispatched both
synthetic stages. Neither stage reached its shell command in this worker
sandbox. Before Bash started, Claude Code tried to create a per-session
directory under `~/.claude/session-env/` and received `EPERM`. The controller
therefore wrote `failed`, cleared `current_stage`, and retained a worker-fault
stall marker. Stage A did not create `/tmp/sdk-exp-A.txt`; this is a harness
limitation, not evidence that `echo hello` failed. Stage B was also recorded
as failed, but the run did not establish that its `false` command executed.

The recorded Stage A run was:

```text
SDK session started with model 'sonnet' and hard cap 120s
23-sdk-exp-a: worker dispatched
23-sdk-exp-a: worker exit_status=unknown sdk_completed=False
23-sdk-exp-a: worker: tool stderr: EPERM: operation not permitted, mkdir '~/.claude/session-env/<session-id>'
23-sdk-exp-a: failed: worker
```

The recorded Stage B run was:

```text
SDK session started with model 'sonnet' and hard cap 120s
23-sdk-exp-b: worker dispatched
23-sdk-exp-b: worker exit_status=unknown sdk_completed=False
23-sdk-exp-b: worker: tool stderr: EPERM: operation not permitted, mkdir '~/.claude/session-env/<session-id>'
23-sdk-exp-b: failed: worker
```

An earlier retained-session run received SIGTERM while Stage A was in progress.
It wrote the stage as `failed`, cleared `current_stage`, and set
`SIGTERM/SIGINT observed while worker was in progress` before exit 143. That is
an observed catchable-signal path. A hard kill can still leave the last durable
state as `in_progress` because the process has no chance to write its recovery
record.

## Comparison matrix

| Axis | Cron-tick | SDK-session experiment |
| --- | --- | --- |
| Resumability | Each tick re-reads durable state and can resume after a process exit. | Session context disappears on process death; durable state only says where the session stopped. |
| Observability | Predictable per-role logs, liveness files, heartbeat, ticker, and tmux. | Console output and one synthetic state file only. The transcript exposed the session-directory refusal, but has no independent liveness record. |
| Cost | A fresh, bounded dispatch per role with recorded cost data. | A retained conversation may reuse context, but a resident process can keep consuming turns until its cap. The failed Bash setup produced no useful command-cost comparison. |
| Failure recovery | A later tick can classify a stale worker and follow the documented recovery path. | Observed SIGTERM records a failed stage only while Python remains alive. A crash or hard kill has no resident recovery mechanism. |
| What happens when the process dies mid-stage | Durable state and external process evidence allow the next tick to recover or stall the stage. | The SDK session and its in-process transcript vanish. The observed SIGTERM path is durable, but an uncatchable death can leave `in_progress` without proof of the child command's outcome. |

## Decision and reasoning

**Decision: keep cron+tick.** The experiment did not complete its happy path:
the SDK session's Bash tool could not create its required session directory in
this sandbox. That failure is still relevant to a resident controller: it adds
another in-process runtime dependency before a worker command can start. The
existing tick controller retains restartability, independent observation, and
a recovery route without keeping controller state in that process.

## The sandbox is the finding, across three attempts

Recorded by the orchestrator on adjudication, because no single worker saw the
whole sequence: each attempt could only report the wall it hit.

A resident SDK session needs two things an ordinary dispatched role does not,
and the experiment found them one at a time.

1. **A socket.** Attempts 1 and 2 died on `API Error: Unable to connect to API
   (FailedToOpenSocket)` before the Bash tool ran at all. Codex's
   `workspace-write` sandbox denies network to every shell command a model
   starts. This costs an ordinary worker nothing, because the codex CLI makes
   its own API calls from outside the sandbox and only the commands it runs are
   confined. An agent session spawned as a shell command has to open its own
   connection, and that is refused. Attempt 3 was dispatched with a
   `Requires network: true` card, which lifts exactly that; the socket errors
   stop and never return.

2. **A writable home.** Attempt 3 then died one layer further in, on
   `EPERM ... mkdir '~/.claude/session-env/<session-id>'`. The same sandbox
   confines writes to the workspace, and Claude Code wants a per-session
   directory under `$HOME`.

Neither is a defect in the apparatus, and the second was reached only because
the first was fixed. Together they are the most decision-relevant result the
experiment produced, and they point the same way as the matrix above: the
resident-session design needs the dispatch sandbox opened twice over before it
can start, where the cron-tick controller needs it opened not at all. A design
that must be exempted from the confinement every other role runs under is
paying a real price for the privilege, and that price is not visible in a
throughput or context-reuse comparison.

The stage was adjudicated complete at 9 of 10 criteria on 2026-09-01. Criterion
2, that stage A produce `/tmp/sdk-exp-A.txt`, is unmet and stays unmet: the
happy path never ran. What that criterion was there to protect, a Decision
resting on an observation rather than an assumption, is satisfied by the
observation above rather than by the one it asked for.

## What changes about future design conversations as a result

The question now has an explicit baseline: a long-lived SDK session is not the
Autometta controller. A future repeat must first run under a writable Claude
Code session environment, complete both synthetic command paths, and still
show how it preserves durable recovery after controller death. It should not
claim a throughput or cost advantage from this bounded result.
