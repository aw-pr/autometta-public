# herdr spike

## What was run

This probe ran on 31 August 2026 in the local Autometta run worktree. `herdr`
was installed through Homebrew at version `0.8.2`; `brew list --versions herdr`
returned `herdr 0.8.2`.

Commands issued, in order:

```sh
git status --porcelain
command -v herdr
herdr --version
herdr channel set stable
herdr channel --help
herdr agent --help
herdr session --help
tmux -V
claude --version
codex --version
herdr --skill
printf 'HERDR_ENV=%s\\n' "${HERDR_ENV:-}"
herdr channel show
brew list --versions herdr
git status --porcelain
```

`herdr channel set stable` exited 1 with `Operation not permitted`. The later
read-only `herdr channel show` reported `stable`, so the stable-channel
constraint was already met. `herdr --skill` then required an in-session check
before any pane or agent control command. That check printed an empty
`HERDR_ENV`, so no Herdr pane, agent, session, server, remote-host, or SSH
command was issued.

The stage card said the operator would supply the local session-tool paths at
dispatch time. No such path was supplied, so that tooling was not inspected.

## Agent detection

Neither a live Claude Code pane nor a live Codex pane was probed. The required
in-session environment marker was absent, and Herdr's supplied control
instructions say to stop rather than inspect or control a Herdr session from
outside it.

Observed states: none. `idle`, `working`, `blocked`, `done`, and `unknown`
were not reached. In particular, this run did not treat the CLI help text as
evidence that any state was observed. The detection and wait commands named in
that help were therefore not run against an agent.

## The blocked probe

Claude Code: not probed. The intended command was
`herdr agent wait <claude-agent> --until blocked --timeout 120000`; it was not
issued, so its exit status is not applicable. Creating the required
no-bypass Claude pane would have violated Herdr's outside-session control
rule after `HERDR_ENV` was found unset.

Codex: not probed. The intended command was
`herdr agent wait <codex-agent> --until blocked --timeout 120000`; it was not
issued, so its exit status is not applicable. Creating the required no-bypass
Codex pane had the same blocker.

The normal Autometta dispatch flags bypass approvals for both families. Even a
successful no-bypass probe would therefore test a condition unavailable under
normal dispatch. This was not tested here.

## Reboot restore

Not tested. No named test session was created, no Herdr server was stopped,
and no Claude or Codex conversation was restored by session reference. The
worker could not make this disruptive probe from outside a Herdr-managed pane.

## Verdict

**Reject.** The deciding finding is not a claimed Herdr defect: this dispatch
could not enter the prerequisite Herdr session, so it could not produce the
two-family blocked-state evidence that the adoption question requires. The
current polling path should remain unchanged on the basis of this incomplete
probe.

### Limits

The descriptions of `idle`, `working`, `blocked`, `done`, `unknown`, and
`herdr agent wait --until` came from Herdr's locally supplied vendor guidance,
not machine observation. The statement that a named session can be managed by
the session commands also came from that guidance. Reboot restore by native
agent session reference was not tested and is not established by this report.
