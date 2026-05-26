# Publish workflow

How Autometta keeps a clean public-facing history separate from the messy private working line. Read this before pushing anything to the public remote, and before changing the publish-guard configuration.

## Model

Autometta uses a one-remote, two-branch model:

- **`dev`** - the private working branch. Atomic commits, per-agent author attribution, full feedback-banking memory chain. Never goes to the public remote. The pre-push hook enforces this.
- **`publish`** - the public-facing line. Created as an orphan-squash from `dev` at the first publish. Subsequent updates either fast-forward atomic merges from a clean topic branch, or land as a single squash commit per merge.

The public remote is `aw-pr/autometta-public` on GitHub. Branch protection keeps everything except `main` off the public side; `publish` is pushed as `publish:main` on the public remote.

## Why squash for the first cut

The pre-arm history (commits before the publish-guard was installed) carries operator home-dir paths in stage-card blobs that were later cleaned in commit `2079b30`. The audit run before first publish confirmed:

- Zero secret material has ever entered git history.
- Privacy leakage is bounded to home-dir paths in old stage-card diffs.

Filter-repo-ing those leaks commit-by-commit would touch every commit in the chain. An orphan-squash for the first public cut is the simpler equivalent: the cleaned tree lands as a single commit and the messy provenance stays private. Subsequent merges from clean topic branches can fast-forward and preserve atomic commits plus per-agent attribution.

## Guard infrastructure

The guard ships at `scripts/publish-guard/`:

- `pre-commit` - refuses to stage files matching personal/secret patterns. Patterns live in the gitignored `.publish-guard.local`, not in the hook itself.
- `pre-push` - on the public remote (matched by `GUARD_PUBLIC_URL_MATCH`), only the public branch (`GUARD_PUBLIC_BRANCH`, default `main`) may be pushed. Private remotes are unrestricted.
- `install-guards.sh` - armed both hooks into `.git/hooks/`. Safe to re-run on a fresh clone.
- `publish-guard.local.example` - checked-in template. Real values go into `.publish-guard.local` which is gitignored.

Override once for a deliberate exception: `git commit --no-verify` or `git push --no-verify`. Both are intentional escape hatches and should not appear in routine workflows.

## One-time setup

Already done in this repo. Documented here for adopters cloning the mechanism into another project.

1. `bash scripts/publish-guard/install-guards.sh` from inside the target repo. Installs both hooks and seeds a toothless `.publish-guard.local` from the example.
2. Edit `.publish-guard.local`: replace placeholders with real home-dir patterns, username, email, and the public repo URL fragment. Never commit this file.
3. Prove the guard fires:
   ```sh
   echo "/Users/<yourname>/secret" > /tmp/test-leak.md
   git add /tmp/test-leak.md
   git commit -m "test"   # should fail with publish-guard message
   ```
4. Create the `dev` branch (if not already) for private work.

## First public push

Done once, the first time Autometta goes public.

1. Confirm the working tree on `dev` is clean and the publish-readiness audit has run. Both reviewer reports must show no must-fix items outstanding.
2. Confirm `.publish-guard.local` `GUARD_PUBLIC_URL_MATCH` matches the canonical public remote (`aw-pr/autometta-public`) and that `git remote -v` points at the same.
3. From `dev`, create the publish orphan:
   ```sh
   git checkout --orphan publish
   git add -A
   git commit --author="..." -m "initial public publish of Autometta"
   ```
4. Push: `git push origin publish:main`. The pre-push hook checks the remote ref (`refs/heads/main`) against `GUARD_PUBLIC_BRANCH` and the remote URL against `GUARD_PUBLIC_URL_MATCH`. If either does not match expectation, the push is rejected.
5. Switch back: `git checkout dev`.

## Ongoing publishing

Two modes per merge.

**Fast-forward (preserve atomic commits and per-agent attribution)**

For a topic branch with clean atomic commits - for example, a single-stage `card-NN-*` branch built via the dispatch contract:

```sh
git checkout publish
git merge --ff-only card-NN-something
git push origin publish:main
git checkout dev
```

The per-agent author lines and commit messages land on the public mirror. The dispatch-contract narrative shows in public `git log --format='%an | %s'`.

**Squash (one commit per landed feature)**

For a messy topic branch or a multi-card sweep where the internal history is exploratory rather than audit-worthy:

```sh
git checkout publish
git merge --squash some-wip-branch
git commit -m "feature: <summary>"
git push origin publish:main
git checkout dev
```

## What never goes public

The pre-commit hook patterns are the floor. Additional things that must not appear in the publish tree:

- `state/` runtime contents (gitignored, but the directory itself is part of the contract - keep `.gitkeep`-style or empty marker files only).
- `.publish-guard.local`, `.env*`, `op-refs.local.sh`, anything under `*.local`.
- Tony's working notes inside `<ALW>...</ALW>` tags. If you see one, resolve it before merging to `publish`.

## When to re-run the audit

- Before every push to public `main` if more than a week or ~ten commits have landed on `dev`.
- After any change to `.gitignore` (the floor moves).
- After any change to `scripts/publish-guard/*` (the gate moves).
- After any operator change to the `.publish-guard.local` patterns (the rules move).

The audit itself is the `repo-publish-audit` skill in the shared mcp-hub. Output is a fix-in-place / history-rewrite / accept triage; act on the first two categories before pushing.
