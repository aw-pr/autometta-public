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

This creates `${AUTOMETTA_HOME:-$HOME/.autometta}` with:

- `subscribers/`
- `log/`
- `config.yaml`
- `subscribers/template.yaml`

`config.yaml` records the installed Autometta root as `autometta_root`. For a
checkout run, that is the source checkout; for the Homebrew-local install, that
is the packaged install root. The script is idempotent and safe to re-run.

On an existing host, the first run moves `~/.phat-controller` to
`~/.autometta` when the new home does not yet exist, then leaves the relative
symlink `~/.phat-controller -> .autometta` for one release. `AUTOMETTA_HOME`
overrides the home. `PHAT_CONTROLLER_HOME` remains a deprecated fallback for
the same compatibility window.

## 3. Per-repo subscription

Subscribe one repository to the controller:

```sh
autometta init <path-to-repo>
```

Example:

```sh
autometta init .
```

This creates repo-local state under `state/` and a subscriber file under `${AUTOMETTA_HOME:-$HOME/.autometta}/subscribers/`.
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

### Queueing path claims

Serial dispatch needs no extra metadata. To opt two adjacent cards into a
pipeline pair, give both cards a comma-separated metadata line of repo-relative
file or directory paths:

```markdown
- **Path claims:** scripts/report.sh, docs/report.md
```

`autometta add-stage` stores valid claims in the stage record. Absolute paths,
`.` or `..` segments, empty entries, and characters outside letters, digits,
`.`, `_`, `/` and `-` are refused at queue time. Omitting the line keeps the
stage serial and produces no pairing log. Claims are a dispatch precondition,
not a landing guarantee: after N passes, the tick checks both actual diffs and
escalates rather than rebasing on any file overlap or conflict.

## 4. Scheduling

macOS uses one LaunchAgent per subscribed repo. `autometta subscribe <repo>`
installs it automatically after writing the subscriber yaml. The committed
template lives in the subscriber repo at `.autometta/launchagent.plist.tpl`; edit
that template if you need a different interval or log layout, then re-run:

```sh
autometta install-launchagent <path-to-repo>
```

After upgrading from the former home name, wait for a queue gap and rerun
`autometta install-launchagent <path-to-repo>` once for each subscribed repo.
This is the only manual migration step: it reloads the plist with
`~/.autometta` as its working directory. Do not reload it while a worker or
verifier is in flight.

The installed plist is written to `~/Library/LaunchAgents/` and is not committed.
It runs `autometta tick` in the user's Aqua session so CLI credentials stored in
the login keychain are available to workers and verifiers.

Non-macOS hosts keep the cron heartbeat model. Sample cron entry to run every 5
minutes:

```sh
*/5 * * * * autometta tick >> "$HOME/.autometta/log/cron.log" 2>&1
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
ls -la "${AUTOMETTA_HOME:-$HOME/.autometta}"
ls -la "${AUTOMETTA_HOME:-$HOME/.autometta}/subscribers"
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

Check that the installed build matches the checkout:

```sh
autometta check-build
```

Open or create the tmux viewer:

```sh
autometta attach .
```

Open the full-screen terminal UI:

```sh
autometta tui .
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

## 7. Auth routes: subscription, API key and free

Every dispatched agent (worker or verifier) runs on its OAuth subscription session (Claude Pro / ChatGPT plan), its API key (`OPENAI_API_KEY` for Codex, `ANTHROPIC_API_KEY` for Claude), or, codex family only, local Ollama weights with no provider at all. Resolver fallback (no manifest) is `subscription` for both families; the shipped `.autometta.local.yaml.example` recommends `codex: api` + `claude: subscription`. Aligned to the `auth-route-security` skill: every launch goes through `op-fetch`, which exec's the child with `env -i` + an allowlist + named refs only, so no stray API key from your parent shell can accidentally redirect billing.

### One-time setup

1. Install `op-fetch` (typically at `~/Scripts/op-fetch`) and a 1Password service-account token at `~/.config/op/service-account.env` (or wherever `$OP_SERVICE_ACCOUNT_ENV` points). See the auth-route-security skill for details. The service account must have read access to the vaults that hold your Codex / Claude API keys.
2. Plant the real op:// references at `~/.config/autometta/op-refs.local.sh` (gitignored; machine-wide). Use the template:
   ```sh
   mkdir -p ~/.config/autometta
   cp templates/op-refs.local.sh.tpl ~/.config/autometta/op-refs.local.sh
   chmod 600 ~/.config/autometta/op-refs.local.sh
   ```
