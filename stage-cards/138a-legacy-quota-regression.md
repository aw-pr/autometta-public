# Stage card 138a: Preserve the explicit legacy reserve policy

## Metadata

- **Authored:** 2026-09-20
- **Orchestrator:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** none (interactive change, offline contract checks)
- **Base branch:** dev
- **Run branch:** dev
- **Dispatch:** interactive

## Operator instruction and scope

The historical provider-window regression runs with AUTOMETTA_CODEX_QUOTA_POLICY=reserve. Freeze its existing assertions while the default Codex policy moves to card admission. No historical frozen assertion block is changed.

This records a direct operator-requested default change. It is not a queued
provider dispatch or a claim of independent model verification. No account
billing settings, credentials or reset inventory are changed by these tests.

## Acceptance

Run `scripts/quota-window-smoke.sh` without provider calls. The frozen assertions must pass.
Run the related reserve, schedule and quota regressions, shell syntax checks
and the contract-test gate. Record failures without weakening assertions.

## Contract test

- **Test file:** scripts/quota-window-smoke.sh
- **Assertions digest:** sha256:e1960b4ecf82a987d11c4fa7ce97a8fa7bb6d41bd0d177c03ee5201c2170b52d
