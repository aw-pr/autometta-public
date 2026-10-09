# Stage card 138: Use the full Codex window for one admitted card

## Metadata

- **Authored:** 2026-09-20
- **Orchestrator:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** none (interactive change, offline contract checks)
- **Base branch:** dev
- **Run branch:** dev
- **Dispatch:** interactive

## Operator instruction and scope

New subscription cards require fresh five-hour and weekly readings below 100%. The active card may finish in overage. Check both roles before admitting a card, preserve Claude reserves and exclude API/local routes.

This records a direct operator-requested default change. It is not a queued
provider dispatch or a claim of independent model verification. No account
billing settings, credentials or reset inventory are changed by these tests.

## Acceptance

Run `scripts/codex-card-quota-smoke.sh` without provider calls. The frozen assertions must pass.
Run the related reserve, schedule and quota regressions, shell syntax checks
and the contract-test gate. Record failures without weakening assertions.

## Contract test

- **Test file:** scripts/codex-card-quota-smoke.sh
- **Assertions digest:** sha256:f13150b6593f8ca12fe21f0be674504f86bdbe23c2a413a9535bea0798bb610e
