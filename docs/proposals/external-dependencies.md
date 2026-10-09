# External dependencies: one directory, one brief each

Operator design note, 2026-09-19, raised alongside card 137. Card 137 made
the provider-window reserve on by default, and in doing so made a quiet
fact loud: the reserve is only as good as the reading, and the reading for
Claude comes from something that is not in this repo and exists on exactly
one machine. Nothing here is built yet. This note is the plan and the
decisions it needs.

## The observation

`scripts/check-deps.sh` knows about eleven things. Three of them are not
installable from anything a fresh machine can reach:

| Dependency | Where it actually lives today | What breaks without it |
|---|---|---|
| `op-fetch` | `~/Scripts/op-fetch`, hand-placed from the `auth-route-security` skill | every dispatch; fails closed |
| `agent-whoami` | `~/.local/bin` symlink into a private `mcp-hub` checkout | state-branch attribution; `tick.sh` fails closed |
| Claude quota publisher | `~/.local/state/ai-quota/claude.json`, a symlink into a private Swift menubar app (`vibe-menuapp`) that polls the OAuth usage endpoint with the Claude Code Keychain token | the Claude reading is `unknown`; the reserve fails open and binds only Codex |

The first two fail closed, so a fresh machine finds out at once. The third
fails open by design (an unknown reading must never stop work), which is
right for a run and wrong for setup: the operator who has just read that the
loop holds 20% by default has no signal that, for Claude, it holds nothing.

Beyond those three, the rest of the surface is scattered: the 1Password
service account and its env file, the sibling `CODEX_HOME` for API-mode
Codex, the git hooks copied from `mcp-hub/templates/git-hooks`, the
Homebrew tap rendered by `scripts/install-homebrew-local.sh`, Ollama and its
pulled weights for the local route, the python packages for the SDK
verifier, tmux for the viewer. Each has a paragraph somewhere in
`docs/setup.md`, `README.md` or `CLAUDE.md`; none has a probe an agent can
run, and no single place lists them.

The user story that matters: **someone, or the operator on a second
machine, points an agent at this repo and says "set it up". The agent
should be able to find every external thing, check it, install what is
installable, and say clearly what it cannot do and why.** Today it cannot,
because the knowledge is in prose and in one person's home directory.

## Proposal

A committed `dependencies/` directory. One subdirectory per external
dependency, each a self-contained brief with the same four files:

```
dependencies/
  README.md                 index: table of every dependency, tier, probe
  op-fetch/
    README.md               what it is, why we need it, what breaks without it
    check.sh                idempotent probe; prints PASS/MISSING/WARN lines
    install.sh              idempotent installer, or absent when there is none
    AGENTS.md               the brief an agent follows when install.sh cannot
                            decide alone (a vault to choose, a login to run)
  agent-whoami/
  quota-publisher-claude/
    README.md
    check.sh
    contract.md             the snapshot shape autometta consumes (moved from
                            docs/observability.md, which then links here)
    AGENTS.md               how to supply a publisher: the reference app, or
                            any other process that writes the contract
  quota-publisher-codex/    check only: rollout logs are self-supplying
  op-service-account/
  codex-home-api/
  git-hooks/
  homebrew-tap/
  ollama-local/             optional tier
  sdk-verifier-python/      optional tier
  tmux/                     optional tier
```

Four rules make it work:

1. **The probe is the contract.** `check.sh` prints the same
   `PASS name reason` / `MISSING name reason` / `WARN name reason` lines
   `check-deps.sh` prints today, so `check-deps.sh` becomes a loop over
   `dependencies/*/check.sh` plus its bash-version check, and `autometta
   check-deps` output does not change shape. Migrate the eleven hardcoded
   checks into the directory one at a time; nothing is rewritten in one go.
2. **Tier is declared, not inferred.** Each README's first line is
   `Tier: required | optional | private`. Required fails `check-deps`;
   optional warns; private is a dependency whose reference implementation
   is not public, so the directory ships the *contract* and a probe, and
   the brief says what any replacement must produce. The Claude publisher
   is the one private entry today.
3. **An agent reads `AGENTS.md`, a script runs `install.sh`, never the
   reverse.** `install.sh` exists only where installation needs no human
   decision (brew formulae, a symlink, a pip requirements file). Anything
   that needs a choice, a login or a secret gets an `AGENTS.md` brief
   written the way a stage card is written: what to check first, what to
   do, what to say back, what never to do (never paste a token into a
   file, never guess a vault name). The brief is the prompt.
4. **Publish-safe by construction.** The directory is on the publish head,
   so no absolute home paths, no vault names, no account identifiers. The
   `pre-commit` guard's absolute-path check already covers this; the
   `credential_symlink_patterns` list in `check-deps.sh` moves into
   `dependencies/README.md` as the statement of what a dependency
   directory must never link to.

`autometta deps` (a thin `bin/autometta` verb) runs every `check.sh`, prints
the table, and for each MISSING prints the path of the brief to read next.
That is the whole agent bootstrap loop: run it, read the brief for the first
MISSING, act, run it again.

## What this does to the reserve

`quota-publisher-claude/check.sh` reads the snapshot exactly as
`quota-window.py` does and reports `MISSING` when it is absent or stale,
with the reason "the Claude reserve fails open until a publisher writes
this file". `check-deps` then says at setup time what the tick can only
whisper at dispatch time. The reserve itself does not change: unknown still
fails open in the loop, because a run must not stop on a broken poller.

## Decisions needed

These are the operator's, and the plan waits on them:

1. **Does the Claude publisher get extracted?** The Swift app's usage fetch
   is about sixty lines: read the Claude Code Keychain entry, call the
   OAuth usage endpoint, write the contract. A small public `claude-usage
   -publish` script (bash or python, LaunchAgent every five minutes) would
   turn the one private dependency into a required one and let the default
   reserve bind Claude on any machine. The menubar app could then read the
   same file instead of polling itself. The alternative is to keep it
   private and accept that the Claude reserve is machine-specific.
2. **Where do `op-fetch` and `agent-whoami` live?** Both come from
   `mcp-hub`, which is a private GitHub repo. Options: vendor copies into
   `dependencies/<name>/` (drift risk, the rules file already warns about
   hand copies), or make `install.sh` clone `mcp-hub` and run its
   `install-bin.sh` (needs the private repo's access on the new machine),
   or publish the two scripts on their own. The rules file says never
   hand-link them; whichever option wins, `install.sh` calls
   `install-bin.sh` rather than making its own symlinks.
3. **Does a subscriber repo carry the directory?** Probably not: it is a
   host concern, and `refresh-repo.sh` vendors contract files, not tooling.
   But `autometta-setup` (the skill) should tell an agent to run
   `autometta deps` on the host before subscribing anything.

## Stages, if approved

- **138**: `dependencies/README.md` index and the four-file shape; move
  the eleven `check-deps.sh` probes across; `autometta deps` verb;
  `check-deps.sh` becomes the loop. Smoke: output shape unchanged, a
  fixture directory with one MISSING dependency produces one MISSING line
  naming its brief.
- **139**: `quota-publisher-claude` contract, probe and brief; the contract
  text moves out of `docs/observability.md`. Depends on decision 1 for
  whether an `install.sh` ships.
- **140**: `op-fetch`, `agent-whoami`, `op-service-account`,
  `codex-home-api` briefs. Depends on decision 2.
- **141**: `autometta-setup` skill and `docs/setup.md` section 1 point at
  the directory instead of restating it; the prerequisites list becomes
  the index table.

Nothing above changes dispatch, the tick, or the budget file. It is docs
and probes, which is the layer a fresh machine needs first.
