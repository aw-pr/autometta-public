# Publish workflow

How autometta keeps a public mirror in step with private development. Read this before pushing to the public remote, or before changing the publish-guard configuration.

Placeholders: `PRIV` = the private remote (`origin`), `PUB` = the public remote (`public`), `PUB_MATCH` = a substring of the public remote URL (e.g. `myorg/myrepo`), `PUBLISH_BRANCH` = the line that becomes public (`publish`).

## Model (read this first)

The history is **linear and shared**. There is one line of development:

- **`dev`** - the working branch on `PRIV`. Atomic commits, per-agent author attribution. This is the canonical line; all work lands here.
- **`publish`** - not a separate history. It is a pointer that sits behind `dev` on the same line and is **fast-forwarded** up to a chosen `dev` commit when you publish. `publish` is pushed to `PUB` as `main`.
- `PUB/main` is whatever `publish` last fast-forwarded to.

`dev` and `publish` share one root commit, and `git merge-base dev publish` is publish's own tip. There is no orphan, no unrelated history, nothing to rebase or cherry-pick. To publish you fast-forward `publish` up to `dev` and push. That is the whole model.

> This replaced an earlier orphan-squash model (see "History note" at the end). If any doc or memory still describes `publish` as an orphan you must cherry-pick onto, it is stale: verify with `git merge-base dev publish` and trust the topology, not the prose.

## Normal publish (the common case)

```sh
# 1. work on dev as usual - atomic commits, per-agent --author=
# 2. when a batch is ready for the public mirror:
git switch publish
git merge --ff-only dev          # publish catches up to dev's tip; always a clean ff
git push origin publish          # private backup first
git push public publish          # PR source, private-file-scanned by the gate
gh pr create --base main --head publish   # first batch only; later pushes update the open PR
git switch dev                   # back to the working branch
# 3. merge the PR on the forge (gh pr merge <n> --merge, or the web button)
```

