# Publish workflow

How Autometta keeps a clean public-facing history separate from the messy private working line. Read this before pushing anything to the public remote, and before changing the publish-guard configuration.

Placeholders used below: `PRIV` = the private remote (`origin`, pointing at `tw-one/autometta`), `PUB` = the public remote (`public`, pointing at `aw-pr/autometta-public`), `PUB_MATCH` = a substring of the public remote URL (`aw-pr/autometta-public`), `PUBLISH_BRANCH` = the local line that becomes public (`publish`).

## Model

- **`dev`** - the private working branch on `PRIV`. Atomic commits, per-agent author attribution, full feedback-banking memory chain. Never goes to the public remote. The pre-push hook enforces this.
- **`publish`** - the public-facing line. Created as an orphan-squash from `dev` at the first publish. Subsequent updates either fast-forward atomic merges from a clean topic branch, or land as a single squash commit per merge.
- **Ephemeral `wip/*` topic branches** for everything else. Merged into `publish` according to the history mode in use; topic branch deleted afterwards.

The public remote is `aw-pr/autometta-public` on GitHub. Branch protection keeps everything except `main` off the public side; `publish` is pushed as `publish:main` on the public remote.

## The one hard invariant

Whatever commit `PUB/main` points at is immutable. Rewrite or squash freely *above* it (commits not yet published); never *at or below* it. Rewriting a published commit forces a history-rewriting push to the public remote, which is the exact hazard the orphan-squash exists to avoid. Treat that as an incident, not routine. The pre-push hook rejects non-fast-forward pushes to the public default branch even when the sentinel is set.

## Why the orphan-squash for the first cut

The pre-arm history (commits before the publish-guard was installed) carried operator home-dir paths in stage-card blobs that were later cleaned in commit `2079b30`. The audit run before first publish confirmed:

- Zero secret material has ever entered git history.
- Privacy leakage was bounded to home-dir paths in old stage-card diffs.

Filter-repo-ing those leaks commit-by-commit would have touched every commit in the chain. An orphan-squash for the first public cut is the simpler equivalent: the cleaned tree lands as a single commit and the messy provenance stays private on `dev`. Subsequent merges from clean topic branches can fast-forward and preserve atomic commits plus per-agent attribution. The repo runs in `preserve` mode from the orphan onward.

## History mode (`publishguard.historymode`)

| Mode | Seed | Ongoing merges | When to pick |
|---|---|---|---|
| `preserve` *(this repo)* | Orphan-squash to one commit | Fast-forward (or `git merge --no-ff wip/x`); atomic commits and per-agent `--author=` attribution land on the public mirror | Atomic commits plus per-agent authors are the honest output of this repo's commit discipline. |
| `squash` *(opt-in per merge)* | n/a | `git merge --squash wip/x` collapses to one clean commit per merge | A genuinely hacky WIP topic branch not worth preserving. |

Mode is a per-merge choice, not a per-repo flag. `publishguard.historymode` only sets the default the alias and docs steer toward. Use `preserve` by default; use `squash` mid-stream when a topic branch is messy.

## Guard infrastructure

The guard ships at `scripts/git-hooks/` and `scripts/install-guards.sh`:

- `scripts/git-hooks/pre-commit` - refuses to stage files matching personal/secret patterns. Patterns live in the gitignored `.publish-guard.local`, not in the hook itself. Also rejects never-commit paths regardless of `.gitignore` state (`.env`, `*.local`, `op-refs.local.sh`, etc.).
- `scripts/git-hooks/pre-push` - on the public remote (matched by `publishguard.publicmatch`), only the default branch (`main` or `master`) may be pushed, and only when the `PUBLISH_GUARD_OK=1` sentinel is set, which only the `git publish` alias does. Direct hand-pushes to the public default branch are rejected and the message points at `git publish`. Non-fast-forward pushes to the public default branch are rejected even with the sentinel set.
- `scripts/install-guards.sh` - idempotent installer. Arms both hooks into `.git/hooks/`, seeds a toothless `.publish-guard.local` from the example, and reconciles the `git publish` alias from the `publishguard.*` git config keys. Safe to re-run on a fresh clone.
- `.publish-guard.local.example` - checked-in template with placeholders. Real values go into `.publish-guard.local` which is gitignored.

Override once for a deliberate exception: `git commit --no-verify` or `git push --no-verify`. Both are intentional escape hatches and should not appear in routine workflows.

## Config keys

Set once per machine via `git config --local`. Never committed (keeps org/repo names out of the tracked tree). For this repo:

```sh
git config publishguard.publicmatch   'aw-pr/autometta-public'
git config publishguard.publicremote  'public'
git config publishguard.privateremote 'origin'
git config publishguard.publishbranch 'publish'
git config publishguard.sentinel      'PUBLISH_GUARD_OK'
git config publishguard.historymode   'preserve'
```

`scripts/install-guards.sh` reads these and writes the `git publish` alias:

```
git push origin publish && PUBLISH_GUARD_OK=1 git push public publish:main
```

