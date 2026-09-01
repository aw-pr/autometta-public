# Stage card 105: the cost smoke survives its own commit

## Metadata

- **Authored:** 2026-09-01
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Base branch:** dev
- **Run branch:** autometta/105-the-cost-smoke-survives-its-own-commit
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/tick-cost-smoke.sh
- **Pairing rationale:** cross-family, and deliberately the seat that wrote the
  test in stage 100. The defect is a blind spot in how the baseline was
  constructed rather than a coding error, so the author's own seat is the one
  that should see it named; the Claude verifier confirms the test now fails for
  the right reason and passes for the right reason.
- **Type:** Test-harness correction.

## Surfacing concern

`scripts/tick-cost-smoke.sh:27` builds its pre-change arm from git:

```sh
git -C "$repo_root" show HEAD:scripts/tick.sh > "$destination/scripts/tick.sh"
```

`HEAD` is whatever is committed. While stage 100's work sat uncommitted in the
run worktree, `HEAD` was the old tick and the comparison was real: the test
passed honestly, and the verifier scored it 6 of 6 in good faith. The moment
the tick committed the deliverable at `85765ff`, `HEAD` became the *changed*
tick, both arms of the comparison became the same file, and the test began to
fail permanently:

```
HEAD    FAIL: pre-change tick did not compute one build check per repo (got 1, expected 6)
HEAD~1  PASS: pre-change 9.33s (6 build checks), candidate 3.90s (1 build check), budget 6.0s
```

The measured improvement is real and is not in question. Only the harness is
wrong, and it is wrong in a way that no verification could have caught, because
the state it needs to pass -- subject uncommitted -- is exactly the state every
verifier sees and no committed tree ever will.

`HEAD~1` is not the fix. It is right only for the one commit that directly
follows the change, and stage 100 has already been merged with `--no-ff`, so
the parent it names is now the merge's first parent rather than the old tick.

## Inputs (read these in your own context)

- `scripts/tick-cost-smoke.sh` (the whole file; it is 121 lines)
- `scripts/tick.sh` and `scripts/heartbeat.sh`, only the build-check caching
  the smoke exercises: `refresh_heartbeat_build_check` and its call site
- `docs/tick-loop.md`, the cost model the smoke is asserting

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/tick-cost-smoke.sh` builds its pre-change arm from something that
   does not move when the repository moves. A fixture holding the pre-change
   behaviour, a pinned blob, or a stub that disables the cache are all
   acceptable; deriving it from a relative git ref is not, and neither is
   pinning an absolute sha that will silently rot when the file is next
   touched. Say in the handoff which you chose and why the choice survives a
   future edit to `tick.sh`.
2. The test passes on a clean committed tree -- the state it is actually run
   in -- and keeps its real assertion: the pre-change path performs one build
   check per repo and misses the budget, the changed path performs one in
   total and meets it.
3. The test still fails if the caching is genuinely removed from `tick.sh`.
   Demonstrate this, do not assert it.

## Constraints

- Do not change `scripts/tick.sh`, `scripts/heartbeat.sh` or the cost model.
  This card is about the harness only; the behaviour it measures is correct
  and already merged.
- The fixture stays offline and dispatch-free, as it is now.
- Runtime stays within the existing budget: the six-repo fixture at a one
  second stub is what makes the difference observable, not machine speed.

## Acceptance criteria

1. `bash -n scripts/tick-cost-smoke.sh` clean and the script executable.
2. On a clean committed `dev`, `scripts/tick-cost-smoke.sh` exits 0.
3. Its pass is not an artefact of an uncommitted tree: it also exits 0 from a
   fresh `git worktree` of the committed branch, with nothing modified.
4. With the build-check caching removed from a *copy* of `tick.sh`, the test
   exits non-zero, and the failure message names the cost regression rather
   than an internal error.
5. `scripts/gate-smoke.sh` and `scripts/installed-build-warning-smoke.sh`
   still pass.
6. No file outside the Path claims is modified.

## Contract test

- **Test file:** `scripts/tick-cost-smoke.sh`
- **Assertions digest:** frame the assertions in an
  `AUTOMETTA-CONTRACT-BEGIN`/`AUTOMETTA-CONTRACT-END` block naming this card,
  with a real sha256. Stage 102 failed its gate for lacking exactly this, and
  a prose digest is what let the gate pass without checking anything.

## Out of scope

- The cost model, the caching itself, `docs/tick-loop.md`.
- The installed-build drift between the Homebrew build and the checkout.
- Any other smoke's baseline construction; if you find the same pattern
  elsewhere, name it in the handoff and leave it.

## Budget

- **Worker wall-clock:** 60 minutes
- **Verifier wall-clock:** 30 minutes

## Escalation

If no baseline construction survives both a clean tree and a future edit to
`tick.sh`, that is a finding: write down what you tried and why each fails, and
stop. A test that measures nothing is worse than a deleted one, so deleting it
and saying so is an acceptable outcome if it comes with the reasoning.

## Verifier handoff

Run the test from a fresh worktree of the committed branch, not from a dirty
tree -- a dirty tree is what hid the defect the first time, and reproducing the
original mistake is the single most likely way to pass this card wrongly. Then
break the caching in a copy of `tick.sh` and confirm the test notices. Judge
criterion 3 by doing it, not by reading that it was done.
