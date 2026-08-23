# Stage card 42: ship the installed build and make drift detectable

## Metadata

- **Authored:** 2026-08-23
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Claude Opus 5 <claude-opus-5@local>
- **Verifier:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Base branch:** dev
- **Run branch:** autometta/42-ship-the-installed-build-and-detect-drift
- **Worker effort:** medium
- **Verifier effort:** medium
- **Verifier panel:** false
- **Pairing rationale:** packaging and a shell guard, no browser and no window
  server. Cross-family verification because the failure being guarded against
  is one an author is least likely to spot in their own change.

## Objective

`/opt/homebrew/bin/autometta` resolves into `Cellar/autometta/<sha>/libexec/`,
and the scripts there are **copies** taken at install time, not links into the
checkout. A committed fix therefore does not reach the fleet tick until the tap
is rebuilt, and nothing currently reports that gap.

This bit on 2026-08-23. `ae41921` fixed `ensure_run_worktree` to share
`node_modules` with each run worktree. The installed build was still the older
copy, so the fix would not have applied to a single dispatch that night. It was
made live by copying the file straight onto the Cellar copy, which is drift the
next legitimate install silently reverts.

Two things are owed: ship HEAD properly, and make "is the fleet running what we
committed" a question something answers.

## Inputs (read these in your own context)

- `scripts/install-homebrew-local.sh`
- `packaging/homebrew/autometta.rb.template`
- `scripts/doctor-platforms.sh`
- `VERSION`
- `docs/dispatch-contract.md`

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. A rebuilt local tap installed from current `dev`, so
   `Cellar/autometta/<sha>/libexec/scripts/tick.sh` is byte-identical to
   `git show HEAD:scripts/tick.sh`, and `VERSION` matches the installed sha.
2. `scripts/check-installed-build.sh` — reports whether the installed build
   matches the checkout. Exit 0 on match, 1 on drift naming each differing
   file, 2 when no install is found. Model the reporting on
   `scripts/autometta-vendor-check.sh`, which answers the same question for
   vendored files in a subscriber.
3. `scripts/doctor-platforms.sh` calls the new check, so an ordinary platform
   doctor run surfaces the gap.
4. A short subsection in `docs/dispatch-contract.md` stating that the installed
   build is a copy, that a committed fix is inert until reinstall, and how to
   check.

## Constraints

- Do not make the Cellar files symlinks into the checkout. The install is meant
  to be a fixed artefact; a live link would make every uncommitted edit in the
  working tree immediately load-bearing for the whole fleet.
- Do not hand-patch Cellar files anywhere in this work. Reinstall is the
  supported route, and the point of the card is to remove the temptation.
- The check must not require network access or `brew` itself to be runnable; it
  compares files on disk.
- Relative paths only in committed code. `/opt/homebrew` may be referenced as a
  default that `HOMEBREW_PREFIX` or an argument overrides.
- A reinstall replaces files the running fleet tick executes. Do it when no
  dispatch is in flight, or accept that a tick mid-execution keeps the inode it
  started with.

## Acceptance criteria

1. `scripts/check-installed-build.sh` exits 0 against the freshly installed
   build, and its output names the installed sha and the checkout HEAD.
2. Deliberately perturbing one installed file (in a scratch copy, or by
   pointing the script at a doctored prefix) makes it exit 1 and name that
   file. Restore anything perturbed.
3. `scripts/doctor-platforms.sh --check` (or its nearest existing flag) runs the
   new check and reflects its verdict.
4. The installed `libexec/scripts/tick.sh` contains the `node_modules` sharing
   block from `ae41921`, and matches `git show HEAD:scripts/tick.sh` byte for
   byte.
5. `docs/dispatch-contract.md` documents the copy semantics and the check.
6. `bash -n` passes on every shell file touched, and no file outside the
   deliverables is modified except this card.

## Contract test

- **Test file:** None
- **Assertions digest:** None

## Out of scope

- Publishing the tap anywhere beyond this machine.
- Changing how `autometta` resolves its own root at runtime.
- Any change to `tick.sh` behaviour. `ae41921` is already committed; this card
  ships it, it does not revisit it.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 25 minutes

## Verifier handoff

Return the installed sha before and after, the output of the new check in both
the matching and the perturbed case, and confirmation that criterion 4 holds by
diff. State explicitly whether any Cellar file was edited by hand.

## Family-specific notes

None