3. **For Codex API mode** — set up a sibling `CODEX_HOME` once. Codex prefers its `auth.json` over the `OPENAI_API_KEY` env var, so an api-mode dispatch needs an isolated codex dir whose `auth.json` says `auth_mode: "apikey"`:
   ```sh
   mkdir -p ~/.codex-api-only && chmod 700 ~/.codex-api-only
   # Pipe the real key from 1Password into codex's login flow:
   op-fetch --print "$OP_REF_OPENAI_API_KEY" | \
     CODEX_HOME=~/.codex-api-only codex login --with-api-key
   ```
   Override the path globally with `AUTOMETTA_CODEX_HOME=/some/other/dir`. Verify with `cat ~/.codex-api-only/auth.json | python3 -m json.tool | head -3` — `auth_mode` must be `"apikey"`. Your main `~/.codex/auth.json` stays untouched.
4. In the **subscribed repo** (the one whose dispatches you are routing), copy `.autometta.local.yaml.example` to `.autometta.local.yaml` and set the `auth.<family>.mode` per family.

### Local weights (codex family only, `auth.codex.mode: local`)

A third codex route: `codex exec --oss --local-provider=ollama -m <model>` against weights served by a local Ollama install. Zero marginal cost, no rate limits, no provider to exhaust: useful when the week's Codex API budget is gone and cross-family verification (Codex verifying Claude workers) still needs to happen without falling back to same-family verification. It is codex-family only: `auth.claude.mode: local` is refused with a clear message, since a Claude-family local route would be a different CLI and a different piece of work.

One-time host setup:

```sh
# macOS
brew install ollama
brew services start ollama

# Linux: install, then keep `ollama serve` running in another terminal or
# under the host's service supervisor.
curl -fsSL https://ollama.com/install.sh | sh
ollama serve
```

After the server is running:

```sh
ollama pull gpt-oss:120b   # the default; scripts/models.sh:AUTOMETTA_MODEL_CODEX_LOCAL
ollama list                # confirm it shows in the NAME column
```

Keeping the server running is the operator's job, not autometta's: `ollama serve` (or the `brew services` equivalent) must already be up before any dispatch that resolves `local`, and it stays up independently of any tick or worktree. Autometta never starts, stops, or supervises it; a spawn against a stopped server fails closed with a clear message rather than launching one for you. `brew services start ollama` is the lowest-effort way to make that true across reboots on macOS; on Linux, run it under whichever supervisor keeps other long-lived local services alive on that host.

Then set the mode:

```yaml
auth:
  codex:
    mode: local
```

or override at dispatch time with `AUTOMETTA_CODEX_MODE=local`. No `OP_REF_*` and no sibling `CODEX_HOME` are needed: the spawn scripts fetch no key for this route (op-fetch still runs, so any stray `OPENAI_API_KEY` in your shell is stripped rather than silently billing the API). If `ollama` is not on `PATH`, is not serving, or the model is not pulled, the spawn fails closed before launching an agent and names the missing piece; autometta never runs `ollama serve` on your behalf.

#### Splitting the roles: local worker, cloud verifier

`auth.codex.mode` sets the route for both sides of the gate, which on the local
route means the same class of weights writes the code and judges it. A per-role
key sits underneath it:

```yaml
auth:
  codex:
    mode: local            # the family default: both roles, unless overridden
    verifier:
      mode: subscription   # the gate runs on a cloud model
```

Resolution is most-specific-wins: `AUTOMETTA_CODEX_MODE_VERIFIER` (or
`_WORKER`), then `AUTOMETTA_CODEX_MODE`, then `auth.codex.<role>.mode`, then
`auth.codex.mode`, then the `subscription` default. A repo that sets no per-role
key dispatches exactly as it did before.

The pairing this buys is free weights writing the code against a metered model
judging it, which costs verifier tokens only and holds the gate at a tier the
worker cannot reach. It is worth knowing what the free-both-sides arrangement
actually failed at in practice: local weights can write correct code and still
be unable to hold the protocol around it, writing no worker envelope or never
landing an `apply_patch` call, so the stage stalls on plumbing rather than on
the work. A cloud verifier removes that failure from the half of the gate where
it is fatal.

Which cloud model the verifier reaches is the card's business, not this key's:
a role's declared identity names its weights (`Codex GPT-5.6 Terra` dispatches
to `gpt-5.6-terra`), and an identity naming none of Sol, Terra or Luna falls
back to `AUTOMETTA_MODEL_CODEX`.

