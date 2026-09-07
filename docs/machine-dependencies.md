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
| `bash` 3.2+ | ships with macOS | fail-closed, named, via `check-deps.sh:30` | yes, `check-deps` |
| `git` | Xcode CLT / Homebrew | fail-closed, named, via `check-deps.sh:44` | yes, `check-deps` |
| `jq` | Homebrew formula | fail-closed, named, via `check-deps.sh:44`; also probed inline (`spawn-verifier.sh:106`) | yes, `check-deps` |
| `yq` | Homebrew formula | fail-closed, named, via `check-deps.sh:44`; every manifest-reading script re-checks (`tick.sh:138`, `spawn-worker.sh:92`) | yes, `check-deps` |
| `python3` | ships with macOS / Homebrew | fail-closed, named, via `check-deps.sh:44`; also required directly by `claude-token-log.sh:18` and `facts-lint.sh:67` | yes, `check-deps` |
| `codex` (Codex CLI) | vendor installer | fail-closed, named, via `check-deps.sh:44` | yes, `check-deps` |
| `claude` (Claude Code CLI) | vendor installer | fail-closed, named, via `check-deps.sh:44` | yes, `check-deps` |
| `agent-whoami` | operator's own script, symlinked onto `PATH` from mcp-hub | fail-closed, named, via `check-deps.sh:55`; `facts-backfill.sh:22` falls back to an env var instead | yes, `check-deps` |
| `op-fetch` | operator's own script, typically `~/Scripts/op-fetch` | fail-closed, named, via `check-deps.sh:83`; every spawn (`spawn-worker.sh:174`, `spawn-verifier.sh:296`, `phat-controller.sh:1598`) sources it again | yes, `check-deps` |
| `op` (1Password CLI) | vendor installer | fail-closed, named, via `check-deps.sh:90` | yes, `check-deps` |
| `tmux` | Homebrew formula | warns and continues; `attach.sh:165` and `attach.sh:232` degrade to no live viewer | yes, `check-deps` (warn only) |
| `git-push-check` | operator's own script, symlinked from mcp-hub | silent refusal to push, logged but non-fatal: `phat-controller.sh:1149` skips the push entirely if absent | **no** |
| `ollama` | Homebrew formula or vendor installer | fail-closed, named, but only at the moment a `local` route is dispatched: `models.sh:310`, `candidate-viability.sh:14` | **no**, absent from `check-deps` |
| `brew` (Homebrew) | vendor installer | fail-closed, named, but only inside `install-homebrew-local.sh:105`; `check-installed-build.sh:91` degrades to skipping the brew-drift check | **no** |
| `realpath` | ships with modern macOS/coreutils | silent degradation: `attach.sh:41` falls back to a `python3` one-liner | no, but the fallback makes this low-risk |
| `gzip` | ships with macOS | silent degradation: `tick.sh:2360` skips worker-log compaction if absent | no, low-risk |
| `xdg-open` | Linux desktop convention, absent on macOS | silent degradation: `dashboard.sh:146` prints a manual-open message | no, expected absent on macOS |
| `launchctl` / `plutil` | ship with macOS | silent degradation: `check-installed-build.sh:234` and `health-check.sh:96` skip the LaunchAgent liveness check | no |
| XDG op-refs file (`~/.config/autometta/op-refs.local.sh`) | operator-authored, from `templates/op-refs.local.sh.tpl` | fail-closed, named: `auth.sh` and `auth-route.sh` report `placeholder` and refuse to dispatch (`auth.sh:210`) | yes, `auth check` |
| 1Password service-account env (`~/.config/op/service-account.env` or `$OP_SERVICE_ACCOUNT_ENV`) | operator-provisioned 1Password vault | fail-closed only indirectly: `op-fetch` itself refuses, this repo just reports whatever `op-fetch --print` returns (`auth.sh:217`) | partial, `auth check` (via `op-fetch --print`) |
| Sibling `CODEX_HOME` (`~/.codex-api-only`) | operator-provisioned via `codex login --with-api-key` | fail-closed, named: `auth.sh:230`, `spawn-worker.sh`, `phat-controller.sh:1613` all refuse codex-api dispatch without it | yes, `auth check codex` |
| LaunchAgent plists (`~/Library/LaunchAgents/*.plist`) | rendered from `templates/launchagent.plist.tpl` by `install-launchagent.sh` | silent degradation: no automated tick ever runs, `health-check.sh:61` and `check-installed-build.sh:199` are the only surfacing points and neither runs unprompted | partial, `health-check.sh` (manual invocation only) |

## Gaps

Worst first, ranked by how quietly the absence manifests:

1. **`git-push-check` absent** manifests as work silently never reaching a
   remote. `phat-controller.sh:1149` logs one line and moves on; there is no
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
