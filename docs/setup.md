# Self-host setup

## 1. Prerequisites

Required commands:

- `bash` 3.2+ (macOS default is fine; the scripts do not use bash 4+ features)
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

Validate dependencies:

```sh
scripts/check-deps.sh
```

## 2. One-time machine setup

Initialise the host controller home once per machine:

```sh
scripts/init-host.sh
```

This creates `${PHAT_CONTROLLER_HOME:-$HOME/.phat-controller}` with:

- `subscribers/`
- `log/`
- `config.yaml`
- `subscribers/template.yaml`

The script is idempotent and safe to re-run.

## 3. Per-repo subscription

Subscribe one repository to the controller:

```sh
scripts/subscribe-repo.sh <path-to-repo>
```

Example:

```sh
scripts/subscribe-repo.sh .
```

This creates repo-local state under `state/` and a subscriber file under `${PHAT_CONTROLLER_HOME:-$HOME/.phat-controller}/subscribers/`.

## 4. Scheduling

Sample cron entry to run every 5 minutes from this repo root:

```sh
*/5 * * * * cd /path/to/autometta && scripts/tick.sh >> "$HOME/.phat-controller/log/cron.log" 2>&1
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

Lint scripts without executing setup actions:

```sh
bash -n scripts/check-deps.sh scripts/init-host.sh scripts/subscribe-repo.sh scripts/tick.sh
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
