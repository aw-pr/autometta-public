# Stage card 51: the docs catch up with the free verifier pattern, once it has one

## Metadata

- **Authored:** 2026-08-24
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Verifier:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Base branch:** dev
- **Run branch:** autometta/51-docs-catch-up-with-the-free-verifier-pattern
- **Worker effort:** medium
- **Verifier effort:** medium
- **Verifier panel:** false
- **Pairing rationale:** prose over settled facts, the Claude side's ground;
  Codex verifies cross-family that every documented claim matches what the
  scripts and the bake-off artefacts actually say, since docs drift is a
  claim-by-claim check, not a style one.

## Objective

Cards 45 and 46 changed what verification costs: a zero-cost local tier on
Ollama weights, two keyed free cloud routes, and a measured verdict on
which of them to trust for what. The docs still describe the two-route
world (subscription, api) with today's additions bolted on piecemeal.

Write the docs the pattern deserves, once, from the measurements. This card
is **gated**: do not dispatch it until card 46 is `completed` and
`docs/verifier-bake-off.md` carries its recommendation. Documenting the
experiment before its result would fix in prose exactly the guesses the
bake-off exists to replace.

## Inputs (read these in your own context)

- `docs/verifier-bake-off.md` and the artefacts under `examples/bake-off/`
  once card 46 lands: the measured recommendation is the source of truth
  for every claim about which model to trust and for what.
- Card 45's landed deliverables: `scripts/auth-route.sh` (the `local`
  mode), `scripts/models.sh` (`AUTOMETTA_MODEL_CODEX_LOCAL`),
  `scripts/rates.sh` (the zero tier), `docs/setup.md` section 7.
- `README.md` "Billing routes", including the "Three files, one of them
  live" op-refs subsection (97bc1b9); extend, do not restate.
- `MANUAL.md`, `docs/cost-log.md`, `docs/sdk-verifier.md`.
- `skills/autometta-setup/SKILL.md`: what an adopting repo needs to know
  about choosing a verification tier.
- `~/.claude/rules/mcp-hub-dev-rules.md` identity table for the local
  identity's canonical string; reference it, never paste it as a literal
  into any script or skill.

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `README.md` — the billing-routes story told as three tiers
   (subscription, api, free: local and cloud), with the bake-off's
   recommendation summarised in one table: which verifier tier for which
   kind of stage, and what stays frontier-only. Link to
   `docs/verifier-bake-off.md` for the evidence.
2. `docs/setup.md` — section 7 covers standing up the free tiers end to
   end: the Ollama one-time setup, the two free-route keys with the
   op-refs three-file layout, the route-isolation guarantee, and the
   dispatch-time overrides. One runbook, no forward references to cards.
3. `MANUAL.md` — the operator-facing quick reference: how to flip a repo's
   verification onto the free tier, how to read a local dispatch in the
   cost log (tier, zero estimate, real tokens), and how to tell which
   route a running verifier is on.
4. `skills/autometta-setup/SKILL.md` — adopting repos get the tier choice
   documented with the same recommendation table, so a new subscriber
   starts from the measured default rather than folklore.
5. Any statement in the touched docs contradicted by the landed scripts or
   the bake-off results is corrected, not worked around; list each such
   correction in the handoff.

## Constraints

- **Gate: card 46 completed first.** If dispatched early, the worker must
  halt with a note naming the gate rather than writing speculative prose.
- Every model-quality claim traces to `docs/verifier-bake-off.md` or a
  checked-in artefact; no claim rests on the card 45/46 authoring-time
  guesses that the bake-off has since replaced or confirmed.
- No behaviour changes. Prose, tables and links only; scripts are inputs.
- The version history table (repo-publish-docs-review convention) gains an
  entry if the README carries one; follow the repo's existing convention
  either way.
- British English, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

1. README's billing routes read as three tiers with the recommendation
   table present, and every row of that table matches
   `docs/verifier-bake-off.md`.
2. `docs/setup.md` section 7 stands alone: an operator on a fresh machine
   can reach a working free-tier verifier from it without opening a stage
   card.
3. MANUAL.md answers the three operator questions in deliverable 3, each
   verifiable against a real or fixture cost-log line and manifest.
4. The setup skill's tier guidance matches the README table word for
   word or by reference, not by a third restatement.
5. No touched doc contradicts a landed script's actual behaviour; the
   verifier spot-checks at least the auth-route modes, the local model
   knob, and the zero-cost tier name against the scripts.
6. `bash -n` on any shell file touched (none expected); no file outside
   the deliverables is modified except this card.

## Contract test

- **Test file:** None
- **Assertions digest:** None

## Out of scope

- Changing any route, rate, or model default; this card documents.
- The bake-off doc itself, which card 46 owns.
- Docs for cards not yet landed (47 to 50); each carries its own docs
  deliverable.
- The public mirror publish; the operator decides when `publish` advances.

## Budget

- **Worker wall-clock:** 60 minutes
- **Verifier wall-clock:** 30 minutes

## Verifier handoff

Return the recommendation table as shipped with a citation per row into
the bake-off doc, the fresh-machine walkthrough evidence for setup.md, the
three MANUAL.md answers with their verification, and the list of corrected
contradictions from deliverable 5.

## Family-specific notes

None
