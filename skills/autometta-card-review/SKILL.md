---
name: autometta-card-review
description: >-
  Interview the operator and review one Autometta stage card before it is
  queued, so the worker lands it on attempt 1: a short frontier interview
  with a recommended answer per question, a seat check and a baseline run
  for every acceptance command, a claims-closure grep, a cold read by the
  other model family, and card-lint under --strict. Use when the operator
  says "write a card for X", "card it up", "card up", "is this card ready",
  "review the card", "grill the card", "check the queued cards", or when
  autometta-run-design hands over one card from a batch. Not for planning
  or sizing a batch (autometta-run-design), writing the frozen test
  (autometta-oracle) or minding a live queue (phat-controller).
---

# Card interview and readiness review

Across this repo's history, more than half of the failed attempts with a
known cause traced to the card, not the worker. In order: a criterion the
judging seat could not satisfy or that was already red on the base,
missing harness context, an undecided design question, wrong path claims,
a wrong or toothless oracle. Each was a question nobody asked before
spending a dispatch. This skill asks them.

The card's `- **Open decisions:**` metadata line is the exit condition: the
card is not queued until it reads `none`.

## 1. Interview, briefly

Look facts up yourself (grep, read the files, run the commands); put only
decisions to the operator. Ask in rounds: each round, every question whose
prerequisites are settled, numbered, each with your recommended answer
worded so that "yes" accepts it. Keep the whole interview to about five
questions; needing more usually means the card is two cards. Write each
answer into the card section it belongs to, never into chat alone.

Work through this list in order, and stop early when the card is small
enough that its diff fits one sentence:

1. **Outcome.** One observable outcome, and the command that shows it.
2. **Seat per criterion.** Who judges each criterion, with what command,
   and can that seat run it? Codex roles run under workspace-write: no
   socket unless `Requires network`, no browser unless `Requires GUI`. A
   one-shot `claude -p` session cannot wait for a background batch. The
   wall clock is what the card declares.
3. **Baseline.** Run every acceptance command on the clean base now and
   record red or green. A criterion already red on the base (card 116), or
   one that forbids what a tool does by design (card 122), is a card
   defect. An environment gap (a missing Python module) is recorded on the
   card as unchanged-from-base, not made a criterion.
4. **Surfaces.** Every surface the change touches (CLI and TUI, table and
   detail pane, schema and fixtures) is a deliverable with an assertion.
5. **Claims closure.** For every symbol, field or rule the card changes,
   grep its consumers and read them. Each file the worker must touch is a
   numbered Deliverable inside Path claims. Card 113's first attempt spent
   822k tokens finding one unclaimed schema.
6. **Out of scope.** Name what the worker will plausibly touch and must not.
7. **Size.** The work fits one fresh context window and the card's
   wall-clock band; otherwise split it along a vertical slice.
8. **Prior walls.** `scripts/facts-query.sh --predicate failed-criterion`
   and the `## Re-brief` sections of related cards; carry forward any wall
   a previous card hit.
9. **Restore and re-brief steps.** If the card restores files from an
   earlier attempt (`git checkout <<sha>> -- .`), check what else that
   rewinds: the card file itself is usually in that tree.

## 2. The oracle

If the card earns a contract test, run `autometta-oracle` now; the answers
above are its input.

## 3. Cold read by the other family

Hand the card, and nothing else, to a fresh session in the other model
family, read-only: "List every question you would have to ask before
starting, every criterion you could not produce evidence for from your
seat, and any contradiction between the card, its test and the repo." From
a Claude seat, use the manual dispatch pattern in `CLAUDE.md` with a
read-only sandbox:

    source op-refs.sh
    auth_pairs="$(REPO_ROOT="$PWD" scripts/auth-route.sh codex)"
    op-fetch $auth_pairs -- codex exec -C "$PWD" --sandbox read-only \
      "$(cat cold-read-prompt.txt)" </dev/null

(add `--pass CODEX_HOME` when codex is in api mode). From a Codex seat,
`op-fetch $auth_pairs -- claude -p "$prompt" </dev/null`. Several cards
can share one cold read. Fold every item back into the card or answer it
there. A same-family subagent reads the way the author reads; if one is
all you can use, say so in the card's Surfacing concern.

## 4. Lint, then queue

`scripts/card-lint.sh --strict <<card>>` must exit 0. It catches unfilled
placeholders, an open decision, a same-family pairing with no rationale,
missing budget lines or headings, Inputs that do not exist, deliverables
outside Path claims, absolute home paths, and a contract test that is
missing, names another card, carries a NONE marker or does not match its
digest, and xhigh or max effort with no `Effort approved` line (lower it
per autometta-run-design section 2 unless the operator asked). Then `scripts/add-stage.sh <<repo>> <<card>>`.

## Done when

- `Open decisions: none` on the card.
- Every criterion names a seat and a command, and the baseline result of
  each command is recorded.
- Claims closure done; its findings are in Deliverables and Path claims.
- The cold read returned nothing unanswered, and the card says which
  family read it.
- `card-lint.sh --strict` exits 0.