If `publicmatch` or `publicremote` are unset, the alias is left inert and the pre-push hook is a no-op on all remotes. That is the right state on a fresh clone before the operator has set the public-remote details.

## One-time setup on a fresh clone

1. `bash scripts/install-guards.sh` from inside the repo. Installs both hooks and seeds a toothless `.publish-guard.local` from the example. The publish gate stays INERT until the next step.
2. Set the six `publishguard.*` config keys above. Re-run `bash scripts/install-guards.sh` and it will write the `git publish` alias.
3. Edit `.publish-guard.local`: replace the example placeholders with your real home-dir patterns, username, email. Never commit this file.
4. Prove the guard fires:
   ```sh
   echo "/Users/<yourname>/secret" > /tmp/test-leak.md
   git add /tmp/test-leak.md
   git commit -m "test"   # should fail with pre-commit message
   ```
5. Add the remotes if not already set:
   ```sh
   git remote add origin <tw-one/autometta URL>
   git remote add public <aw-pr/autometta-public URL>
   ```

## Day-to-day

```bash
# Default (preserve mode): atomic commits land on publish as-is.
git switch -c wip/<thing>        # atomic commits, per-agent --author=
# ... work ...
git switch publish
git merge --ff-only wip/<thing>  # fast-forward when publish has not moved
# or: git merge --no-ff wip/<thing> -m "merge wip/<thing>: <topic>"
git publish                      # PRIV publish, then ff PUB main
git branch -d wip/<thing>        # -d (not -D); commits live on publish now
```

```bash
# Opt-in squash: when wip/<thing> has messy WIP commits not worth preserving.
git switch -c wip/<thing>        # branch from publish, not from dev
# ... work ...
git switch publish
git merge --squash wip/<thing>
git commit -m "One clean message"
git publish
git branch -D wip/<thing>        # -D; commits do not live on publish
```

`git publish` backs up to the private remote first, then publishes. Do not hand-type `git push public publish:main`; the gate blocks it. Route through `git publish`.

When branching a `wip/*` for publish-track work, branch it **from `publish`**, not from `dev`. `dev` carries private-tier paths (`HANDOFF.md`, runtime state, full memory chain) that should not reach the public mirror. See "Gotchas" below.

## The gate (why it cannot be bypassed by accident)

`pre-push` fails closed on the public remote:

- non-default branch to public is rejected;
- default branch to public is rejected unless `PUBLISH_GUARD_OK=1` is set, which only `git publish` does;
- non-fast-forward to public default is rejected even with the sentinel.

So a hand-typed `git push public publish:main` is blocked and told to use `git publish` (which guarantees the private backup happened first). Deliberate one-off override: `git push --no-verify`.

Why fail-closed, not a warning: publishing is effectively irreversible (objects stay fetchable by SHA, content gets cached and indexed). A guardrail for an irreversible outward action must stop it and point at the right command, not narrate the mistake as it completes.

## What never goes public

The pre-commit hook patterns are the floor. Additional things that must not appear on `publish`:

- `state/` runtime contents (gitignored, but the directory itself is part of the contract; keep marker files only).
- `HANDOFF.md`, `RUNBOOK.md`, anything `runs/`-style. Private-tier paths that live on `dev` only.
- `.publish-guard.local`, `.env*`, `op-refs.local.sh`, anything under `*.local`.
- Tony's working notes inside `<ALW>...</ALW>` tags. If you see one, resolve it before merging to `publish`.

## When to re-run the audit

- Before every push to public `main` if more than a week or ten-ish commits have landed on `dev`.
- After any change to `.gitignore` (the floor moves).
- After any change to `scripts/git-hooks/*` or `scripts/install-guards.sh` (the gate moves).
- After any operator change to the `.publish-guard.local` patterns (the rules move).

The audit itself is the `repo-publish-audit` skill in the shared mcp-hub. Output is a fix-in-place / history-rewrite / accept triage; act on the first two categories before pushing.

## Gotchas

- **`squash` mode plus branching `wip/*` from `dev`.** A `git merge --squash dev` into `publish` fails outright ("refusing to merge unrelated histories") because the orphan-squash means `publish` and `dev` share no ancestry. Even with `--allow-unrelated-histories` it would drag `dev`'s private-tier paths onto `publish`. For a small cross-tree change, file-level cherry-pick onto `publish` instead. For ongoing work that is born publish-safe, branch the `wip/*` topic **from `publish`**, then `git merge --squash wip/x` works as documented and the tree stays clean by construction.
- **`install-guards.sh` reseeds `.publish-guard.local`** from the placeholder example if absent, so pre-commit is toothless until real personal patterns are restored. Always re-check after running it on a fresh clone.
- **Default branch `master` vs `main`.** pre-push allows either; adjust the `git publish` alias target if the public default is `master`.
- **`git publish` private push needs `--force-with-lease`** if you rebased `publish` (private only; never force public). Edit the alias by hand for the one-off; do not bake `--force-with-lease` into the default alias.
