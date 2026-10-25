# Publish workflow

How autometta keeps a public mirror in step with private development. Read this before pushing to the public remote, or before changing the publish-guard configuration.

Placeholders: `PRIV` = the private remote (`origin`), `PUB` = the public remote (`public`), `PUB_MATCH` = a substring of the public remote URL (e.g. `myorg/myrepo`), `PUBLISH_BRANCH` = the line that becomes public (`publish`).

## Model

`dev` is the private working line. `publish` is the curated, append-only public
line. They share ancestry, but tracked private material is removed from every
new public commit by `scripts/publish-sync.sh`. A replay preserves the original
author and message and records its source commit in a `Publish-Sync-Source`
trailer. A fast-forward is used only when no private path needs removal.

Stage cards are intentionally public. They are part of the implementation and
review evidence, together with frozen assertions and role attribution. They
are not private-file exclusions. Machine configuration, session handoffs and
runtime records remain outside the public head.

The public default branch advances through a PR from `publish`. Published
commits are immutable; a later cleanup does not erase material from older
public history. Audit both the candidate trees and the incoming history before
pushing. Do not rewrite existing public history as part of a routine release.

## Normal publish

First commit the intended changes on the working line and run their relevant
checks. Use a clean review worktree if the working checkout contains unrelated
or active work. Never clean that work away just to prepare a release.

```sh
# In a clean working or review checkout, with the intended source on dev:
scripts/publish-sync.sh                         # read the dry-run plan
scripts/publish-sync.sh --apply --on-conflict abort
# Audit the resulting publish tree and incoming history before either push.
git push origin publish                        # private backup
git push public publish                        # guarded public PR source
gh pr create --repo "$(git config --get publishguard.publicmatch)" --base main --head publish
# Omit creation if an open public PR already exists.
```

The pre-push gate rejects direct pushes to public `main` and private paths on
the PR source. Review and merge the PR on the forge. An agent prepares the
reviewable PR; it does not replace the human merge decision with a sentinel or
attestation flag. Keep the public default branch protected on the forge as
well as locally. No force-push or guard bypass belongs in this workflow.

The replay helper may report a conflict or a tree mismatch. Stop and inspect
it; do not skip a public change merely to make the gate pass. Its final public
paths must match the intended source, with only the declared private paths
removed. See mcp-hub's `docs/PUBLISH-SYNC.md` for the helper's detailed contract.

## Tagging a release

Releases are **tags on the linear history plus GitHub release notes**, not squashed commits. Preserve the atomic, per-agent-authored commits: the cross-family commit trail is part of what this repo demonstrates, so there is no per-release squash.

```sh
git tag -a vX.Y.Z -m "vX.Y.Z - <summary>" <commit>   # annotate the published commit
git push origin vX.Y.Z                                # private backup
# The gate blocks tag pushes to PUB (only the PR-source branch may be pushed
# in pr mode, only main in direct mode), so make the public
# release via gh, which creates the tag server-side at main's tip:
gh release create vX.Y.Z --repo PUB_MATCH --target main \
  --title "vX.Y.Z - <summary>" --notes "<release notes>"
```

Versioning: semver. `v0.x.y` covered the pre-alpha passes; `v1.0.0` (2026-09-10) marks the contract, loop and operator surfaces as stable for single-operator use. A short CHANGELOG entry per release is optional but cheap.

## The gate (why it cannot be bypassed by accident)

The guard ships at `scripts/git-hooks/` and installs via `scripts/install-guards.sh`:

- `pre-commit` - refuses to stage files matching the personal or secret patterns in the gitignored `.publish-guard.local`, plus never-commit paths (`.env`, `*.local`, `op-refs.local.sh`, `.publish-guard.local`) regardless of `.gitignore` state.
- `pre-push` - on `PUB` (matched by `publishguard.publicmatch`), the boundary decides what may be pushed:
  - `publishguard.boundary=pr` (the default): the public default branch (`main`/`master`) is never pushed from here; it advances only by a merge on the forge. The PR-source branch (`publishguard.prsource`, default `publish`) may be pushed, private-file-scanned, so the PR can exist. There is no attestation variable; the old `PUBLISH_PR_REVIEWED=1` escape hatch is gone.
  - `publishguard.boundary=direct`: the default branch may be pushed, only when the sentinel (`PUBLISH_GUARD_OK=1`, which only `git publish` sets) is present, only as a **fast-forward**, and only when the tree carries no `publishguard.privatefile`.
  - In both modes any other ref (tags included) is rejected.
- `commit-msg` - appends the vendor avatar trailer for an agent author. `pre-merge-commit` - extends the `pre-commit` guard to merge commits, which git otherwise exempts from `pre-commit`.

