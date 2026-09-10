# Stage card 126: the verifier does not think harder than it reads

## Metadata

- **Authored:** 2026-09-06
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Verifier:** Codex GPT-OSS 120B <codex-gpt-oss-120b@local>
- **Base branch:** dev
- **Run branch:** autometta/126-the-verifier-does-not-think-harder-than-it-reads
- **Worker effort:** medium
- **Verifier effort:** medium
- **Verifier panel:** false
- **Gate:** stage-completed: 125-a-turn-is-the-unit-nobody-caps
- **Path claims:** scripts/models.sh, scripts/spawn-verifier.sh, scripts/verifier-effort-default-smoke.sh, templates/stage-card.md, docs/dispatch-contract.md, stage-cards/126-the-verifier-does-not-think-harder-than-it-reads.md
- **Pairing rationale:** local verifier while the Codex cloud seats are out of
  session quota. The card is also its own demonstration: it is verified at
  `medium` by a local model, which is the claim it makes.
- **Type:** Default correction. Gated behind 125 because both edit
  `scripts/models.sh` and `scripts/spawn-verifier.sh`.

## Surfacing concern

`high` has become the reflex setting for a role that mostly reads.

Across `stage-cards/`, 70 of 129 cards declare `- **Verifier effort:** high`
against 26 at `medium`. Of the 17 cards currently pending or in progress, 13
are at `high` or above. No card in the tree was written with a reason for the
choice; it is what the last card said.

The ledger says that reflex is the expensive half. Since 2026-09-01, across 17
worker runs and 17 verifier runs, `state/cost-log.jsonl` records **workers at
$51.11 and verifiers at $132.91** — the seat that judges finished work costs
two and a half times the seat that produces it.

Effort buys reasoning tokens. A worker earns them: it is deciding what to write.
A verifier is running commands from a card's acceptance criteria and reporting
exit statuses, and the criteria are frozen at authoring time precisely so that
the judgement is mechanical. There are stages where a verifier genuinely has to
reason — an architectural claim, a security argument, a card whose criteria are
prose. Those should say `high` and say why. The default should not.

`effort_flags_for_family` (`scripts/models.sh:154-170`) already does the right
thing with an absent value: it prints nothing and leaves the CLI on its own
default. That is a reasonable floor but it is not a fleet position, so every
card states one, and every card states the same one.

## Objective

An unset verifier effort resolves to a declared fleet default of `medium`, the
template asks a card that wants more to say why, and the pending queue stops
running `high` by inheritance.

## Inputs (read these in your own context)

- `scripts/models.sh:149-190`, `effort_flags_for_family` and its comment on
  what an absent and an unrecognised value each do
- `scripts/spawn-verifier.sh:35-38` and `:533-540`
- `templates/stage-card.md`, the Verifier effort line
- `scripts/effort-flags-smoke.sh`
- `docs/dispatch-contract.md`, the section describing effort
- `state/state.yaml`, to enumerate the cards currently `pending` or
  `in_progress`

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. `scripts/models.sh` gains `AUTOMETTA_VERIFIER_EFFORT_DEFAULT`, environment-
   overridable, set to `medium`, with a comment recording the ledger evidence
   above rather than asserting a preference.
2. `scripts/spawn-verifier.sh` applies that default when the card declares no
   verifier effort. A card that declares one still wins, and `None` still means
   "leave the CLI on its own default" — the escape hatch must survive, because
   a fleet default that cannot be turned off is worse than the reflex it
   replaces.
3. The worker default is **not** changed. Only the verifier seat gets a fleet
   default in this card; the worker's absent-means-CLI-default behaviour stays
   exactly as it is.
4. `templates/stage-card.md` rewrites the Verifier effort line: state the
   default, and ask a card choosing `high` or above to give its reason on the
   same line. Keep the line a single bullet; the section headings and field
   names are load-bearing and must not change.
5. The 13 cards currently pending or in progress at `high` or above have their
   verifier effort set to `medium`, **except** any whose acceptance criteria are
   substantially prose judgement rather than executable checks. Read each card's
   Acceptance criteria section before changing it, list in the envelope which
   you changed and which you left, and give the one-line reason for each you
   left. Do not touch cards in any other status: a completed card records what
   actually ran and rewriting it falsifies the record.
6. `scripts/verifier-effort-default-smoke.sh` covers: absent card field
   resolving to the fleet default; a card field overriding it; `None`
   suppressing the flag entirely; the environment override taking effect; and
   the worker seat being unaffected by any of it. It must fail against the
   pre-change tree — demonstrate that.
7. `docs/dispatch-contract.md` states the default and the rule that `high` is
   the exception that carries a reason.

## Constraints

- Do not edit any card whose status is not `pending` or `in_progress`.
- Do not change `effort_flags_for_family`'s handling of an unrecognised value.
  A typo must still cost a stage its override and not its run.
- Do not introduce a second place where effort is resolved. If applying the
  default in `spawn-verifier.sh` would duplicate logic that belongs in
  `models.sh`, put it in `models.sh` and call it.
- Stage 125 has already landed against these two files. Rebase on its result
  rather than reverting any part of it.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. `bash -n` clean across every script touched, and
   `scripts/verifier-effort-default-smoke.sh`.
2. A card with no verifier effort field dispatches with the fleet default; the
   assembled command line shows it.
3. A card declaring `high` still dispatches `high`. A card declaring `None`
   dispatches with no effort flag at all.
4. `AUTOMETTA_VERIFIER_EFFORT_DEFAULT=low` in the environment changes the
   resolved default and nothing else.
5. The worker seat's resolution is byte-for-byte unchanged. Show a worker
   dispatch line from before and after and confirm they match.
6. Every pending and in-progress card is either at `medium` or below, or is
   named in the envelope with its reason for staying higher. The count of cards
   changed plus the count left equals 13.
7. No card outside `pending` or `in_progress` is modified. `git diff --name-only`
   against the base branch demonstrates this.
8. `scripts/effort-flags-smoke.sh` and `scripts/turn-cap-smoke.sh` both still
   pass.

## Contract test

- **Test file:** scripts/verifier-effort-default-smoke.sh
- **Assertions digest:** frame the assertions in a block between the begin
  marker and the end marker, the begin marker naming this card by its
  `card=stage-cards/126-the-verifier-does-not-think-harder-than-it-reads.md`
  field, and replace this line's text with the real digest printed by
  `scripts/check-contract-test-gate.sh print scripts/verifier-effort-default-smoke.sh`.
  Do not write a `sha256:` comment inside the block, and do not spell the
  marker tokens anywhere in this card's prose; the card is in your path claims
  for exactly this edit.

## Out of scope

- The 57 completed cards at `high`. They are a record, not a queue.
- Any change to worker effort defaults or to which model a seat resolves to.
- Retiring the effort field, or collapsing the level set.
- The verifier panel path.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 25 minutes

## Escalation

If reading the 13 pending cards suggests that most of them genuinely need
`high` — that their acceptance criteria are prose rather than commands — stop
and report that count. It would mean the defect is in how criteria are written,
not in the effort field, and that is a different card.

## Verifier handoff

Check criterion 5 by construction, not by reading the diff: assemble a worker
dispatch line on the base branch and on the run branch and compare them
directly. A change that quietly gives the worker seat a default too would halve
the value of every worker run on this fleet and would not be visible in the
verifier-side tests. Then confirm criterion 7 with `git diff --name-only`
yourself; the envelope's own list is not evidence for it.

## Family-specific notes

None.
