# Stage card 125: a turn is the unit nobody caps

## Metadata

- **Authored:** 2026-09-06
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Verifier:** Codex GPT-OSS 120B <codex-gpt-oss-120b@local>
- **Base branch:** dev
- **Run branch:** autometta/125-a-turn-is-the-unit-nobody-caps
- **Worker effort:** medium
- **Verifier effort:** medium
- **Verifier panel:** false
- **Path claims:** scripts/models.sh, scripts/spawn-worker.sh, scripts/spawn-verifier.sh, scripts/turn-cap-smoke.sh, docs/dispatch-contract.md, stage-cards/125-a-turn-is-the-unit-nobody-caps.md
- **Pairing rationale:** local verifier while the Codex cloud seats are out of
  session quota. The change is a flag-plumbing change with an executable
  smoke, which is the shape a local model can judge honestly: every criterion
  below is a command with an observable exit status rather than a judgement
  about design.
- **Type:** Spend ceiling on dispatch. Touches both spawn scripts, so serial.

## Surfacing concern

Nothing bounds how long a dispatched run may go on.

`scripts/spawn-worker.sh:256` and `scripts/spawn-verifier.sh:844` build the
`claude -p` command line out of a model, an effort argv, `--dangerously-skip-permissions`
and the prompt. There is no turn ceiling in either, and no equivalent for the
Codex routes. `scripts/tick.sh:1038` reads `token_cap_total` from
`state/budget.json` at *dispatch* time only: once a run is away it can spend
whatever it likes and the cap is not consulted again.

The ledger shows what that costs. Since 2026-09-01, `state/cost-log.jsonl`
records 34 dispatches, 173.3M tokens, $184.03. Of the input, **5.2M tokens
were fresh and 167.3M were cache reads** — 97%. Spend on this fleet is not a
function of prompt size or card size; it is a function of how many turns a run
takes, because every turn re-reads the whole conversation.

One card carries the evidence. Stage 104 took six dispatches, 80.3M tokens and
$79.24 to land. Two of its workers ran 23.5M tokens in 1271s and 23.3M tokens
in 1161s. A worker still going at that point is looping, not working, and
nothing was in a position to say so.

This card does not attempt to detect a loop. It puts a declared ceiling on the
unit that actually meters, so an unbounded run becomes a bounded partial the
operator can re-brief.

## Objective

Every dispatch carries a turn ceiling: a fleet default a card may override,
plumbed the way effort already is, and a run that ends by hitting it is
recorded as a partial rather than read as a pass.

## Inputs (read these in your own context)

- `scripts/models.sh:149-190`, `effort_flags_for_family` and
  `effort_argv_for_family` — the pattern this card mirrors, including why the
  return channel is a global array and why callers expand it with the
  `+alternate` guard
- `scripts/spawn-worker.sh:37-40` (`extract_worker_effort`), `:133-141` and
  `:240-256`
- `scripts/spawn-verifier.sh:35-38`, `:533-540` and `:690-845`
- `templates/stage-card.md`, the Worker effort and Verifier effort lines
- `scripts/effort-flags-smoke.sh`, as the model for the new smoke
- `docs/dispatch-contract.md`, the section describing effort
- `claude --help` and `codex exec --help` on this machine, to establish what
  each CLI actually accepts before you write a flag into a command line

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. `scripts/models.sh` gains `AUTOMETTA_TURN_CAP_DEFAULT`, environment-
   overridable in the same style as `AUTOMETTA_MODEL_CODEX_LOCAL`, set to
   **60**. The comment states the reasoning the ledger supports: the cap is
   there to convert an unbounded run into a bounded partial, not to right-size
   a stage, so it sits well above what an ordinary stage takes.
2. `scripts/models.sh` gains `turn_cap_flags_for_family` and
   `turn_cap_argv_for_family`, mirroring the effort pair exactly: the argv
   lands in a global array, an empty or `None` value produces an empty array,
   and a non-numeric value prints a warning to stderr and produces an empty
   array rather than failing the dispatch — the same choice effort already
   makes, for the same reason.
3. A family that has no turn-ceiling flag gets an empty argv and a comment
   saying so plainly. Do not invent a flag for a CLI that does not have one:
   establish per family, from `--help`, whether a ceiling exists, and record
   what you found in the envelope.
