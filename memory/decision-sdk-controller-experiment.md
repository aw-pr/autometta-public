---
name: sdk-controller-experiment
description: Decision record for the bounded resident Claude Agent SDK controller experiment.
metadata:
  type: project
---

# Decision: retain cron-tick rather than a resident SDK controller

## Context

We ran a deliberately small Claude Agent SDK controller experiment because a
resident session can appear simpler than a cron-driven controller when only the
happy path is considered.

## Decision

Keep cron+tick. The retained SDK session authenticated, but its Bash tool could
not create `~/.claude/session-env/` inside the worker sandbox, so neither
synthetic command ran. A catchable SIGTERM was recorded durably, but an
uncatchable process death still loses the in-memory conversation and can leave
the synthetic state at `in_progress`.

## Evidence

Both current runs failed before Bash started with an `EPERM` session-directory
error. The controller records no command exit status unless it receives the
status marker in a successful Bash tool result. The postmortem records the
observed SIGTERM state transition and the remaining hard-kill gap. See [the
postmortem](../docs/experiments/sdk-controller-postmortem.md).

## Why

Autometta's unattended controller needs recovery and auditability more than it
needs a retained conversation. Cron+tick keeps its source of truth and recovery
path outside the process that can fail.

## How to apply

Treat a resident SDK controller as an interactive, separately bounded tool, not
as a replacement for the autonomous tick loop. Any future proposal must
preserve durable recovery after controller death, complete both synthetic paths
in a writable Claude Code environment, and cite this experiment.

## Scope and follow-up

This result generalises to Autometta's unattended controller. It does not rule
out a short-lived SDK session inside a separately bounded interactive tool. The
handoff-envelope decision remains relevant: [[decision-handoff-envelope]].