Local weights are a real step down in capability from a frontier verifier. Prefer this route for stages whose acceptance is mechanical (smoke scripts, `bash -n`, fixture comparisons) and keep a frontier verifier for judgement-heavy criteria: a FAIL from a weaker verifier still blocks the merge, but a PASS is only as trustworthy as the acceptance commands it actually ran. `gpt-oss:120b` is the measured default (77% FAIL recall against a 10-stage benchmark, tied for best of eight candidates measured; see `docs/verifier-bake-off.md`); `qwen3-coder:30b` is faster but effectively a rubber stamp (15% FAIL recall) and should not be substituted for the default without accepting that trade. Cold model load is on the order of a minute; warm dispatches are faster.

### Cloud free tier (measured, not a selectable dispatch mode)

A second free route exists at two cloud providers, Groq and OpenRouter, each with a free API tier. It is not wired into `auth-route.sh` or `spawn-verifier.sh`: there is no `auth.<family>.mode: cloud-free` a stage card can select. It is exercised today only by the standalone bake-off harness, `scripts/verifier-bake-off.sh`, which measured it against the same benchmark set as the local candidates (results and methodology in `docs/verifier-bake-off.md`). Run one measured candidate by hand with:

```sh
scripts/verifier-bake-off.sh run \
  --candidate openrouter-nemotron-3-ultra-550b \
  --stage <stage-id>
```

The harness sources `op-refs.sh`, selects the one provider ref and invokes `op-fetch` itself. Do not wrap this command in a second `op-fetch` call.

Plant the two extra refs at the same live file as the paid keys, using the names `op-refs.sh` already declares:

```sh
# in ~/.config/autometta/op-refs.local.sh
export OP_REF_GROQ_API_KEY="op://<your-vault>/groq-api-key/credential"
export OP_REF_OPENROUTER_API_KEY="op://<your-vault>/openrouter-api-key/credential"
```

**Route isolation.** Each cloud candidate's caller (`scripts/verifier-bake-off-caller.py`) reads exactly one `--api-key-env` value; no code path reads `OPENAI_API_KEY`/`ANTHROPIC_API_KEY`. `scripts/verifier-bake-off.sh` resolves exactly one `NAME=ref` pair per candidate and hands it to `op-fetch`, whose `env -i` plus allowlist strips the paid refs from the child even when they are exported in the parent shell. Verified live: with `OPENAI_API_KEY` and `ANTHROPIC_API_KEY` exported in the parent shell, `op-fetch GROQ_API_KEY=$OP_REF_GROQ_API_KEY -- env` showed only `GROQ_API_KEY` in the child. `scripts/verifier-bake-off-route-smoke.sh` turns the same property into an offline, credential-free check (stubbed `op-fetch` capturing argv); run it after touching the harness rather than re-verifying by hand.

**Data-sharing constraint.** Every cloud call ships the stage card and the deliverable files it evaluates to a third party (Groq or OpenRouter). Nothing from `.autometta.local.yaml`, `op-refs.local.sh`, or the controller home directory is included, but the card and diff themselves leave the machine. A repo whose diffs must not reach a third party stays on the local candidates only.

**Measured recommendation.** Of the eight candidates measured (five local, Groq, two OpenRouter), `local-gpt-oss-120b` and `openrouter-nemotron-3-ultra-550b` tie at 77% FAIL recall, the only two that clear a defensible bar. `local-gpt-oss-120b` is the better default (same recall, better artefact discipline, $0 with no daily cap); the cloud candidate is a fallback for when the local machine is busy or a stage's evidence is too large for local wall-clock patience, and only for a repo already cloud-eligible. The one-time $10 OpenRouter unlock (50 to 1,000 requests/day) is not worth taking for this purpose: the free local candidate already matches its FAIL recall at $0. Groq's free tier cannot complete this comparison at all: its 8,000 tokens/minute cap is smaller than this verifier's prompt on most stages, a capacity fact rather than a quality one. Full table and per-candidate evidence: `docs/verifier-bake-off.md`.

