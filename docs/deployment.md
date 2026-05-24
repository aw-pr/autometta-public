# Deployment model

Autometta should be easy to update across adopter repos without turning the
project into a packaged runtime. The default deployment model is:

1. Keep one canonical Autometta checkout on the machine.
2. Initialise `${PHAT_CONTROLLER_HOME:-$HOME/.phat-controller}` from that checkout.
3. Subscribe adopter repos to that host controller.
4. Keep repo-local stage cards and `state/`.
5. Resolve shared scripts, templates, and docs from the canonical checkout.

This replaces copy-first pass-2 adoption. Copying remains useful for one-off
pass-1 dispatches where the adopter wants to own the templates locally.

## Why not just copy or symlink?

Copying is simple, but every adopter freezes at the version it copied. Fixing a
headless gotcha then means finding and patching every copied script.

Symlinks keep one source of truth on one machine, but they break easily after a
clone, VM restore, or path change. They also hide the fact that an adopter
depends on a host-level install.

The central-install model makes the dependency explicit. The source checkout has
ordinary git history, so updates are auditable with `git log`. Adopter repos keep
only their local queue, state, and optional overrides.

## Default model: Homebrew-local CLI plus local manifest

Install the local CLI from the canonical checkout:

```sh
scripts/install-homebrew-local.sh
```

Then initialise an adopter repo:

```sh
autometta init /path/to/repo
```

The installed `autometta` command wraps the shell scripts from the packaged
checkout:

- `autometta init-host`
- `autometta init <repo>`
- `autometta add-stage <repo> <card>`
- `autometta status`
- `autometta attach`
- `autometta tick`

The installer renders a local Homebrew formula outside this repo. The committed
formula template contains placeholders only; machine paths are written into the
local tap and archive when the operator runs the installer.

The host controller config records the installed Autometta root. When run from a
checkout, this is the source checkout; when run through Homebrew-local, this is
the packaged install root:

```yaml
version: 1
autometta_root: /path/to/autometta
max_per_fire: 20
default_weight: 100
log_level: info
```

Each subscribed repo may also carry a gitignored local manifest:

```yaml
version: 1
autometta_root: /path/to/autometta
state_dir: state
stage_card_globs:
  - docs/stages/*.md
  - examples/self-host/*.md
templates_mode: upstream
```

The manifest is local-machine configuration. It can contain absolute paths and
therefore should not be committed. Portable repos that need committed provenance
should use a submodule instead.

## Portable alternative: pinned submodule

Use a Git submodule when an adopter repo must be cloneable and reproducible
without pre-existing machine setup:

```sh
git submodule add <autometta-remote> vendor/autometta
```

The repo then pins a specific Autometta commit. Updates are explicit:

```sh
git -C vendor/autometta fetch
git -C vendor/autometta checkout <new-commit>
git add vendor/autometta
git commit -m "Update Autometta contract"
```

This gives the strongest git audit trail inside the adopter repo, at the cost of
submodule ceremony.

## Escape hatches

- **Copy:** best for a single pass-1 dispatch or when the target repo wants to
  fork the templates.
- **Subtree:** acceptable when submodules are banned, but conflict handling is
  noisier.
- **npm package:** possible later, but not the current shape. Homebrew-local is
  a better first fit for shell scripts on macOS.

## Update rule

Update the canonical checkout first, rerun `scripts/install-homebrew-local.sh`,
then let subscribers consume the new scripts on the next tick. If a script
change is incompatible with older subscriber state, add an explicit compatibility
check before dispatching workers.

For an existing subscribed repo, the normal update is:

```sh
cd /path/to/autometta
git pull --ff-only
scripts/install-homebrew-local.sh
autometta status
```

`brew update` alone does not refresh Autometta in the current local formula
model, because the formula and archive are rendered from the checkout. Rerun the
installer after updating the checkout.
