# Stage card 89: the SDK verifier runs on the subscription

## Metadata

- **Authored:** 2026-08-31
- **Orchestrator:** Claude Fable 5 <claude-fable-5@local>
- **Worker:** Claude Opus 5 <claude-opus-5@local>
- **Verifier:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Base branch:** dev
- **Run branch:** autometta/89-the-sdk-verifier-runs-on-the-subscription
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Gate:** stage-completed: 85-the-verifier-reads-the-ledger-first
- **Path claims:** scripts/spawn-verifier.sh, scripts/verify-sdk.py, docs/sdk-verifier.md
- **Pairing rationale:** auth-route plumbing is where a silent wrong-billing
  bug lives (gotcha 8 is the codex mirror of it), so the stronger Claude tier
  does the wiring and the codex verifier re-runs the route probes from
  outside. Gated on 85 because both cards claim `spawn-verifier.sh`.

## Objective

The SDK verifier route currently fails closed on `auth.claude.mode:
subscription` (`docs/sdk-verifier.md`, failure table). That gate is our own
conservatism, not an SDK limit: the Agent SDK runs the Claude Code harness,
which authenticates with `CLAUDE_CODE_OAUTH_TOKEN` (minted once by `claude
setup-token`), and `op-refs.sh` already reserves
`OP_REF_CLAUDE_CODE_OAUTH_TOKEN` for exactly this. The operator wants the
SDK route on the subscription so the CLI stops being the only OAuth
transport: the SDK route streams per-message usage, which is the honest path
to real-time token visibility.

Wire the subscription branch: when `transport: sdk` meets `auth.claude.mode:
subscription`, resolve `OP_REF_CLAUDE_CODE_OAUTH_TOKEN` through op-fetch and
inject it as `CLAUDE_CODE_OAUTH_TOKEN`; keep the api branch exactly as it
is. An unset or placeholder OAuth ref fails closed with a message naming
`claude setup-token` and the ref, before any process spawns.

## Inputs (read these in your own context)

- docs/sdk-verifier.md
- scripts/spawn-verifier.sh
- scripts/verify-sdk.py
- scripts/auth-route.sh
- op-refs.sh

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/spawn-verifier.sh`: the sdk+subscription branch described above.
   The op-fetch invocation names only the OAuth ref for this branch, so the
   API keys stay structurally absent from its child env, matching the route
   isolation the bake-off proved for the free tiers.
2. `scripts/verify-sdk.py`: accepts the OAuth-token env as an auth source if
   it currently insists on `ANTHROPIC_API_KEY`; no other behaviour change.
3. `docs/sdk-verifier.md`: the failure table row for `transport: sdk` +
   `subscription` changes from fail-closed to the new contract; a short
   subsection states the token is minted by `claude setup-token`, lives in
   1Password behind `OP_REF_CLAUDE_CODE_OAUTH_TOKEN`, and notes Anthropic's
   published position that products must not offer claude.ai login to third
   parties, which a solo operator's own machine does not do.

## Constraints

- The api branch and the cli transport are byte-for-byte untouched apart
  from the failure-table doc row.
- Fail closed on a missing or placeholder OAuth ref; never fall back
  silently to `ANTHROPIC_API_KEY` or to the cli transport on an auth
  mismatch, because a silent fallback is how billing goes wrong invisibly.
- No secrets in code or logs; the token exists only in the child env
  op-fetch builds.
- Multi-token argument lists travel in bash arrays, expanded quoted
  (gotcha 12).

## Acceptance criteria

1. `bash -n scripts/spawn-verifier.sh` and `python3 -m py_compile
   scripts/verify-sdk.py` both pass.
2. With `transport: sdk`, `auth.claude.mode: subscription` and a resolvable
   OAuth ref, a dry-run spawn (or the route's cheapest real probe) reaches
   the SDK entrypoint with `CLAUDE_CODE_OAUTH_TOKEN` set and no
   `ANTHROPIC_API_KEY` in its env; shown by the spawn's own route log line
   or an env probe, not asserted in prose.
3. With the OAuth ref unset or left as a `YOUR_VAULT` placeholder, the spawn
   exits non-zero before any process starts and the message names both the
   ref and `claude setup-token`.
4. The api branch still passes its existing probe: `transport: sdk` +
   `auth.claude.mode: api` resolves `ANTHROPIC_API_KEY` exactly as before.
5. `docs/sdk-verifier.md` failure table matches the implemented behaviour
   row for row.
6. `git diff --stat` on the run branch touches only the three claimed paths.

## Contract test

- **Test file:** None
- **Assertions digest:** None

## Out of scope

- The worker or orchestrator SDK transports (card 28 territory).
- Real-time token surfacing in the TUI or ticker: this card makes the
  transport possible; the display is later work.
- Any codex-family SDK route.
- Minting the token: the operator runs `claude setup-token` once by hand.

## Budget

- **Worker wall-clock:** 3000s
- **Verifier wall-clock:** 2400s

## Verifier handoff

Leave the working tree dirty. Report the route log line or env probe for
criteria 2 and 4, and the exact failure message for criterion 3.

## Family-specific notes

The SDK route is claude-family only. The verifier must not mint or possess
the OAuth token; it checks the route logs and the fail-closed paths from
outside the sandbox.