4. A card may declare `- **Turn cap:**` per role, extracted by the same
   `sed -n 's/^- \*\*Worker turn cap:\*\* //p'` idiom as effort, in both spawn
   scripts. An absent field means the fleet default, and `None` means no
   ceiling — a stage that genuinely needs to run unbounded can say so, and it
   then says so on the card where the operator can see it.
5. Both spawn scripts expand the new array into the dispatch command line
   alongside the effort argv, with the same `+alternate` guard, and log the
   resolved cap on the same line style as `log_msg "worker effort: ..."`.
6. `scripts/turn-cap-smoke.sh` covers: default applied when the card is silent;
   card value overriding the default; `None` producing no flag; a non-numeric
   value warning and producing no flag; and a family with no flag producing an
   empty argv. It must fail against the pre-change tree — demonstrate that.
7. `docs/dispatch-contract.md` documents the field next to effort, including
   what an operator should read a turn-capped exit as: a partial to re-brief,
   never a failed stage.

## Constraints

- Do not change effort resolution. This card sits beside it, and the two must
  stay independently readable.
- A run that exits because it hit the ceiling must not be recorded as `pass`.
  Establish how the current envelope and cost-log `result` are derived for a
  run whose CLI exits early, and if a truncated run would currently read as a
  pass, say so in the envelope. Fixing that is stage 109's territory if it
  turns out to live in `scripts/tick.sh`; do not follow it there.
- Do not touch `scripts/tick.sh`. Stage 109 is pending against it and claims
  it.
- Bash 3.2 is the system shell on this machine. The `+alternate` guard on
  every array expansion is not optional.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. `bash -n scripts/models.sh scripts/spawn-worker.sh scripts/spawn-verifier.sh scripts/turn-cap-smoke.sh` is clean.
2. Sourcing `scripts/models.sh` and calling `turn_cap_argv_for_family claude ""`
   yields the default cap; calling it with an explicit value yields that value;
   calling it with `None` yields an empty array; calling it with `banana` warns
   on stderr and yields an empty array.
3. The flag the Claude route emits is one `claude --help` actually lists.
   Confirm this by reading the help output yourself, not by trusting the card.
4. A dry run of each spawn script shows the cap in the assembled command line
   for a card that declares one, and shows the default for a card that does not.
5. `scripts/turn-cap-smoke.sh` passes on the changed tree and fails on the
   pre-change tree. Run it both ways and show the two exit statuses.
6. `scripts/effort-flags-smoke.sh` still passes unchanged.
7. The envelope reports what you found for criterion 3 per family, and what you
   found about how a truncated run is currently recorded.

## Contract test

- **Test file:** scripts/turn-cap-smoke.sh
- **Assertions digest:** frame the assertions in a block between the begin
  marker and the end marker, the begin marker naming this card by its
  `card=stage-cards/125-a-turn-is-the-unit-nobody-caps.md` field, and replace
  this line's text with the real digest printed by
  `scripts/check-contract-test-gate.sh print scripts/turn-cap-smoke.sh`. Do not
  write a `sha256:` comment inside the block, and do not spell the marker
  tokens anywhere in this card's prose; the card is in your path claims for
  exactly this edit.

## Out of scope

- Killing a run in flight on token spend. That reads live state and belongs
  with the stall check in `scripts/tick.sh`, which stage 109 claims.
- Detecting a looping worker, as opposed to bounding one.
- Re-tuning the default away from 60 on evidence this card cannot yet have.
  Land the mechanism; the number is an operator decision afterwards.
- Any change to `state/budget.json` or its cap semantics.

## Budget

- **Worker wall-clock:** 60 minutes
- **Verifier wall-clock:** 30 minutes

## Escalation

If a CLI turns out to have no turn-ceiling flag at all, stop before inventing a
substitute — a wall-clock timeout wrapper is a different mechanism with
different failure modes and it is not what this card authorises. Land the
ceiling for the families that support one, record the gap for the families
that do not, and leave it to the operator.

## Verifier handoff

Do not take criterion 3 on trust from the worker's prose. Run the CLI's help
yourself and confirm the emitted flag appears in it; a plausible-looking flag
that the CLI rejects would break every dispatch on this fleet, and it is the
single most likely way this card passes wrongly. Judge criterion 5 by running
the new smoke against the pre-change script and watching it fail — a smoke that
passes against both trees is not a regression test.

## Family-specific notes

The Claude route dispatches `claude -p` (`spawn-worker.sh:256`). The Codex
routes dispatch `codex exec`, cloud and `--oss` local. Whether each accepts a
turn ceiling is a question for `--help` on this machine, not for this card.
