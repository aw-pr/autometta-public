# Stage card 134: the gate describes the tree it is shown

## Metadata

- **Authored:** 2026-09-07
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Codex GPT-5.6 Sol <codex-gpt-5-6-sol@local>
- **Verifier:** Claude Opus 5 <claude-opus-5@local>
- **Base branch:** dev
- **Run branch:** autometta/134-the-gate-describes-the-tree-it-is-shown
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/check-contract-test-gate.sh, scripts/gate-consistency-smoke.sh, stage-cards/134-the-gate-describes-the-tree-it-is-shown.md
- **Pairing rationale:** cross-family, on the component every verdict in this
  repo leans on. The fix is two lines of git semantics (what `--worktree`
  diffs against, and what a missing card is called), and the failure to guard
  against is a fix that widens one mode until it swallows the other or turns
  an empty tree into a pass. A Codex worker writes it; a Claude verifier with
  no stake in the worker's reading of `git diff` exercises every mode against
  its own trees. Opus 5 found two of the three gate defects in this batch
  (stages 113 and 129) and verified 129's `--worktree` mode, which is the
  mode this card corrects, so it arrives knowing what it passed and why.
- **Type:** Gate correction. Touches no dispatch path, so it pairs.

## Surfacing concern

`scripts/check-contract-test-gate.sh` has been found wrong about its own
inputs three times in the 108-133 batch, each time by a verifier checking an
unrelated stage. Cards 121 and 129 closed the first two. This card closes the
third and a fourth that the reproduction surfaced beside it.

**The two modes disagree about one tree.** `--worktree` selects its change
set with `git diff --name-only`, which compares the index with the tree. A
change that has already been staged is absent from that diff, so on a tree
where the frozen block has drifted and the drift is staged:

```
$ scripts/check-contract-test-gate.sh --staged
contract-gate: scripts/fixture-smoke.sh: frozen assertions changed but their card ... (exit 1)
$ scripts/check-contract-test-gate.sh --worktree
contract-gate: no relevant changed files to inspect in the working tree (exit 2)
```

The same holds for a clean landing: a matching test and card, both staged,
pass `--staged` and are "nothing to inspect" to `--worktree`. The mode that
card 129 added so a dirty tree could be inspected before anything is staged
goes blind the moment something is. An operator who runs both and gets two
answers cannot know which to believe, and a worker or orchestrator who has
`git add`-ed their work gets told the tree is unchanged.

**A missing card is reported as a mute one.** Stage 133's verifier ran the
gate in a run worktree that had been cut before the card commit landed on
`dev`, so `stage-cards/133-*.md` was not in that tree. The gate said:

```
cat: stage-cards/133-the-dashboard-states-its-times-in-one-zone.md: No such file or directory
contract-gate: scripts/dashboard-clock-smoke.sh: card stage-cards/133-... has no 'Assertions digest' line
```

The card has a digest line; it has had one since it was queued. The gate
reads the card through `cat`, `cat` fails, `|| true` swallows the failure,
and the empty result is reported as a card without a digest. Both modes say
this; `print` never reads the card at all, which is why it agreed with
neither. The verifier worked out the real cause by hand and recorded it in
`state/verifiers/133-*.json`. A message that sends the next reader to edit a
card's digest line when the card is not there is worse than no message.

Both were reproduced against pristine `dev` in a scratch clone on
2026-09-07, and `scripts/gate-consistency-smoke.sh` reproduces them in
throwaway repositories on every run.

## Objective

The gate gives one answer about one tree: `--worktree` inspects every
candidate that differs from `HEAD`, staged or not, and a card that is not in
the tree is reported as absent, not as digestless.

## Inputs (read these in your own context)

- `scripts/check-contract-test-gate.sh`, the whole script, in particular
  `cmd_gate` and the `declared` read below it
- `scripts/gate-consistency-smoke.sh`, the frozen assertions for this card
- `tests/contract-gate-smoke.sh` and section 4 of `scripts/gate-smoke.sh`,
  the assertions cards 129 and 121 left, which must stay green

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. `--worktree` builds its change set from everything that differs from
   `HEAD` (`git diff HEAD --name-only --diff-filter=ACM` or equivalent) plus
   the untracked candidates card 129 added, so a staged change is inspected
   exactly as an unstaged one is. The candidate rule from card 121 (card-named
   paths and `scripts/*-smoke.sh`) and the content it reads (the working
   tree) are unchanged.

2. A card the test names that the mode's content reader cannot read is
   reported on stderr as `card <path> does not exist`, counted as a violation,
   and produces no raw `cat:` line. Same wording in both modes. Everything
   else about the digest comparison is unchanged: a card that exists but has
   no digest line still gets the message it gets today.

3. The usage comment at the top of the script says what each mode compares
   against, in one line each, so the next reader does not have to rediscover
   it from the git invocation.

## Constraints

- No change to the marker tokens, the digest algorithm, or `print`. Every
  digest recorded in `stage-cards/` must still validate.