Why fail-closed rather than a warning: publishing is effectively irreversible. Objects stay fetchable by SHA and content gets cached and indexed. A guard for an irreversible outward action has to stop it and point at the right command.

Do not bypass these hooks. A rejected candidate needs a fix and another guard run. Releases do not require a tag-push bypass: `gh release create` can create the reviewed tag server-side after the public PR is merged.

## Config keys

Set once per machine via `git config --local`; never committed, which keeps org and repo names out of the tracked tree. Current values for this repo:

```sh
git config publishguard.publicmatch   'PUB_MATCH'
git config publishguard.publicremote  'public'
git config publishguard.privateremote 'origin'
git config publishguard.publishbranch 'publish'
git config publishguard.sentinel      'PUBLISH_GUARD_OK'
```

Other guard keys:

| Key | Default | Meaning |
|---|---|---|
| `publishguard.boundary` | `pr` | `pr`: PUB/main advances only by a forge merge. `direct`: sentinel-gated ff push of `publish:main`. |
| `publishguard.prsource` | value of `publishbranch` | The one non-default branch allowed on PUB, as the PR source. |
| `publishguard.privatefile` | `HANDOFF.md` | Repeatable. A path that must not be in any tree pushed to PUB; the push is rejected if it is. |
| `publishguard.historymode` | `preserve` | `preserve` or `squash`; informational in the hook, surfaced in its error text. `install-guards.sh` seeds it. |

`scripts/install-guards.sh` reads these and writes the `git publish` alias (`push PRIV publish && PUBLISH_GUARD_OK=1 push PUB publish:main`). The alias only completes on a `direct` boundary; under `pr` its second push is the one the hook rejects, so use the "Normal publish" recipe instead. If `publicmatch` or `publicremote` are unset, the alias is left inert and the pre-push hook is a no-op on all remotes. That is the correct state on a fresh clone before the operator has set the public-remote details.

## What is private, and how

- **Ignored local files:** `.env*`, `*.local`, `op-refs.local.sh`,
  `.publish-guard.local`, `.publish-guard-strict.local`, `.autometta.local.yaml`,
  and runtime contents under `state/`. Tracked state README/marker files describe
  the contract; they are not live runtime snapshots.
- **Tracked private records:** `HANDOFF.md`, `RUNBOOK.md`, `runs/` and `archive/`
  remain portable on the private working line. Declare these file or directory
  paths with repeatable `publishguard.privatefile` settings. The replay helper
  strips them; the pre-push guard rejects their presence in the candidate tree.
- **Public review material:** `stage-cards/`, templates, smoke tests, design
  notes and shared `memory/` are part of the public project. Keep actual home
  paths, credentials and private service references out of them. Test fixtures
  and configuration examples must use placeholders.

A private-file configuration overrides the default list, so retain
`HANDOFF.md` when adding another path. Directory rules cover their descendants,
without matching similarly named public directories. The mcp-hub policy
registry is the source for this machine's local rules; sync it rather than
leaving a local setting that the next policy refresh will undo.

## Fresh-clone setup (one time)

1. `bash scripts/install-guards.sh` - installs every hook in `scripts/git-hooks/` and seeds a toothless `.publish-guard.local` from the example. The gate stays inert until step 2.
2. Set the `publishguard.*` keys above, then re-run `bash scripts/install-guards.sh` to write the `git publish` alias.
3. Edit `.publish-guard.local` with your real home-dir patterns, username, and email. Never commit it.
4. Add the remotes if they are missing:
   ```sh
   git remote add origin <PRIV URL>
   git remote add public <PUB URL>
   ```
5. Prove the guard fires:
   ```sh
   # In a disposable test clone, stage a harmless fixture matching a configured
   # private path or personal pattern, then invoke the installed guard.
   # It must reject the candidate; never plant a real credential.
   ```

## When to re-audit

Run the `repo-publish-audit` skill before publishing if more than ten-ish commits have landed on `dev` since the last publish, after any `.gitignore` change, after any change to `scripts/git-hooks/*`, or after editing `.publish-guard.local`. A fast-forward exposes the **history** of the commits it brings, not just the current tree, so the audit covers the range `PUB/main..dev`, not only the working tree.

## History note (the first publish, done once)

The public mirror was seeded once by an orphan-squash from older repositories whose early commit blobs carried operator home-dir paths. That one-time cleanup is finished. The pre-arm histories are archived in the tags `archive/dev-final`, `archive/main-legacy`, and `pre-rewrite-2026-05-27` (private only). Later private handoffs require curated replay above that shared seed. The current flow preserves published commits and strips private paths from new public commits. The orphan-squash is not part of routine publishing and should not be repeated.