A genuine third CLI family (Gemini CLI's free tier) was investigated and stays out of scope: it would need a new spawn branch, a new log format, and a new registry/heartbeat family value.

### Two committed files, one user-config file

```
op-refs.sh                                  # COMMITTED — placeholder refs, sources the override
templates/op-refs.local.sh.tpl                    # COMMITTED — template
~/.config/autometta/op-refs.local.sh        # GITIGNORED — your actual op:// references
```

`op-refs.sh` declares `OP_REF_OPENAI_API_KEY`, `OP_REF_ANTHROPIC_API_KEY`, `OP_REF_CLAUDE_CODE_OAUTH_TOKEN`, plus the two cloud free-tier refs `OP_REF_GROQ_API_KEY` and `OP_REF_OPENROUTER_API_KEY` (see "Cloud free tier" above), all with `op://YOUR_VAULT/...` placeholders, then searches for an override in this order: `$AUTOMETTA_LOCAL_REFS`, `~/.config/autometta/op-refs.local.sh` (XDG, recommended), then `<repo-root>/op-refs.local.sh` (dev checkout only). The XDG location is the one location both the brew-installed CLI and the dev checkout can both see.

### Per-repo mode toggle

`.autometta.local.yaml` (gitignored under `*.local`) carries only the mode:

```yaml
auth:
  codex:
    mode: api          # subscription | api | local
  claude:
    mode: subscription  # subscription | api (local is codex-family only)
```

Override at dispatch time without editing the manifest:

```sh
AUTOMETTA_CODEX_MODE=api  autometta tick
AUTOMETTA_CLAUDE_MODE=api autometta tick
```

### Verify before any dispatch

```sh
autometta auth status            # mode + ref provenance per family
autometta auth check codex       # also preflights Ollama when mode=local
autometta auth check claude
```

In API mode, `auth check` calls `op-fetch --print` against the configured ref. If the service-account token resolves it, the dispatch path will too; the resolved key is redacted and never written to disk. Subscription mode reports that no key fetch is needed. Codex local mode runs the same Ollama server and model preflight as the spawn scripts.

### How it dispatches

`scripts/spawn-worker.sh` and `scripts/spawn-verifier.sh` source `op-refs.sh`, ask `scripts/auth-route.sh <family>` for the NAME=ref pair (empty when subscription or codex local), then invoke `op-fetch <pairs> -- codex exec ...` / `op-fetch <pairs> -- claude -p ...`. In subscription mode no key is fetched but the child still gets the sanitised env. In api mode a single key is fetched and injected with nothing else from the parent shell. For codex, the spawn scripts additionally ask `scripts/auth-route.sh codex --print-mode` for the resolved mode word so they can pick the `--oss --local-provider=ollama -m <model>` argv when it resolves `local`.

For **codex in api mode**, the spawn script also exports `CODEX_HOME=$AUTOMETTA_CODEX_HOME` (default `~/.codex-api-only`) and passes it through op-fetch via `--pass CODEX_HOME`. Without that isolation, codex prefers `~/.codex/auth.json` (`auth_mode: "chatgpt"`) and silently bills the subscription regardless of the injected `OPENAI_API_KEY`. The spawn fails closed if the sibling CODEX_HOME is missing or has the wrong `auth_mode`.

Fails closed across the surface: missing `op-fetch`, an unset `OP_REF_*`, a placeholder ref, or a missing sibling CODEX_HOME all abort the spawn before any token is spent.

For manual orchestrator dispatches outside the loop, the pattern is:

```sh
source "$autometta_root/op-refs.sh"
auth_pairs="$(REPO_ROOT=$repo scripts/auth-route.sh codex)"

# For codex api mode: pass CODEX_HOME pointing at the sibling so codex reads
# its auth_mode: apikey instead of the chatgpt-mode default at ~/.codex.
CODEX_HOME="${AUTOMETTA_CODEX_HOME:-$HOME/.codex-api-only}" \
  op-fetch $auth_pairs --pass CODEX_HOME -- \
  codex exec -C "$repo" --sandbox workspace-write "$prompt" </dev/null >log 2>&1 &

# Claude has no equivalent: claude -p honours ANTHROPIC_API_KEY directly.
op-fetch $auth_pairs -- claude -p "$prompt" </dev/null >log 2>&1 &
```

## 8. Uninstall

Remove one subscriber:

```sh
autometta uninstall-launchagent <path-to-repo>
rm "${AUTOMETTA_HOME:-$HOME/.autometta}/subscribers/<repo-slug>.yaml"
```

Remove the whole host setup:

```sh
rm -rf "${AUTOMETTA_HOME:-$HOME/.autometta}"
```

Optional repo cleanup:

```sh
rm -rf state
```
