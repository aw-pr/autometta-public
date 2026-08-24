# Stage card 56: phat-controller is the minder, not the loop

## Metadata

- **Authored:** 2026-08-24
- **Orchestrator:** Claude Fable 5 <claude-fable-5@local>
- **Worker:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Base branch:** dev
- **Run branch:** autometta/56-phat-controller-is-the-minder-not-the-loop
- **Worker effort:** medium
- **Verifier effort:** medium
- **Verifier panel:** false
- **Pairing rationale:** a rename that threads through paths, env vars,
  a LaunchAgent and a registry other repos depend on; verified
  cross-family because the failure mode is a subscriber silently losing
  its controller home mid-window.

## Objective

The operator's decision, 2026-08-24: the name **phat-controller** belongs
to the queue-minding agent role card 54 builds (the thing that controls),
not to the cron tick loop that currently carries it. The loop is the
tick; it should be named as such.

Today the name is spread across: the controller home `~/.phat-controller`
(log/, subscribers/, config.yaml), the `PHAT_CONTROLLER_*` environment
variables in `scripts/attach.sh` and friends, `docs/phat-controller.md`,
and prose across README, MANUAL and the docs. The LaunchAgents are
already autometta-named (`com.autometta.tick.fleet`) and need no rename.

After this card: the tick loop and its home are autometta-named, the
docs call the loop "the tick loop", and the name phat-controller is
vacant for card 54's role to take.

## Inputs (read these in your own context)

- `git grep -ln 'phat.controller\|PHAT_CONTROLLER'` for the full surface;
  trust the grep over this card's list.
- `scripts/init-host.sh` (writes the controller home),
  `scripts/tick.sh`, `scripts/attach.sh`, `scripts/subscribe-repo.sh`.
- `templates/launchagent.plist.tpl` (WorkingDirectory points at the
  home).
- `docs/phat-controller.md`, `docs/setup.md`, `README.md`, `MANUAL.md`.
- Card 54, whose role takes the vacated name.

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. The controller home becomes `~/.autometta` (override
   `AUTOMETTA_HOME`), with a one-time migration in `init-host.sh`: if
   the old home exists and the new does not, move it and leave a
   symlink `~/.phat-controller -> ~/.autometta` so anything unmigrated
   keeps working. Idempotent; re-running is a no-op.
2. `PHAT_CONTROLLER_*` env vars gain `AUTOMETTA_*` names; the old names
   keep working as fallbacks for one release, each fallback site
   commented as deprecated.
3. `docs/phat-controller.md` becomes `docs/tick-loop.md` (git mv), its
   prose retitled; a one-paragraph stub may remain at the old path
   naming the move.
4. README, MANUAL and docs prose: the loop is "the tick loop"; the name
   phat-controller is reserved for the queue-minding role, stated once
   where the roles are enumerated.
5. The fleet LaunchAgent plist template's WorkingDirectory follows the
   new home; the operator re-runs `install-launchagent.sh` at a queue
   gap, documented as the one manual step.
6. Card 54's references updated: the role ships under the name
   phat-controller (`scripts/phat-controller.sh`,
   `templates/phat-controller-prompt.md`, role string in the cost log),
   amending that card's deliverable names in place.

## Constraints

- Nothing breaks mid-migration: every read of the home goes through one
  resolver that accepts both paths until the symlink retires. A running
  tick during the move must complete its pass.
- No subscriber repo is touched; the registry moves with the home.
- The `session_slug` and tmux session names do not change.
- British English, no em dashes.

## Acceptance criteria

1. On a fixture home at the old path, `init-host.sh` migrates, symlinks,
   and a second run is a no-op; a tick against the migrated home
   completes.
2. Both env spellings work for every renamed variable, demonstrated for
   at least the fleet session and refresh interval variables.
3. `git grep -i 'phat.controller'` after the change returns only: the
   deprecation fallbacks, the stub doc, the role's own files, and
   historical documents, each named in the handoff.
4. The docs enumerate the roles with phat-controller as the minder and
   the tick loop as the loop.
5. `bash -n` on every touched shell file; every offline smoke passes.

## Contract test

- **Test file:** None
- **Assertions digest:** None

## Out of scope

- Building the role itself; that is card 54.
- Renaming LaunchAgent labels (already autometta-named).
- Retiring the symlink and fallbacks; a later card.

## Budget

- **Worker wall-clock:** 60 minutes
- **Verifier wall-clock:** 30 minutes

## Verifier handoff

Return the migration fixture evidence, the dual-spelling demonstration,
the residual-grep list with each site justified, and confirmation the
live home on this machine was either migrated cleanly or deliberately
left for the operator, stating which.

## Family-specific notes

None
