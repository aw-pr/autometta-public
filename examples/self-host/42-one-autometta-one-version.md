# Stage card 42: one autometta, one version

## Metadata

- **Authored:** 2026-08-23, rewritten 2026-08-24
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Claude Opus 5 <claude-opus-5@local>
- **Verifier:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Base branch:** dev
- **Run branch:** autometta/42-one-autometta-one-version
- **Worker effort:** medium
- **Verifier effort:** medium
- **Verifier panel:** false
- **Pairing rationale:** shell and packaging, no browser. Cross-family
  verification because the bug class here is one an author cannot see: the
  code reads correctly, and only the environment it runs under makes it wrong.

## Objective

`autometta` runs different code depending on who invokes it.

`libexec/bin/autometta` resolves `autometta_root="${AUTOMETTA_ROOT:-$(cd
"$script_dir/.." && pwd)}"`, so a human typing `autometta` gets the Homebrew
copy under `Cellar/autometta/<sha>/libexec`. The fleet tick's LaunchAgent sets
`AUTOMETTA_ROOT=~/repos/autometta` (its own comment: "runs the working checkout
rather than the Homebrew copy, which lags HEAD"), so the same command there runs
the checkout, including uncommitted edits.

Two consequences, both observed on 2026-08-23:

1. A committed fix (`ae41921`) was live for the tick immediately, while the
   installed build still held the old file. Reasoning about "what is deployed"
   gave the wrong answer in both directions on the same day, and the file was
   hand-patched into the Cellar on a false premise.
2. `autometta --version` reports the root it happens to resolve, so it cannot
   be trusted to describe what the tick will run.

The uncommitted-edit exposure is the sharper half: with the checkout as root,
any half-finished edit in the working tree is load-bearing for every subscribed
repo at the next tick.

Pick one resolution rule, make it explicit, and make the version command tell
the truth.

## Inputs (read these in your own context)

- `bin/autometta` and `libexec/bin/autometta` (the resolution line)
- `~/Library/LaunchAgents/com.autometta.tick.fleet.plist` (read only, do not
  edit from the worktree; propose changes as deliverables)
- `scripts/install-homebrew-local.sh`
- `scripts/init-host.sh` and the controller `config.yaml` it writes
- `VERSION`
- `docs/dispatch-contract.md`

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. A single documented resolution rule for `autometta_root`, with the
   precedence order stated (explicit `AUTOMETTA_ROOT`, then the controller
   config's `autometta_root`, then the install's own libexec) and implemented
   in one place rather than restated per entry point.
2. `autometta --version` reports the resolved root, its sha, and whether that
   root is a git checkout with uncommitted changes to tracked files under
   `scripts/`. A dirty root must be visible in the output, not inferred.
3. `scripts/check-installed-build.sh` — compares the installed build against
   the checkout and reports which one the fleet tick will actually run. Exit 0
   when they agree, 1 on drift naming each differing file, 2 when either side
   is missing. Model the reporting on `scripts/autometta-vendor-check.sh`.
4. `scripts/health-check.sh` calls it, so an ordinary doctor run surfaces
   the split. (Amended 2026-08-24: the original named
   `scripts/doctor-platforms.sh`, which is an mcp-hub script that does not
   exist in this repo; `health-check.sh` is this repo's doctor surface.)
5. `docs/dispatch-contract.md` documents the rule, the precedence, and the
   dirty-checkout exposure.

## Constraints

- Do not silently change which root the fleet tick uses. If the recommendation
  is to move the tick onto the installed build, say so in the handoff and leave
  the plist edit to the operator; a worker must not repoint the live fleet.
- Do not make Cellar files symlinks into the checkout, and do not hand-patch a
  Cellar file at any point in this work.
- Relative paths in committed code. `/opt/homebrew` may appear only as a
  default that `HOMEBREW_PREFIX` overrides.
- The version command must work when the root is not a git checkout.
- Reinstalling replaces files a running tick executes. Do it when no dispatch
  is in flight.

## Acceptance criteria

1. The precedence rule is implemented once, and every entry point that resolves
   a root goes through it.
2. `autometta --version` names the resolved root and its sha, and flags a dirty
   checkout. Demonstrate both clean and dirty.
3. `check-installed-build.sh` exits 0 when install and checkout agree, and 1
   naming the file when one is perturbed. Restore anything perturbed.
4. Its output states unambiguously which root the fleet tick will run, derived
   from the plist environment rather than assumed.
5. `health-check.sh` reflects the verdict. (Amended 2026-08-24, as
   deliverable 4.)
6. `docs/dispatch-contract.md` documents rule, precedence and exposure.
7. `bash -n` passes on every shell file touched; no file outside the
   deliverables is modified except this card.

## Contract test

- **Test file:** None
- **Assertions digest:** None

## Out of scope

- Publishing the tap beyond this machine.
- Vendored-contract freshness in subscribers; that is card 48.
- Changing `tick.sh` behaviour.

## Budget

- **Worker wall-clock:** 60 minutes
- **Verifier wall-clock:** 30 minutes

## Verifier handoff

Return the resolution rule and where it is implemented, `--version` output for
clean and dirty checkouts, both `check-installed-build.sh` outcomes, and the
evidence for which root the tick runs. State explicitly whether any Cellar file
or the live plist was modified.

## Family-specific notes

None

## Re-brief for attempt 2 (2026-08-24, after the FAIL on criteria 1, 5 and 7)

Attempt 1's implementation is committed as `5cee168` (branch
`wip/42-attempt-1`). Criteria 2, 3, 4 and 6 passed; 5 and 7 failed only
on the wrong-repo path now amended above (`health-check.sh` was the right
call and is now the named deliverable). Restore the WIP and close the one
real gap, criterion 1: these entry points still resolve `autometta_root`
themselves instead of through `scripts/resolve-root.sh` —
`scripts/attach.sh:321-328`, `scripts/retro-grade.sh:5-6`,
`scripts/install-launchagent.sh:5-6`, `scripts/dashboard.sh:8-10`,
`scripts/auth.sh:19` (and grep for any sibling the verifier's list
missed). Thread each through the one resolver, re-run the smokes, hand
off.
