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
to the installed Autometta root. If `tmux` is installed, it also starts a
detached read-only viewer named `autometta-<project-name>`.

Before running `autometta tick`, review and commit the repo setup files. The tick
refuses to operate with dirty non-state files.

```sh
git status --short
git add .gitignore state/state.yaml state/budget.json
git commit -m "Initialise Autometta"
```

## 4. Scheduling

macOS uses one LaunchAgent per subscribed repo. `autometta subscribe <repo>`
installs it automatically after writing the subscriber yaml. The committed
template lives in the subscriber repo at `.autometta/launchagent.plist.tpl`; edit
that template if you need a different interval or log layout, then re-run:

```sh
autometta install-launchagent <path-to-repo>
```

The installed plist is written to `~/Library/LaunchAgents/` and is not committed.
It runs `autometta tick` in the user's Aqua session so CLI credentials stored in
the login keychain are available to workers and verifiers.

Non-macOS hosts keep the cron heartbeat model. Sample cron entry to run every 5
minutes:

```sh
*/5 * * * * autometta tick >> "$HOME/.phat-controller/log/cron.log" 2>&1
```

Migration from the old global cron sample:

```sh
crontab -l | grep autometta
```

`autometta install-launchagent <repo>` removes the exact autometta-managed cron
sample above when it finds it, so a macOS repo is not double-scheduled. If you
created a hand-written cron line with different paths or logging, remove that
manual entry yourself after confirming the LaunchAgent is listed:

```sh
launchctl list | grep com.autometta.tick.<repo-name>
```

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

Open or create the tmux viewer:

```sh
autometta attach .
```

Lint scripts without executing setup actions:

```sh
bash -n bin/autometta scripts/check-deps.sh scripts/init-host.sh scripts/subscribe-repo.sh scripts/install-launchagent.sh scripts/uninstall-launchagent.sh scripts/tick.sh
```

## 6. Publish guard

Autometta ships the canonical `repo-publish-workflow` guard at `scripts/git-hooks/` and `scripts/install-guards.sh`. The shim is committed so any fresh clone can re-arm in one command:

```bash
bash scripts/install-guards.sh
```

That installs `.git/hooks/pre-commit` and `.git/hooks/pre-push` and seeds a gitignored `.publish-guard.local` from `.publish-guard.local.example`. Set the per-repo gate config once (see `docs/PUBLISH-WORKFLOW.md` for the full list of `publishguard.*` keys), then re-run `install-guards.sh` and it writes the `git publish` alias.

Edit `.publish-guard.local` with the machine-specific values (home path, username, email). The pre-commit hook is toothless until that file carries real patterns, so a fresh clone is safe by default but unguarded against operator-specific leaks; never push from an unarmed clone.

The hooks block (a) any commit that contains a personal-pattern string from `.publish-guard.local`, (b) any push of a non-default branch to the public remote (matched by `publishguard.publicmatch`), and (c) any push of the default branch to the public remote unless the `PUBLISH_GUARD_OK=1` sentinel is set, which only the `git publish` alias does. Override any of these with `--no-verify` if you intend the action.

For a deeper introduction or to retrofit a repo that pre-dates this pattern, use the `repo-publish-workflow` skill directly.

## 7. Auth routes (subscription vs API key)

Every dispatched agent (worker or verifier) runs on either its OAuth subscription session (Claude Pro / ChatGPT plan) or its API key (`OPENAI_API_KEY` for Codex, `ANTHROPIC_API_KEY` for Claude). Default for both families is `subscription`. Aligned to the `auth-route-security` skill: every launch goes through `op-fetch`, which exec's the child with `env -i` + an allowlist + named refs only — so no stray API key from your parent shell can accidentally redirect billing.

### One-time setup

1. Install `op-fetch` (typically at `~/Scripts/op-fetch`) and a 1Password service-account token at `~/.config/op/service-account.env` (or wherever `$OP_SERVICE_ACCOUNT_ENV` points). See the auth-route-security skill for details. The service account must have read access to the vaults that hold your Codex / Claude API keys.
2. Copy `op-refs.local.sh.example` to `op-refs.local.sh` in the autometta repo root and replace the placeholders with the real op:// references. `op-refs.local.sh` is gitignored.
3. In the **subscribed repo** (the one whose dispatches you are routing), copy `.autometta.local.yaml.example` to `.autometta.local.yaml` and set the `auth.<family>.mode` per family.

### Two committed files, one gitignored

```sh
op-refs.sh                  # COMMITTED — placeholder refs, sources op-refs.local.sh
op-refs.local.sh.example    # COMMITTED — template showing the real-ref format
op-refs.local.sh            # GITIGNORED — your actual op:// references
```

`op-refs.sh` declares `OP_REF_OPENAI_API_KEY`, `OP_REF_ANTHROPIC_API_KEY`, `OP_REF_CLAUDE_CODE_OAUTH_TOKEN` with `op://YOUR_VAULT/...` placeholders, then sources `op-refs.local.sh` to let your real values override.

### Per-repo mode toggle

`.autometta.local.yaml` (gitignored under `*.local`) carries only the mode:

```yaml
auth:
  codex:
    mode: api          # subscription | api
  claude:
    mode: subscription
```

Override at dispatch time without editing the manifest:

```sh
AUTOMETTA_CODEX_MODE=api  autometta tick
AUTOMETTA_CLAUDE_MODE=api autometta tick
```

### Verify before any dispatch

```sh
autometta auth status            # mode + ref provenance per family
autometta auth check codex       # PASS / FAIL / subscription with redacted credential
autometta auth check claude
```

`auth check` calls `op-fetch --print` against the configured ref — if the service-account token resolves it, the dispatch path will too. The resolved key is redacted in the report and never written to disk.

### How it dispatches

`scripts/spawn-worker.sh` and `scripts/spawn-verifier.sh` source `op-refs.sh`, ask `scripts/auth-route.sh <family>` for the NAME=ref pair (empty when subscription), then invoke `op-fetch <pairs> -- codex exec ...` / `op-fetch <pairs> -- claude -p ...`. In subscription mode no key is fetched but the child still gets the sanitised env. In api mode a single key is fetched and injected with nothing else from the parent shell. Fails closed: missing `op-fetch`, an unset `OP_REF_*`, or a placeholder ref aborts the spawn before any token is spent.

For manual orchestrator dispatches outside the loop, the pattern is:

```sh
source "$autometta_root/op-refs.sh"
auth_pairs="$(REPO_ROOT=$repo scripts/auth-route.sh codex)"
op-fetch $auth_pairs -- codex exec -C "$repo" --sandbox workspace-write "$prompt" </dev/null >log 2>&1 &
```

## 8. Uninstall

Remove one subscriber:

```sh
autometta uninstall-launchagent <path-to-repo>
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
