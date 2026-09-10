# Machine dependencies

This repo ships prose, templates, and bash. It assumes a machine already
carries a working set of vendor CLIs, Homebrew tools, one 1Password service
account, and a handful of the operator's own scripts that live outside this
tree entirely. None of that arrives with a fresh clone.

## Credential symlinks

`check-deps` refuses any symlink in the checkout that resolves into the Codex,
Autometta, or 1Password configuration directories, or to `auth.json`,
`.credentials.json`, or an `op-refs` script. It reports the link and the
credential category only; it never reads the target. Keep local links to
operator configuration under `~/.config/autometta/symlinked-config`, outside
the checkout, rather than recreating the former `symlinked-config/` directory
here.

## Discovery method

Grep each file under `scripts/` and `bin/autometta` for `command -v`, for
literal `$HOME` / `~/` path fragments, and for named external binaries
(`op-fetch`, `ollama`, `brew`, `tmux`, `yq`, `jq`). Read only the lines the
grep points at, plus the surrounding function, to see how the script reacts
when the thing is missing: does it call a `pass` / `missing` / `warn`
function (`scripts/check-deps.sh`), guard with its own `if` and degrade, or
assume success and let the shell fail bare. Cross-check `docs/setup.md` for
the operator-facing install steps that name a dependency `check-deps` does
not probe. Repeat this sweep whenever `scripts/` gains a new `command -v` or
a new `$HOME`-rooted path; the two greps below are the whole method:

```sh
grep -rnoE 'command -v [a-zA-Z0-9_-]+' scripts/ bin/
grep -rnoE 'HOME[a-zA-Z_/.~]*|~/[A-Za-z0-9._/-]+' scripts/ bin/ templates/
```

## Inventory

| Dependency | Source | Failure mode | Already probed |
| --- | --- | --- | --- |
| `bash` 3.2+ | ships with macOS | fail-closed, named, via the bash version check in `check-deps.sh` | yes, `check-deps` |
| `git` | Xcode CLT / Homebrew | fail-closed, named, via the `for cmd in ...` loop in `check-deps.sh` | yes, `check-deps` |
| `jq` | Homebrew formula | fail-closed, named, via the `for cmd in ...` loop in `check-deps.sh`; also probed inline by `spawn-verifier.sh` before it reads an envelope | yes, `check-deps` |
| `yq` | Homebrew formula | fail-closed, named, via the `for cmd in ...` loop in `check-deps.sh`; every manifest-reading script re-checks (`ensure_yq_or_halt` in `tick.sh`, `main` in `spawn-worker.sh`) | yes, `check-deps` |
| `python3` | ships with macOS / Homebrew | fail-closed, named, via the `for cmd in ...` loop in `check-deps.sh`; also required directly by `claude-token-log.sh` and `facts-lint.sh` | yes, `check-deps` |
| `codex` (Codex CLI) | vendor installer | fail-closed, named, via the `for cmd in ...` loop in `check-deps.sh` | yes, `check-deps` |
| `claude` (Claude Code CLI) | vendor installer | fail-closed, named, via the `for cmd in ...` loop in `check-deps.sh` | yes, `check-deps` |
| `agent-whoami` | operator's own script, symlinked onto `PATH` from mcp-hub | fail-closed, named, via its own named check in `check-deps.sh`; `facts-backfill.sh` falls back to an env var instead | yes, `check-deps` |
| `op-fetch` | operator's own script, typically `~/Scripts/op-fetch` | fail-closed, named, via its own named check in `check-deps.sh`; every spawn (`main` in `spawn-worker.sh` and `spawn-verifier.sh`, `pc_pass` in `phat-controller.sh`) checks for it again | yes, `check-deps` |
| `op` (1Password CLI) | vendor installer | fail-closed, named, via its own named check in `check-deps.sh` | yes, `check-deps` |
| `tmux` | Homebrew formula | warns and continues; `report_orphans` and the viewer creation in `attach.sh` degrade to no live viewer | yes, `check-deps` (warn only) |
| `git-push-check` | operator's own script, symlinked from mcp-hub | silent refusal to push, logged but non-fatal: `pc_push` in `phat-controller.sh` journals a refusal and returns 3 if absent | **no** |
| `ollama` | Homebrew formula or vendor installer | fail-closed, named, but only at the moment a `local` route is dispatched: `codex_local_preflight` in `models.sh`, the opening check in `candidate-viability.sh` | **no**, absent from `check-deps` |
| `brew` (Homebrew) | vendor installer | fail-closed, named, but only inside `install-homebrew-local.sh`; `check-installed-build.sh` degrades to skipping the brew-drift check | **no** |
| `realpath` | ships with modern macOS/coreutils | silent degradation: `resolve_path` in `attach.sh` falls back to a `python3` one-liner | no, but the fallback makes this low-risk |
| `gzip` | ships with macOS | silent degradation: `sweep_repo_retention` in `tick.sh` skips worker-log compaction if absent | no, low-risk |
| `xdg-open` | Linux desktop convention, absent on macOS | silent degradation: `open_page` in `dashboard.sh` prints a manual-open message | no, expected absent on macOS |
| `launchctl` / `plutil` | ship with macOS | silent degradation: `label_is_loaded` in `check-installed-build.sh` and the LaunchAgent check in `health-check.sh` skip the LaunchAgent liveness check | no |
| XDG op-refs file (`~/.config/autometta/op-refs.local.sh`) | operator-authored, from `templates/op-refs.local.sh.tpl` | fail-closed, named: `auth.sh` and `auth-route.sh` report `placeholder` and refuse to dispatch (`cmd_check` in `auth.sh`) | yes, `auth check` |
| 1Password service-account env (`~/.config/op/service-account.env` or `$OP_SERVICE_ACCOUNT_ENV`) | operator-provisioned 1Password vault | fail-closed only indirectly: `op-fetch` itself refuses, this repo just reports whatever `op-fetch --print` returns (`cmd_check` in `auth.sh`) | partial, `auth check` (via `op-fetch --print`) |
| Sibling `CODEX_HOME` (`~/.codex-api-only`) | operator-provisioned via `codex login --with-api-key` | fail-closed, named: `cmd_check` in `auth.sh`, `spawn-worker.sh` and `pc_pass` in `phat-controller.sh` all refuse codex-api dispatch without it | yes, `auth check codex` |
| LaunchAgent plists (`~/Library/LaunchAgents/*.plist`) | rendered from `templates/launchagent.plist.tpl` by `install-launchagent.sh` | silent degradation: no automated tick ever runs, `tick_jobs` in `health-check.sh` and the launchd-dirs walk in `check-installed-build.sh` are the only surfacing points and neither runs unprompted | partial, `health-check.sh` (manual invocation only) |

