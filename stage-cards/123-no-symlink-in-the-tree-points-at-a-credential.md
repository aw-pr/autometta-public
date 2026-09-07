# Stage card 123: no symlink in the tree points at a credential

## Metadata

- **Authored:** 2026-09-06
- **Orchestrator:** Claude Fable 5.1 <claude-fable-5-1@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Base branch:** dev
- **Run branch:** autometta/123-no-symlink-in-the-tree-points-at-a-credential
- **Worker effort:** low
- **Verifier effort:** medium
- **Verifier panel:** false
- **Path claims:** scripts/check-deps.sh, scripts/credential-symlink-smoke.sh, docs/machine-dependencies.md, stage-cards/123-no-symlink-in-the-tree-points-at-a-credential.md
- **Pairing rationale:** cross-family. A guard against reading secrets; the Claude seat verifies
  by planting a symlink and confirming the guard names it without
  printing what it points at.
- **Type:** Hygiene guard. Pipeline-eligible.

## Surfacing concern

Until 2026-09-06 the checkout held an untracked, gitignored
`symlinked-config/` directory of symlinks to the operator's Codex auth
files, the 1Password reference script and the LaunchAgent plist. It was
never committed, and a run worktree never contained it, but any agent
reading the shared checkout could follow the links; on 2026-09-06 an
analysis agent listing the tree read live credentials into its context.
The directory has been moved to `~/.config/autometta/symlinked-config`.
Nothing prevents it, or something like it, from coming back.

## Objective

`autometta check-deps` (or the doctor pass it feeds) refuses when any
symlink under the checkout, tracked or not, resolves to a path under
`~/.codex`, `~/.codex-api-only`, `~/.config/autometta`, `~/.config/op`, or
to a file named `auth.json`, `.credentials.json` or `op-refs*.sh`, and it
never prints the target's contents.

## Inputs (read these in your own context)

- `scripts/check-deps.sh`, its check structure and how a failure is reported
- `.gitignore:6`
- `docs/machine-dependencies.md`

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. A check in `scripts/check-deps.sh` (or a sibling it calls) that walks
   the checkout with `find -type l`, excluding `.git`, resolves each link and
   fails naming the link path and the *category* of the target (never the
   target contents), for the patterns above. The pattern list is one array
   at the top of the check.
2. `scripts/credential-symlink-smoke.sh`: a fixture tree with a symlink to a
   temporary `auth.json` fails the check naming the link; a symlink to an
   ordinary file passes; the check's output does not contain the fixture
   file's contents. Frozen block around those assertions.
3. `docs/machine-dependencies.md`: the rule and the relocated directory's
   new home, so the next person does not recreate it in the tree.

## Constraints

- Never `cat` or read a candidate target; `readlink -f` only.
- The check must run in under a second on this checkout.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. `autometta check-deps` passes on the operator's checkout as it is today.
2. Planting `ln -s ~/.codex/auth.json <checkout>/x` makes it fail naming `x`
   and the category, and the output contains no token-like string; remove
   the link afterwards.
3. `scripts/credential-symlink-smoke.sh` passes and its failing case fails
   against the pre-change check.

## Contract test

- **Test file:** scripts/credential-symlink-smoke.sh
- **Assertions digest:** `sha256:81cf66a76a403683ee0ff025fc66797ce350d0e8a5ec7f6390cb09f14eeaaa48`

## Out of scope

- Scanning file contents for secrets; `repo-publish-audit` does that.

## Budget

- **Worker wall-clock:** 30 minutes
- **Verifier wall-clock:** 20 minutes

## Escalation

If `check-deps.sh`'s structure cannot take a check that walks the tree
without restructuring, put it in `scripts/doctor-symlinks.sh` and call it
from `check-deps`; say so.

## Verifier handoff

Plant the link yourself, run the check, read its output for anything that
looks like a token, then remove the link. The wrong pass is a check that
reads the target to classify it.

## Family-specific notes

None

## Seat history (2026-09-06)

The Codex subscription closed at 10:31Z and this batch was re-seated onto
Claude alone; when Claude session windows then drained faster than the batch
was sized for, the verifying seat moved to the free local route
(`gpt-oss:120b` via `codex exec --oss`). The Codex window reopened the same
afternoon and the card is back on the seats it was authored with. Nothing
about the work changed across either move.

## Digest line repaired by the orchestrator (2026-09-07)

The worker recorded the correct digest but appended it inside the template's
instruction sentence rather than replacing the line, so
`declared_digest()` found no `Assertions digest` value and the gate failed
the stage with "card has no 'Assertions digest' line". The hex it computed
was right and is unchanged above; only the line's shape is repaired, and no
assertion, deliverable or criterion has been touched.

This is the fifth stage in this batch hit by the same template defect, after
113, 115, 116 and 118. Card 131 landed the fix while this stage was already
in flight, so the card it was dispatched with still carried the old wording.

Note also that `scripts/check-contract-test-gate.sh` run bare in this
worktree exits 0 while the same tree with its files staged exits 1: the
gate short-circuits on an empty index, which stage 120's verifier also
flagged. A bare invocation proves nothing.

