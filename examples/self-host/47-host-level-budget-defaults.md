# Stage card 47: the daily cap is a host decision, not a per-repo accident

## Metadata

- **Authored:** 2026-08-24
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Claude Opus 5 <claude-opus-5@local>
- **Verifier:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Base branch:** dev
- **Run branch:** autometta/47-host-level-budget-defaults
- **Worker effort:** medium
- **Verifier effort:** medium
- **Verifier panel:** false
- **Pairing rationale:** budget arithmetic and a setup path. Cross-family
  verification because a cap that silently fails open is worse than one set
  wrongly, and the author is the last to notice which they built.

## Objective

`token_cap_total` is written per repo into `state/budget.json` and never
revisited. The fleet currently reads 3,000,000 / 8,000,000 / 100,000,000 /
150,000,000 across five subscribers, with nothing recording why any of them
holds its number. The spread is accumulated history, not policy.

It cost an hour on 2026-08-23. emergence-lab spent 104,942,068 against a
100,000,000 cap during a deliberate weekly-token drain. The budget gate refused
the verifier dispatch at 00:01 with a finished worker sitting on a passing
envelope, re-halted through two attempts to clear it, and released only when
the midnight window reset zeroed the counter at 01:01. The cap was doing its
job; the number simply did not describe the intent.

The intent has two modes, and only one of them is the daily case:

- **Daily:** a cap that catches a runaway. Set once for the host, not argued
  per repo.
- **Overnight drain:** deliberately spend down the provider window and stop
  when the *provider* stops, around 01:00. The local cap should not be the
  thing that ends it.

Make the daily cap a host-level default chosen at setup, and give the drain its
own explicit mode.

## Inputs (read these in your own context)

- `scripts/init-host.sh` (writes the controller `config.yaml`)
- `scripts/budget.sh` (`budget_spend_caps_blown` and the halt path)
- `scripts/subscribe-repo.sh` (registers a repo; note it does not vendor)
- `schemas/budget.json`
- `skills/autometta-setup/SKILL.md` and its `REFERENCE.md`
- `docs/dispatch-contract.md`

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. A `token_cap_total` default in the controller `config.yaml`, written by
   `init-host.sh` and prompted for (or documented) at setup time.
2. Resolution order implemented in `budget.sh`: an explicit per-repo
   `token_cap_total` wins where present, otherwise the host default. A repo
   with no cap of its own must not fail open to unlimited.
3. A drain mode that lifts or raises the cap for a deliberate overnight run,
   set per run rather than by editing a repo's budget. It must be explicit,
   visible in the tick log when active, and must expire on its own so a drain
   cannot silently become the permanent setting.
4. `skills/autometta-setup/SKILL.md` covers budget policy: what the daily cap
   is for, that it is a host decision, and how a drain differs. The skill
   currently mentions `budget.json` only to say commit it and how to clear a
   halt.
5. `docs/dispatch-contract.md` documents resolution order and drain mode.
6. A one-off note in the handoff (not a code change) listing each existing
   subscriber's current cap, so the operator can decide which are deliberate
   and which were accidents.

## Constraints

- Do not change any existing repo's `budget.json` in this card. Migration is an
  operator decision, and the small caps on `emergence-viewer-deep-zoom` and
  `fractals-from-the-90s` may well be deliberate.
- No unlimited default. Drain mode may lift the cap; the resting state may not.
- Failure-cap and tick-cap behaviour is unchanged; this card is about the token
  cap only.
- A halt already latched must keep behaving as it does now. Raising a cap is
  not a licence to auto-clear a halt that was correctly taken.
- `state/` is runtime data and gitignored. Do not start tracking it.

## Acceptance criteria

1. A fresh `init-host.sh` run produces a config carrying a daily
   `token_cap_total`, and the value is visible to the operator at setup.
2. A repo with no `token_cap_total` inherits the host default, demonstrated
   against `budget.sh`.
3. A repo carrying its own `token_cap_total` keeps it, demonstrated.
4. A repo with neither is capped, not unlimited.
5. Drain mode raises or lifts the cap for one run, logs that it is active, and
   is no longer in force afterwards. Show the expiry.
6. With drain mode off and spend above the cap, the gate still refuses, exactly
   as it did on 2026-08-23.
7. The setup skill and dispatch contract document the model.
8. `bash -n` passes on every shell file touched; no subscriber's `budget.json`
   is modified; no file outside the deliverables is modified except this card.

## Contract test

- **Test file:** None
- **Assertions digest:** None

## Out of scope

- Per-model or per-tier pricing, and any spend-in-currency accounting.
- Changing the wall-clock or tick caps.
- Retrofitting existing subscribers, which criterion 6 of the deliverables only
  reports on.

## Budget

- **Worker wall-clock:** 60 minutes
- **Verifier wall-clock:** 30 minutes

## Verifier handoff

Return the generated config, the four resolution outcomes from criteria 2 to 4,
the drain-mode lifecycle including its expiry, and the refusal from criterion 6.
Confirm no subscriber `budget.json` was touched.

## Family-specific notes

None
