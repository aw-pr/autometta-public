# Stage card 129: a bare gate invocation inspects nothing

## Metadata

- **Authored:** 2026-09-06
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Opus 5 <claude-opus-5@local>
- **Base branch:** dev
- **Run branch:** autometta/129-a-bare-gate-invocation-inspects-nothing
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/check-contract-test-gate.sh, tests/contract-gate-smoke.sh, stage-cards/129-a-bare-gate-invocation-inspects-nothing.md
- **Pairing rationale:** cross-family. The defect is a guard that passes when
  it should refuse, and the fix is a guard that must refuse without becoming
  a guard that refuses everything. A verifier from the other family exercises
  the refusal path against its own cases rather than the worker's.
- **Type:** Guard correctness. Vendored downstream, so the fix must survive
  re-vendoring.

## Surfacing concern

`cmd_gate` in `scripts/check-contract-test-gate.sh` reads the staged change
set and returns success when it is empty:

```sh
staged="$(git diff --cached --name-only --diff-filter=ACM)"
[ -n "$staged" ] || exit 0
```

Every dispatch evaluates a dirty, wholly unstaged working tree. The worker
writes files and does not stage them; the tick stages and commits afterwards.
So the bare invocation that stages are told to run exits 0 having inspected
nothing, and reports as a pass. Stage 79 of emergence-lab found this on
2026-09-06 when its verifier declined to accept the exit code as evidence.

The blast radius downstream: twenty-nine verifier artefacts in
emergence-lab's `state/verifiers/` cite this gate, back to its stage 67. Each
carries an acceptance criterion asserting the guard passed. None of them
checked anything. That repo's card 86 audits the damage; this card fixes the
cause.

The silence is the defect, not the empty-set shortcut itself. A gate that
finds nothing to check and a gate that checks and finds nothing are the same
exit code today, and an agent citing that exit code cannot tell which it got.

## Inputs (read these in your own context)

- `scripts/check-contract-test-gate.sh` — the whole script
- `templates/git-hooks/` — every hook that invokes the gate, and how
- Any smoke script under `tests/` that already exercises the gate

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. A gate that distinguishes "nothing staged" from "checked and clean". The
   empty-staged path must say so on stderr and must not be reportable as a
   pass. Choose the mechanism and defend it in the card's own prose: a
   distinct exit code, a required explicit `--staged`, or a working-tree mode.
   Whatever you choose, the pre-commit hook's behaviour on a normal commit is
   unchanged.
2. A mode that gates the working tree rather than the index, so a dispatch can
   invoke it meaningfully before anything is staged. Name it explicitly; do
   not make it the default.
3. A smoke script covering, at minimum: nothing staged; a staged file with a
   marker and a matching declared digest; a staged file whose block drifted
   from its card; a staged marked file whose card is absent from the commit; a
   card with no `Assertions digest` line; and a dirty unstaged tree with a
   drifted block, which must now be catchable.
4. A note in the card recording that emergence-lab vendors this script, so the
   fix has to be re-vendored there and that is a separate landing.

## Constraints

- The pre-commit hook must keep refusing a real freeze violation, and must
  keep letting an ordinary commit through. If your change makes every commit
  noisy, it will be reverted.
- No change to the marker tokens or the digest algorithm. Existing declared
  digests in downstream cards must stay valid.
- No change to any downstream repo from this card.
- The script stays POSIX `sh`-compatible if it is today; do not quietly make
  it bash-only.

## Acceptance criteria

1. The repo's own verify gate is green.
2. The smoke script passes and covers all six cases in deliverable 3, each as
   a separately named assertion.
3. A dirty unstaged tree with a drifted frozen block is now detected. Show the
   before and after: the old invocation exits 0, the new one does not.
4. An ordinary commit with nothing frozen in it still succeeds through the
   pre-commit hook, demonstrated end to end.
5. Existing digests declared in downstream cards still validate — recompute at
   least one and show it unchanged.
6. The vendoring note is present and names the downstream path.

## Contract test

- **Test file:** `tests/contract-gate-smoke.sh`
- **Assertions digest:** to be declared by this card on landing. The file is
  new, so compute the digest of its frozen block with
  `check-contract-test-gate.sh print` and write it into this card's Metadata
  in the same commit.

## Out of scope

- Re-vendoring into emergence-lab.
- Auditing which downstream stages were affected — that is emergence-lab's
  card 86.
- Adding freeze markers to any test file anywhere.

## Budget

- **Worker wall-clock:** 90 minutes
- **Verifier wall-clock:** 45 minutes

## Escalation

If you find that the pre-commit hook depends on the empty-staged exit-0 path
in a way that cannot be preserved alongside a loud empty-set signal, stop and
report the conflict rather than choosing one. That is a contract decision.

## Verifier handoff

Exercise the refusal path yourself, on your own drifted block. The specific
failure to look for is the fix that makes the gate loud in a way agents will
learn to ignore: check that a clean ordinary commit is silent.
