---
name: autometta-card-review
description: >-
  Interview the operator and review one Autometta stage card before it is
  queued, with proportionate preparation: a short frontier interview
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
card is not queued for execution until it reads `none`. Known implementation
uncertainty or an explicitly assigned evidence task is not an undecided product
choice; record it as a risk or deliverable, not as an endless readiness blocker.

## Preparation must earn its cost

Optimise total cost to a verified result, not a perfect first-attempt rate.
Preparation is useful when it prevents an ambiguous, impossible or unsafe
attempt; it must not become a second implementation before the worker starts.

- Record a preparation allowance alongside the worker/verifier estimate.
  Include authoring, test harness work, reference experiments, cold reads and
  controller sessions. Compare like units: cached-inclusive tokens with the
  same token measure, or provider cost with cost. Report cached input separately;
  a dashboard prediction and a historical token estimate are not interchangeable.
- Default checkpoint: 10% of the expected cost of one worker/verifier attempt.
  If no credible comparable estimate exists, use a 15-minute initial checkpoint.
  These are planning defaults, not permission to change runtime caps. At the
  checkpoint stop adding preparation and choose a smaller card, a bounded
  implementation attempt, or a specifically justified extension within existing
  authority. Never renew the allowance by changing model or restarting context.
- Use a coding-tier model for routine readiness work. Reuse exact-head evidence
  and cold-read findings; rerun only checks invalidated by code, environment or
  acceptance changes. Read narrow files and excerpts instead of full histories.
  A frontier session is for a concrete unresolved judgement, not polling.
- Before dispatch establish the outcome, scope, judging seat, executable core
  check, known baseline failures and spend/stop limits. Do not pre-implement the
  whole feature or build a comprehensive new evidence framework to avoid a
  bounded worker failure. Follow the oracle skill's proportional proof rules.
- If the operator authorises a bounded attempt with incomplete new coverage,
  record precisely what is validated, defective or deferred, who supplies the
  remaining evidence, and what prevents PASS without it. Existing frozen tests
  and criteria stay binding unless explicitly amended. A broken harness is
  inadequate evidence, not a proven product failure. Never count skips as PASS
  or label an implementation card prose-only to evade the gate.
- Once the card is actionable, hand it to the worker. Use the deterministic tick,
  heartbeat and shell state-change waits for monitoring; invoke a model for a
  concrete failure or decision. Do not spend model turns watching unchanged logs.

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
3. **Baseline.** Record red or green for each acceptance command, reusing
   evidence on unchanged source/environment. Run missing or invalidated checks.
   An unintended baseline failure (card 116), or
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
can share one cold read. Reuse an existing review for unchanged scope; a
follow-up should address only unresolved findings. Fold each material item into
the card or assign it explicitly as evidence work for a bounded attempt. A same-family subagent reads the way the author reads; if one is
all you can use, say so in the card's Surfacing concern.

## 4. Lint, then queue

`scripts/card-lint.sh --strict <<card>>` must exit 0. It catches unfilled
placeholders, an open decision, a same-family pairing with no rationale,
missing budget lines or headings, Inputs that do not exist, deliverables
outside Path claims, absolute home paths, and a contract test that is
missing, names another card, carries a NONE marker or does not match its
digest, and xhigh or max effort with no `Effort approved` line (lower it
per autometta-run-design section 2 unless the operator asked). A `frontier-tier` NOTE does not block: confirm the
pairing rationale says why the role needs Fable or Astra (high complexity
or UI work as worker; a judgement-heavy verification as verifier). Keep the
pin when it does; do not trade it down by default. Then
`scripts/add-stage.sh <<repo>> <<card>>`.

## Done when

- `Open decisions: none` on the card.
- Every criterion names a seat and a command; baseline results and any
  operator-approved coverage exception are recorded without implying PASS.
- Claims closure done; its findings are in Deliverables and Path claims.
- The cold read has no unassigned material findings, and the card says which
  family read it. Known evidence tasks have a judging seat and a fail-closed verdict.
- `card-lint.sh --strict` exits 0.