The publish boundary is PR-by-default and the pre-push gate enforces it strictly: any push to `PUB/main` is rejected, with no attestation escape hatch. The old `PUBLISH_PR_REVIEWED=1 git publish` completion is retired; a flag set by the same automation it gates certifies nothing, so the merge happens on the forge where the diff is actually in front of you. The forge merge is a merge commit, so `PUB/main` carries publish's per-agent commits plus one merge bubble per batch; `publish` itself stays a strict ancestor and the next batch's push updates or reopens the PR (first exercised here as PR #3, merged 2026-08-31). A repo where the PR is genuinely surplus opts out with `git config publishguard.boundary direct`.

If `git merge --ff-only dev` refuses, `publish` has commits `dev` does not (someone committed directly on `publish`). That should not happen in this model; reconcile by hand rather than forcing.

## Tagging a release

Releases are **tags on the linear history plus GitHub release notes**, not squashed commits. Preserve the atomic, per-agent-authored commits: the cross-family commit trail is part of what this repo demonstrates, so there is no per-release squash.

```sh
git tag -a vX.Y.Z -m "vX.Y.Z - <summary>" <commit>   # annotate the published commit
git push origin vX.Y.Z                                # private backup
# The gate blocks tag pushes to PUB (only main is allowed), so make the public
# release via gh, which creates the tag server-side at main's tip:
gh release create vX.Y.Z --repo PUB_MATCH --target main \
  --title "vX.Y.Z - <summary>" --notes "<release notes>"
```

Versioning: pre-1.0 while pre-alpha (`v0.x.y`). The first tagged release is `v0.1.0`. A short CHANGELOG entry per release is optional but cheap.

## The gate (why it cannot be bypassed by accident)

The guard ships at `scripts/git-hooks/` and installs via `scripts/install-guards.sh`:

- `pre-commit` - refuses to stage files matching the personal or secret patterns in the gitignored `.publish-guard.local`, plus never-commit paths (`.env`, `*.local`, `op-refs.local.sh`, `.publish-guard.local`) regardless of `.gitignore` state.
- `pre-push` - on `PUB` (matched by `publishguard.publicmatch`): only the default branch (`main`/`master`) may be pushed, only when `PUBLISH_GUARD_OK=1` is set (which only `git publish` does), only with the `PUBLISH_PR_REVIEWED=1` attestation (unless `publishguard.boundary` is `direct`), and only as a **fast-forward**. The configured PR-source branch (`publishguard.prsource`, default `publish`) may also be pushed, private-file-scanned, so the PR can exist. Other non-default refs (tags included) and non-fast-forward pushes are rejected.

Why fail-closed rather than a warning: publishing is effectively irreversible. Objects stay fetchable by SHA and content gets cached and indexed. A guard for an irreversible outward action has to stop it and point at the right command.

Deliberate one-off override: `git commit --no-verify` or `git push --no-verify`. These are intentional escape hatches and should not appear in routine workflows. Releases do not need one, because `gh release create` makes the tag server-side instead of pushing it.

## Config keys

Set once per machine via `git config --local`; never committed, which keeps org and repo names out of the tracked tree. Current values for this repo:

```sh
git config publishguard.publicmatch   'PUB_MATCH'
git config publishguard.publicremote  'public'
git config publishguard.privateremote 'origin'
git config publishguard.publishbranch 'publish'
git config publishguard.sentinel      'PUBLISH_GUARD_OK'
```

`scripts/install-guards.sh` reads these and writes the `git publish` alias. If `publicmatch` or `publicremote` are unset, the alias is left inert and the pre-push hook is a no-op on all remotes. That is the correct state on a fresh clone before the operator has set the public-remote details.

## What is private, and how

In a linear model there is **no private-tier branch**. Whatever is tracked and committed on `dev` reaches `PUB` on the next fast-forward. Privacy is enforced by `.gitignore` and the pre-commit guard, not by branch separation:

- **Gitignored, never public:** `.env*`, `*.local`, `op-refs.local.sh`, `.publish-guard.local`, `.autometta.local.yaml`, `state/**` (runtime; only the `state/handoffs/` markers are tracked), and `HANDOFF.md` (the dated session log stays private).
- **Tracked, intentionally public:** `memory/` is the in-repo shared agent memory and is part of the public mirror by design. Keep secrets and absolute home-dir paths out of it; the pre-commit guard patterns are the floor.

If a file must never be public, it has to be gitignored. Keeping it only on `dev` is no longer protection.

## Fresh-clone setup (one time)

1. `bash scripts/install-guards.sh` - installs both hooks and seeds a toothless `.publish-guard.local` from the example. The gate stays inert until step 2.
2. Set the `publishguard.*` keys above, then re-run `bash scripts/install-guards.sh` to write the `git publish` alias.
3. Edit `.publish-guard.local` with your real home-dir patterns, username, and email. Never commit it.
4. Add the remotes if they are missing:
   ```sh
   git remote add origin <PRIV URL>
   git remote add public <PUB URL>
   ```
5. Prove the guard fires:
   ```sh
   printf '/Users/<you>/secret\n' > /tmp/leak.md && git add /tmp/leak.md && git commit -m test   # must fail
   ```

## When to re-audit

Run the `repo-publish-audit` skill before publishing if more than ten-ish commits have landed on `dev` since the last publish, after any `.gitignore` change, after any change to `scripts/git-hooks/*`, or after editing `.publish-guard.local`. A fast-forward exposes the **history** of the commits it brings, not just the current tree, so the audit covers the range `PUB/main..dev`, not only the working tree.

## History note (the first publish, done once)

The public mirror was seeded once by an orphan-squash from older repositories whose early commit blobs carried operator home-dir paths. That one-time cleanup is finished. The pre-arm histories are archived in the tags `archive/dev-final`, `archive/main-legacy`, and `pre-rewrite-2026-05-27` (private only). From that seed onward, `dev` and `publish` are one linear history and the normal flow above is all you need. The orphan-squash is not part of routine publishing and should not be repeated.