- `--staged` keeps judging the index. Fixture (c) in the smoke pins the one
  divergence the two modes are allowed: a drift staged with its card
  re-recorded only in the tree fails `--staged` and passes `--worktree`.
  A fix that collapses the modes into one fails that fixture.
- Card 129's exit `2` on an untouched tree stays, in both modes. Widening the
  change set must not turn "nothing changed" into a pass.
- Do not touch `docs/dispatch-contract.md`. Its description of the gate is
  still true after this change, and three unqueued cards already claim it.
- Do not make the pre-commit path noisy. An ordinary commit with nothing
  frozen in it stays silent, as `tests/contract-gate-smoke.sh` checks.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. A staged drift is rejected by both modes, and the `--worktree` message
   names the drift.
2. A matching test and card, both staged, pass both modes.
3. A drift staged with its card re-recorded only in the tree still fails
   `--staged` with "not in this commit" and passes `--worktree`.
4. A test naming a card that is not in the tree fails both modes with
   `card <path> does not exist`, and no `cat:` line reaches stderr.
5. An untouched tree exits `2` in both modes.
6. `scripts/gate-consistency-smoke.sh` passes, and fails against the
   pre-change `scripts/check-contract-test-gate.sh`.
7. `tests/contract-gate-smoke.sh` and `scripts/gate-smoke.sh` are no more red
   than on clean `dev`.
8. `scripts/check-contract-test-gate.sh print scripts/dashboard-clock-smoke.sh`
   still prints the digest card 133 records.

## Contract test

- **Test file:** scripts/gate-consistency-smoke.sh
- **Assertions digest:** `sha256:63b868d625c7dde4af8f0b37b3559fa8bedb011f37cba5b3212f6f2204241227`

The file and its frozen block are **already written**, by the orchestrator,
before any implementation exists. Do not author, extend or edit the block:
satisfy it by changing the implementation. It fails today at nine of its
eighteen assertions, four for the staged-change blindness and five for the
missing-card message, and every control assertion passes. Fixtures and
scaffolding may be added outside the markers. If you become convinced an
assertion is wrong, stop and surface it as a blocker; the verifier recomputes
this digest and fails the stage if the assertions moved.

## Out of scope

- The dispatch ordering that cut stage 133's run worktree before its card
  commit reached `dev`. That is `scripts/tick.sh` and `scripts/add-stage.sh`
  territory, and a separate card if it recurs.
- `templates/verifier-prompt.md` step 6, which tells the verifier to run the
  gate "against the working tree" without naming `--worktree`. One word, and
  its own card.
- Re-vendoring the gate to subscribers. `scripts/vendor-set.sh` lists it and
  emergence-lab carries a copy; that landing is separate, as card 129 said.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes

## Escalation

If diffing against `HEAD` cannot work in a repository with no commit yet
(`git diff HEAD` has nothing to diff against on an unborn branch), stop and
report rather than special-casing it silently; the empty-tree object is one
answer and refusing with a clear message is another, and which one is a
contract decision. Every fixture in the smoke has a seed commit, so this will
not block the assertions, but a subscriber's first commit could meet it.

## Verifier handoff

Rebuild the stage 133 shape by hand before you trust the smoke: cut a
worktree at a commit that predates a card, copy that card's smoke in, run
both modes, and read the message. The whole deliverable is that the message
now tells you what you would otherwise have had to work out, as 133's
verifier did.

Then stage something and run `--worktree`. The failure mode this card is
most likely to ship is a change set widened by union with `--cached` rather
than by diffing against `HEAD`, which passes fixtures (a) and (b) and
quietly double-lists paths; check the invocation, not only the exit codes.

Finally, run an ordinary commit through a pre-commit hook that chains the
gate, as `tests/contract-gate-smoke.sh` does, and confirm it is still silent.
A gate that got louder on every commit would be disarmed by habit within a
week, and that is a regression this card must not trade for the fix.

## Family-specific notes

None

## Authorship of this card (2026-09-07)

The card and its frozen assertions were drafted by Claude Fable 5.1 acting
as orchestrator-delegate, then reviewed, reproduced and queued by the
orchestrator session, which owns the acceptance and is named above. The
assertions are still orchestrator-side and were written before any
implementation exists, so `docs/dispatch-contract.md:131` holds: the worker
does not author its own oracle.

The delegate corrected the brief it was given on four points, each verified
here rather than taken on trust:

- Card 121 had **landed** (`ab286ca`), not pending, so there is no
  path-claim collision to negotiate.
- The prose-token misfire is **already fixed** by 121; staging
  `docs/dispatch-contract.md` no longer trips the gate. This card does not
  re-card it.
- Stage 133's finding is **not** a worktree-versus-staged disagreement. The
  verifier compared `--worktree` against `print`, and `print` never reads
  the card. Both modes agree, and both are wrong the same way: `cat` on a
  missing card fails, `|| true` swallows it, and an empty read is reported
  as "card has no 'Assertions digest' line".
- There **is** a genuine same-tree disagreement, and it is this card's lead
  deliverable: `--worktree` reads `git diff --name-only`, so a staged change
  is invisible to it. A drifted block that has been added fails `--staged`
  and is "no relevant changed files" to `--worktree`.

