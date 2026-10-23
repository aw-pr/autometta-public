# Stage card 162a: the spend authority is dropped

## Metadata

- **Authored:** 2026-10-23
- **Orchestrator:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Worker:** GPT-6.1 Sol <gpt-6-1-sol@local>
- **Verifier:** Claude Sonnet 5.5 <claude-sonnet-5-5@local>
- **Base branch:** dev
- **Run branch:** autometta/162a-spend-authority-dropped
- **Worker effort:** low
- **Verifier effort:** low
- **Verifier panel:** false
- **Dispatch:** serial
- **Pairing rationale:** a docs-and-template repair of about 25 lines across five files, fully covered by a grep-level contract test: Sol writes it on the Codex window and Sonnet verifies cross-family on the Claude window, the same pairing as card 163. Low effort on both seats because there is no design left in it.
- **Open decisions:** none
- **Operator decision:** 2026-10-23, drop the field rather than have the tick enforce it.
- **Cold read:** skipped for this card; a same-family read by the orchestrator only. The diff fits one sentence and the frozen test pins every surface.
- **Claims closure:** 2026-10-23, `git grep -i 'spend.authority'` outside stage cards, the handoff, memory, incident and run logs and the two superseded proposals. Every hit is a deliverable below; no script or smoke reads the field.

## Surfacing concern

Card 162 removed the controller pass, and with it `pc_spend_authority_exhausted`, the only code that ever read `spend_authority` from the mandate. The docs it left behind say the opposite: `docs/tick-loop.md`, the mandate template, the `autometta-setup` skill, a comment in `scripts/phat-controller.sh` and the table in `docs/proposals/controller-retired.md` all say the tick reads the spend-authority fields through `quota_gate_family_dispatch`. It does not. An operator who sets a ceiling believes spend is bounded when it is not. The operator chose to drop the field: each repo's `budget.json` caps and a bounded drain stay the hard stops.

## Objective

No live surface mentions or offers `spend_authority`, the retirement proposal records that it was dropped, and nothing else about the mandate changes.

## Inputs (read these in your own context)

- `templates/phat-controller-mandate.yaml.tpl` (header comment and the `spend_authority` block)
- `docs/tick-loop.md` (the "The mandate file stays, for the tick" paragraph and the "There is no default spend authority" paragraph after it)
- `skills/autometta-setup/SKILL.md` (the host-level mandate section)
- `scripts/phat-controller.sh` (the comment above `pc_mandate_ensure`)
- `docs/proposals/controller-retired.md` (the Decision paragraph, the duty table and Consequences)
- `scripts/spend-authority-dropped-smoke.sh` (the frozen contract test)

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `templates/phat-controller-mandate.yaml.tpl`: remove the `spend_authority` block and its comment, and every header mention of the spend authority. The file still parses and keeps `window_reserve`, `escalation` and `repos` unchanged.
2. `docs/tick-loop.md`: the mandate paragraph names only the reserve and curfew fields as what the tick reads; remove the "There is no default spend authority" paragraph. Say in one sentence that the per-repo `budget.json` caps and a drain are the hard spend stops, if the paragraph does not already.
3. `skills/autometta-setup/SKILL.md`: drop the spend-authority question to the operator and the two `spend_authority.*` fields from the hand-edit list.
4. `scripts/phat-controller.sh`: the comment above `pc_mandate_ensure` names only the reserve and curfew fields. Comment only; no code change.
5. `docs/proposals/controller-retired.md`: the Decision paragraph and the "Stop at an exhausted spend authority" table row no longer say the tick reads `spend_authority`; the row says the per-repo `budget.json` caps and drains are the stop. Add a Consequences bullet saying `spend_authority` was removed because only the retired pass read it, and that a mandate still carrying it is read with the key ignored. The Evidence section stays as it is: it is history.
6. `scripts/spend-authority-dropped-smoke.sh` (frozen, written by the orchestrator; do not edit it).

## Constraints

- No code change to any script. `scripts/phat-controller.sh` changes in its comment only.
- Do not touch stage cards, `HANDOFF.md`, `memory/`, `docs/incidents/`, `docs/runs/` or the superseded proposals `orchestrator-role-review.md` and `controller-as-correspondent.md`: they are records.
- British English, no em dashes, no AI-tell vocabulary (`CLAUDE.md` conventions).
- No absolute home paths in committed files.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. **Smoke, worker and verifier:** `scripts/spend-authority-dropped-smoke.sh` exits 0. Base: red at `the mandate template still carries spend_authority`.
2. **No regression, worker and verifier:** `scripts/quota-window-smoke.sh`, `scripts/reserve-default-smoke.sh`, `scripts/reserve-schedule-smoke.sh`, `scripts/session-window-smoke.sh`, `scripts/quota-pace-smoke.sh`, `scripts/phat-controller-smoke.sh` and `scripts/card-lint-smoke.sh` exit 0. Base: green.
3. **Prose, verifier:** `git diff dev -- docs skills templates` reads correctly, in British English with no em dashes, and changes nothing about the mandate except removing the spend authority.
4. **Parse, worker:** `bash -n scripts/phat-controller.sh` passes and `shellcheck -S warning scripts/spend-authority-dropped-smoke.sh` exits 0.

## Contract test

- **Test file:** `scripts/spend-authority-dropped-smoke.sh`
- **Assertions digest:** `sha256:8919e97c05387ba3b25e0d95303cd309c4cb77f12351f240eba257ebb0354811`
- **Oracle proof:** fails on dev at the template check. A throwaway reference (deliverables 1 to 5, seven lines added and 24 removed) passed it and left the criterion 2 smokes green. Each assertion names the file it guards, so leaving any one surface unedited trips its own line.

## Out of scope

- Enforcing a spend ceiling in the tick (the operator declined it).
- The host's own `$AUTOMETTA_HOME/phat-controller-mandate.yaml`: the orchestrator removes the key there after landing, outside the worker sandbox.
- Renaming the mandate file or any other field.

## Budget

- **Worker wall-clock:** 15 minutes (kill at 30)
- **Verifier wall-clock:** 10 minutes
- **Spend basis:** `state/cost-log.jsonl`: autometta role median 1.0M tokens. A five-file docs edit at low effort; plan 2M for the stage.

## Dispatch envelope

Write `state/envelopes/162a-spend-authority-dropped.json` using `schemas/envelope.json`. List changed deliverables, the exact smoke commands and their results, and any criterion you could not satisfy with why. If the card itself is wrong, stop with `status: fail` and say so in `notes` rather than working round it. Do not self-verify or land your own branch. The verifier writes `state/verifiers/162a-spend-authority-dropped.json`.

## Family-specific notes

None
