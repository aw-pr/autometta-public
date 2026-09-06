# Stage card 121: the gate checks only what a card can name

## Metadata

- **Authored:** 2026-09-06
- **Orchestrator:** Claude Fable 5.1 <claude-fable-5-1@local>
- **Worker:** Codex GPT-5.6 Sol <codex-gpt-5-6-sol@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Base branch:** dev
- **Run branch:** autometta/121-the-gate-checks-only-what-a-card-can-name
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Gate:** stage-completed: 106-the-gate-does-not-pass-what-it-cannot-check
- **Path claims:** scripts/check-contract-test-gate.sh, scripts/gate-smoke.sh, docs/dispatch-contract.md, stage-cards/121-the-gate-checks-only-what-a-card-can-name.md
- **Pairing rationale:** cross-family. Card 106 (Sonnet worker) narrowed the gate's fail-closed
  behaviour; this card narrows its candidate set, and the seat that did not
  write 106 is the one to confirm the two compose.
- **Type:** Gate correction. Gated on 106. Pipeline-eligible.

## Surfacing concern

`cmd_gate` treats any staged file containing the begin token anywhere as
a contract test (`scripts/check-contract-test-gate.sh`, the `grep -q` in
the staged-files loop). The token legitimately appears in the gate's own
usage comment, `docs/dispatch-contract.md`, `templates/worker-prompt.md`,
`templates/verifier-prompt.md`, `templates/stage-card.md`, `HANDOFF.md` and
several stage cards. Staging any of them trips the gate, which is why
cards must avoid spelling the token and why card 106's worker reported the
defect in its envelope.

## Objective

The gate considers a staged file a contract test only when a stage card
names it as one, or it is a `scripts/*-smoke.sh`; every other file is
skipped regardless of what tokens it contains.

## Inputs (read these in your own context)

- `scripts/check-contract-test-gate.sh`, as landed by card 106
- `scripts/gate-smoke.sh`, as landed by card 106
- `stage-cards/*.md`, the `Test file:` lines, for the set of names to honour
- `docs/dispatch-contract.md`, the Contract tests section

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. `cmd_gate` builds the candidate set from the union of every
   `- **Test file:**` path in `stage-cards/` and staged files matching
   `scripts/*-smoke.sh`, and skips any staged file outside it. A named
   test file with no marker block still fails, as 106 made it.
2. `scripts/gate-smoke.sh` gains: a staged `docs/` file containing the token
   is skipped; a staged template containing it is skipped; a staged smoke
   with a bad block still fails; a staged card-named non-smoke test with no
   block still fails. Frozen block around the new assertions.
3. `docs/dispatch-contract.md`: the candidate rule in one sentence.

## Constraints

- Nothing 106 made strict becomes lax; run its smoke.
- Keep the fixture tokens built from the gate's constants, as 106 did.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. Staging `docs/dispatch-contract.md` alone passes the gate.
2. Staging `templates/worker-prompt.md` alone passes the gate.
3. A staged `scripts/*-smoke.sh` with a changed block and a stale card digest
   still fails.
4. `scripts/gate-smoke.sh` passes; the docs and template cases fail against
   the pre-change gate.

## Contract test

- **Test file:** scripts/gate-smoke.sh
- **Assertions digest:** frame the assertions in a block between the begin
  marker and the end marker, the begin marker naming this card by its
  `card=stage-cards/121-the-gate-checks-only-what-a-card-can-name.md` field, and replace this line's text with the real
  digest printed by `scripts/check-contract-test-gate.sh print scripts/gate-smoke.sh`. Do not
  write a `sha256:` comment inside the block, and do not spell the marker
  tokens anywhere in this card's prose; the card is in your path claims for
  exactly this edit.

## Out of scope

- Vendoring the gate to subscribers; `vendor-set.sh` already does.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes

## Escalation

If a subscriber's cards live somewhere other than `stage-cards/`
(emergence-lab uses `docs/stages/`), read the manifest's `stage_card_globs`
and honour it; if the gate has no way to reach the manifest, report that
and honour both directories by name.

## Verifier handoff

Stage each of the token-carrying files on `dev` one at a time and run the
gate. Then confirm criterion 3 so the narrowing did not swallow the check
106 added.

## Family-specific notes

None

## Seat history (2026-09-06)

The Codex subscription closed at 10:31Z and this batch was re-seated onto
Claude alone; when Claude session windows then drained faster than the batch
was sized for, the verifying seat moved to the free local route
(`gpt-oss:120b` via `codex exec --oss`). The Codex window reopened the same
afternoon and the card is back on the seats it was authored with. Nothing
about the work changed across either move.

## Confirmed in the wild (2026-09-06)

Stage 113's verifier hit this while checking an unrelated stage, and its
reproduction is worth keeping as a ready test case.

Running the gate over a full staged change set exits 1 on two files that no
card names as a contract test:

- `docs/dispatch-contract.md` carries two `AUTOMETTA-CONTRACT-BEGIN`
  strings, a fenced example at :142 and prose at :168, so `extract_block`
  reports "more than one frozen block in file" (exit 4).
- `templates/stage-card.md`:75 mentions the marker in prose with no
  `card=` attribute, which draws the no-card warning.

Both were reproduced against pristine HEAD content in a scratch repo with
only those files staged, so **any commit touching either file trips the gate
regardless of its content**. Two cards in this batch claim
`docs/dispatch-contract.md` (113 and 131), so this is in the way now rather
than theoretical.

It is also a reason to prefer the objective's rule over a narrower fix: a
gate keyed to "does this file contain the token" cannot tell a document
*about* the markers from a test *using* them, and both of these files exist
to describe the mechanism.

