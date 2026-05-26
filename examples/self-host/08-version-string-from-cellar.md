# Stage card 08-version-string-from-cellar: `autometta --version` should report the installed Cellar SHA, not a stale upstream ref

## Metadata

- **Authored:** 2026-05-26
- **Orchestrator:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Worker:** Codex GPT-5.3 <codex-gpt-5-3@local>
- **Verifier:** Claude Sonnet 4.6 <claude-sonnet-4-6@local>
- **Pairing rationale:** Cross-family. Small bin-script change but the verifier needs to confirm the reported version actually tracks what is installed across brew reinstall + dev mode + AUTOMETTA_ROOT-override mode.

## Objective

`autometta --version` currently prints a stale string (observed: `10a163ac12`) regardless of which Cellar build is installed. The bin wrapper at `libexec/bin/autometta` runs `git rev-parse --short HEAD` against `$autometta_root` (= `libexec`), which is not a git repo; the value `10a163ac12` is leaking from some ancestor git directory (likely a tap repo). The Cellar path `/opt/homebrew/Cellar/autometta/<sha>/` is the only currently-reliable signal of which build is live.

Make the version report match the installed build:

1. **Install-time version embedding.** `install-homebrew-local.sh` already passes a `__AUTOMETTA_VERSION__` placeholder into the formula template; the template substitutes it into the formula's `version` field but the CLI does not read that. Write the resolved version into a `libexec/VERSION` file at install time and have the CLI read that.
2. **Dev mode fallback.** When the CLI is run directly from a working checkout (not via brew), use `git rev-parse --short HEAD` against the checkout root.
3. **AUTOMETTA_ROOT override.** Honour the env var when set; use its git rev if it points at a checkout, otherwise the embedded VERSION file.

The result: `autometta --version` always reports the actually-running build's identifier.

## Inputs (read these in your own context)

- `bin/autometta`
- `scripts/install-homebrew-local.sh`
- `packaging/homebrew/autometta.rb.template`
- `docs/setup.md` (any docs that quote the --version output)

Do not read anything else.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. `bin/autometta` — change the `--version|version` case branch to:
   - First, read `$autometta_root/VERSION` if it exists and is non-empty.
   - Otherwise, attempt `git -C "$autometta_root" rev-parse --short HEAD`; on success, print that.
   - Otherwise, print `autometta local`.
2. `scripts/install-homebrew-local.sh` — write the resolved `$version` string into `$autometta_root/VERSION` immediately before `tar` so the file lands in the brew install.
3. `.gitignore` — add `/VERSION` (the in-source dev tree should never have a stale baked VERSION file shadowing the git-derived one).

## Constraints

- No format change to the printed version line. It still reads `autometta <token>\n`.
- Bash 3.2 compatibility (macOS default).
- All shell scripts must pass `bash -n` syntax check.
- No modifications to `tick.sh` or any other script outside the deliverables.
- No new dependencies.
- Worker does NOT self-commit. Orchestrator commits on verifier-pass per the new dispatch model (stage 07 in the autometta self-host history).
- Atomic commits with `--author="<worker-identity>"`; push via the `git publish` alias.
- After commit + push, run `bash scripts/install-homebrew-local.sh` from the repo root to refresh the brew copy; confirm `autometta --version` then reports the new SHA.

## Acceptance criteria

1. `bash -n bin/autometta && bash -n scripts/install-homebrew-local.sh` passes.
2. `bin/autometta` reads from `VERSION` file before falling back to git.
3. `scripts/install-homebrew-local.sh` writes the resolved version into `$autometta_root/VERSION` before the `tar` step.
4. `.gitignore` contains a `/VERSION` (or `VERSION`) entry that prevents the in-source VERSION file from being committed.
5. After running `bash scripts/install-homebrew-local.sh`, `autometta --version` outputs `autometta <current-publish-HEAD-short-sha>`, NOT `10a163ac12`.
6. When run from a fresh checkout (no VERSION file, in a git tree), `autometta --version` falls back to `git rev-parse --short HEAD` correctly.
7. No files outside the deliverables set are modified — except this stage card itself, which is exempt per `memory/feedback-acceptance-criterion-stage-card-exemption.md`.
8. Publish-guard pre-push hook continues to pass.

## Out of scope

- Switching to a long-SHA or semver scheme. Short SHA is fine.
- A `--version --verbose` flag exposing the install path + build date. Future work.
- Auto-updating the `__AUTOMETTA_VERSION__` placeholder logic in the formula template (already works).
- Any other CLI subcommand.

## Budget

- **Worker wall-clock:** 25 minutes
- **Verifier wall-clock:** 10 minutes

## Verifier handoff

Worker returns:

- List of modified files + commit SHAs.
- The before/after output of `autometta --version`.
- Confirmation that `git publish` succeeded on both remotes.
- Confirmation that the brew reinstall emitted `PASS installed autometta`.
- One-line confirmation that no `git commit` was invoked from the worker phase.

## Family-specific notes

- Codex worker: `</dev/null` stdin redirect; **do not run `git commit`** in your phase. Leave changes uncommitted; the orchestrator commits on verifier-pass.
- Claude verifier: cross-family. Check both the bin-script change and the install-script change land together and the printed version actually updates after reinstall.
