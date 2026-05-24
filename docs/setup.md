# Self-host setup

## 1. Prerequisites

Required commands:

- `bash` 3.2+ (macOS default is fine; the scripts do not use bash 4+ features)
- `brew` (for the local `autometta` CLI install)
- `jq`
- `git`
- `codex`
- `claude`
- `python3`
- `yq` (required: `scripts/tick.sh` uses it for atomic YAML writes)

macOS install hints with Homebrew:

```sh
brew install jq git python yq
# bash 3.2 ships with macOS; bash 4+ is not required
# codex and claude install via your normal team path
```

Install Codex CLI and Claude Code with your normal team path.

Install or refresh the local CLI from the Autometta checkout:

```sh
scripts/install-homebrew-local.sh
```

Validate dependencies:

```sh
autometta check-deps
```

## 2. One-time machine setup

Initialise the host controller home once per machine:

```sh
autometta init-host
```

This creates `${PHAT_CONTROLLER_HOME:-$HOME/.phat-controller}` with:

- `subscribers/`
- `log/`
- `config.yaml`
- `subscribers/template.yaml`

`config.yaml` records the installed Autometta root as `autometta_root`. For a
checkout run, that is the source checkout; for the Homebrew-local install, that
is the packaged install root. The script is idempotent and safe to re-run.

## 3. Per-repo subscription

Subscribe one repository to the controller:

```sh
autometta init <path-to-repo>
```

Example:

```sh
autometta init .
```

This creates repo-local state under `state/` and a subscriber file under `${PHAT_CONTROLLER_HOME:-$HOME/.phat-controller}/subscribers/`.
It also creates a gitignored `.autometta.local.yaml` manifest that points back
to the installed Autometta root.

Before running `autometta tick`, review and commit the repo setup files. The tick
refuses to operate with dirty non-state files.

```sh
git status --short
git add .gitignore state/state.yaml state/budget.json
git commit -m "Initialise Autometta"
```

## 4. Scheduling

Sample cron entry to run every 5 minutes from this repo root:

```sh
*/5 * * * * autometta tick >> "$HOME/.phat-controller/log/cron.log" 2>&1
```

`launchd` is the macOS-native alternative if you prefer managed job lifecycle and logging.

## 5. Verify the install

Check host files:

```sh
ls -la "${PHAT_CONTROLLER_HOME:-$HOME/.phat-controller}"
ls -la "${PHAT_CONTROLLER_HOME:-$HOME/.phat-controller}/subscribers"
```

Check repo state files:

```sh
ls -la state
ls -la state/verifiers state/logs
cat state/state.yaml
cat state/budget.json
```

Check the controller at a glance:

```sh
autometta status
```

Open an optional tmux viewer:

```sh
autometta attach
```

Lint scripts without executing setup actions:

```sh
bash -n bin/autometta scripts/check-deps.sh scripts/init-host.sh scripts/subscribe-repo.sh scripts/tick.sh
```

## 6. Publish guard

Autometta ships with the publish-guard shim vendored at `scripts/publish-guard/`. The shim is committed so any fresh clone can re-arm in one command:

```bash
bash scripts/publish-guard/install-guards.sh
```

That installs `.git/hooks/pre-commit` and `.git/hooks/pre-push`, seeds a gitignored `.publish-guard.local` from the example, and adds publish-safe entries to `.gitignore`. Then edit `.publish-guard.local` with the machine-specific values (home path, username, email, public remote URL fragment, public branch). The hooks are inert until that file exists, so a fresh clone is safe by default but unguarded; never push from an unarmed clone.

The hooks block (a) any commit that contains a personal-pattern string from `GUARD_PATTERNS`, and (b) any push of a non-public branch to the public remote named in `GUARD_PUBLIC_URL_MATCH`. Override either with `--no-verify` if you intend the action.

For a deeper introduction or to retrofit a repo that pre-dates this pattern, use the `repo-publish-guard-init` or `repo-publish-guard-retrofit` skills directly.

## 7. Uninstall

Remove one subscriber:

```sh
rm "${PHAT_CONTROLLER_HOME:-$HOME/.phat-controller}/subscribers/<repo-slug>.yaml"
```

Remove the whole host setup:

```sh
rm -rf "${PHAT_CONTROLLER_HOME:-$HOME/.phat-controller}"
```

Optional repo cleanup:

```sh
rm -rf state
```