## Gaps

Worst first, ranked by how quietly the absence manifests:

1. **`git-push-check` absent** manifests as work silently never reaching a
   remote. `pc_push` journals a refusal, logs one line and moves on; there is no
   escalation, no red status anywhere an operator is likely to look, and the
   symptom (an unpushed branch) looks identical to "nothing to push yet".
2. **LaunchAgent plists absent or unloaded** manifest as a fleet that simply
   never ticks again after a reboot or a `brew` reinstall wipes
   `~/Library/LaunchAgents/`. Nothing polls for this; `health-check.sh` only
   catches it if an operator thinks to run it.
3. **1Password service-account token missing or expired** manifests as every
   dispatch failing one at a time, discovered only when the next tick's log
   is read, because `check-deps.sh` cannot probe a token it never touches
   directly; the failure surfaces one layer down, inside `op-fetch` itself.
4. **`brew` absent** manifests as `install-homebrew-local.sh` failing loudly,
   but `check-installed-build.sh` silently skips its drift check instead of
   warning that drift can no longer be detected at all.
5. **`ollama` absent or not serving** manifests loudly, but only at the
   moment a `local` route is actually dispatched; a repo that never
   exercises the local route carries this gap invisibly for months, and nothing
   in `check-deps.sh` would tell an operator setting up a new machine that it
   is expected at all.
6. **`realpath`, `gzip`, `xdg-open`, `launchctl`, `plutil` absent** each
   degrade a convenience path (path canonicalisation, log compaction, opening
   a browser, LaunchAgent liveness) rather than a dispatch; low risk
   individually, but none of the five is named anywhere in `check-deps.sh`,
   so a Linux port or a minimal container image would silently lose several
   of these without a single line of diagnostic output.
