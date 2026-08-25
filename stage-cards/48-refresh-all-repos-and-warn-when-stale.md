# Stage card 48: push autometta to its subscribers, and say when one is behind

## Metadata

- **Authored:** 2026-08-24
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Claude Opus 5 <claude-opus-5@local>
- **Verifier:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Base branch:** dev
- **Run branch:** autometta/48-refresh-all-repos-and-warn-when-stale
- **Worker effort:** high
- **Verifier effort:** medium
- **Verifier panel:** false
- **Pairing rationale:** this writes into other repositories, which is the most
  destructive thing autometta does. Cross-family verification, and the
  acceptance criteria are weighted toward what it refuses to overwrite.

## Objective

Work happens in autometta; subscribers hold a vendored copy of the contract
(templates plus a couple of scripts) recorded in a `.autometta-vendor` stamp
naming the sha it came from. There is no way to push an update, and nothing
tells you when a subscriber is behind.

The pieces exist and do not connect. `scripts/subscribe-repo.sh` registers a
repo in `~/.phat-controller/subscribers/` but vendors nothing. Vendoring is a
manual step driven by the setup skill. `autometta-vendor-check.sh` detects
drift, but only once vendored into a repo and only when a human runs it.
emergence-lab's stamp read `vendored_from: 496c7cc` while autometta HEAD was
`baf6fcb` — it happened to still match, and nothing would have said otherwise.

Give the operator one command to push a release to every subscriber, and make a
stale subscriber announce itself instead of waiting to be asked.

## Inputs (read these in your own context)

- `scripts/subscribe-repo.sh`
- `scripts/autometta-vendor-check.sh`
- `scripts/install-homebrew-local.sh`
- `scripts/tick.sh` (where a per-repo warning can be emitted once per pass)
- `~/.phat-controller/subscribers/*.yaml` and `template.yaml` (read only)
- An existing subscriber's `.autometta-vendor` (e.g. emergence-lab's) for the
  stamp format
- `skills/autometta-setup/SKILL.md`

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. A single definition of the vendored file set, read by both the vendor step
   and the check, so the two cannot disagree about what is vendored.
2. `autometta refresh-repo <repo-path>` — re-vendors the set into one
   subscriber and updates its `.autometta-vendor` stamp.
3. `autometta refresh-all-repos` — the same across every enabled subscriber in
   the registry, with a `--dry-run` that reports what would change and writes
   nothing. Disabled subscribers and `.disabled` entries are skipped and named.
4. A per-repo staleness warning in the tick: when a subscriber's stamp lags the
   resolved autometta sha, log it once per pass, naming both shas. A warning
   only; it must never block a dispatch.
5. `skills/autometta-setup/SKILL.md` documents the push model and that a
   subscriber is refreshed rather than hand-edited.
6. `docs/dispatch-contract.md` documents the commands and the stamp.

## Constraints

- **Never overwrite a filled template.** `autometta-vendor-check.sh` already
  distinguishes FILLED (a subscriber legitimately completed a
  `<<placeholder>>`) from DRIFT. A refresh must preserve a filled file and
  report it, never clobber it. This is the single most important constraint on
  the card.
- Refuse to write into a repo with a dirty working tree for any vendored path,
  and say which path. A push must not be mixed into someone's uncommitted work.
- Do not commit or push in the subscriber. Leave changes staged or unstaged for
  the operator; autometta is not authorised to make commits in another repo
  from this path.
- Skip a subscriber whose `repo_path` is missing from disk, and report it. The
  registry holds `.disabled` entries and paths for repos that have been
  removed.
- Never refresh a repo while a stage is dispatched in it. Check first and skip
  with a reason.
- Relative paths inside committed code; no home-dir absolutes.
- The staleness warning must not fire per stage or per subscriber per second;
  once per repo per tick pass.

## Acceptance criteria

1. `refresh-repo` updates a subscriber's vendored files and stamp, shown by a
   before-and-after `autometta-vendor-check.sh` run in that repo.
2. A file the subscriber has legitimately filled survives a refresh unchanged
   and is reported as filled, not overwritten. Demonstrate with a real filled
   placeholder.
3. `refresh-all-repos --dry-run` writes nothing, proven by unchanged mtimes and
   an unchanged `git status` in a target repo.
4. `refresh-all-repos` covers every enabled subscriber and names each skipped
   one with its reason.
5. A dirty vendored path in a subscriber causes a refusal naming that path.
6. A subscriber whose stamp lags produces exactly one tick warning per pass,
   naming both shas, and its stage still dispatches.
7. A subscriber with a current stamp produces no warning.
8. A repo with a stage in flight is skipped with a reason.
9. `bash -n` passes on every shell file touched; the vendored set is defined in
   one place; no file outside the deliverables is modified except this card.

## Contract test

- **Test file:** None
- **Assertions digest:** None

## Out of scope

- Homebrew bundle building and install, which is card 42. This card consumes a
  resolved autometta root; it does not decide which one.
- Committing or pushing in subscriber repos.
- Adding or removing subscribers, which `subscribe-repo.sh` already does.
- Any change to what the vendored set contains. Move the list, do not revise it.

## Budget

- **Worker wall-clock:** 90 minutes
- **Verifier wall-clock:** 45 minutes

## Verifier handoff

Return the before-and-after vendor-check output for a refreshed repo, the
filled-file evidence for criterion 2, the dry-run proof, the skip list with
reasons, the dirty-tree refusal, and both warning cases. Use a scratch clone or
a disposable subscriber for anything destructive, and state which repos were
written to.

## Family-specific notes

None
