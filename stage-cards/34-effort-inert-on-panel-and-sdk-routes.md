# Stage card 34-effort-inert-on-panel-and-sdk-routes: two verifier routes ignore a declared effort

## Metadata

- **Authored:** 2026-08-16
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Fable 5 <claude-fable-5@local>
- **Worker effort:** high
- **Verifier effort:** medium
- **Verifier panel:** false
- **Pairing rationale:** cross-family. Codex worker on the CLI-argument
  surface it knows best; Claude verifier checks the panel and SDK routes
  independently.

## Objective

A card's `Verifier effort` reaches the CLI on exactly one of the three verifier
routes. `spawn-verifier-panel.sh` never reads the field at all, and the SDK
transport in `spawn-verifier.sh` has no argument to pass it to. Both accept the
declaration and discard it silently.

Make a declared effort either take effect or fail loudly.

## Reported by

Found on 2026-08-14 while fixing card 30 (effort flags collapsing into one argv
element). That card fixed delivery on the CLI route and explicitly left these
two alone. `grep -n effort scripts/spawn-verifier-panel.sh` returns nothing —
the panel script reads no effort field of any kind, so a panel card's
`Verifier effort` has never had any effect since the field was introduced.

The SDK case is at least already admitted at the call site
(`scripts/spawn-verifier.sh`, the sdk branch):

> No effort override here: the sdk verifier takes --model but has no effort
> argument, so a card's "Verifier effort" is silently inert on this transport.

An honest comment is better than nothing, but a card author reading
`templates/stage-card.md` has no way to know their declaration will be dropped,
and the dispatch log says nothing either.

## Why it matters more than it looks

The panel route is the expensive one — N verifiers per stage. It is exactly
where a card author is most likely to reach for a high effort setting, and the
only route that guarantees they will not get it. The cost is paid, the effort
is not delivered, and the log claims the card's value either way because
`spawn-worker.sh` logs the *card's* effort, not what the CLI accepted.

## Inputs (read these in your own context)

- scripts/spawn-verifier-panel.sh — the whole dispatch path; it reads no effort
- scripts/spawn-verifier.sh — the sdk branch and its existing comment
- scripts/models.sh — `effort_argv_for_family` and `AUTOMETTA_EFFORT_ARGV`,
  the mechanism card 30 established
- scripts/verify-sdk.py — whether the SDK exposes an effort/thinking parameter
  at all on the current SDK version; this is a question to answer, not assume
- scripts/effort-flags-smoke.sh — the existing argv-capture test to extend
- templates/stage-card.md — where the field is documented to card authors
- docs/verifier-panel.md and docs/sdk-verifier.md — the route docs

## Deliverables

1. Panel route: honour `Verifier effort` per panel member, using the same
   `AUTOMETTA_EFFORT_ARGV` mechanism as the CLI route rather than a second
   implementation.
2. SDK route: determine whether the Agent SDK exposes an effort or
   thinking-budget parameter on the version pinned in
   `scripts/requirements-sdk.txt`. If it does, pass it. If it does not, fail
   the dispatch closed with a clear message rather than running at an unknown
   effort while the card says otherwise — a declared effort that cannot be
   honoured is a card the operator should be told about, not one that quietly
   runs cheaper.
3. Extend `scripts/effort-flags-smoke.sh` to cover both routes, asserting on
   constructed argv as it already does for the CLI route. It must fail against
   the pre-fix commit.
4. Say plainly in `templates/stage-card.md` which routes honour the field.

## Constraints

- Do not duplicate the argv construction. One helper, three call sites.
- Do not regress card 30's fix or its smoke.
- A card with no effort declared must keep dispatching unchanged on all three
  routes.
- If the SDK genuinely cannot take an effort, do not fake it by switching that
  card to the CLI transport behind the operator's back.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. The repo's own acceptance suite is green.
2. A panel card declaring `Verifier effort: high` passes the effort to every
   panel member as separate argv elements.
3. The SDK route either passes the effort or refuses the dispatch with a
   message naming the card field and the reason.
4. The extended smoke fails against the pre-fix commit. Check it out, run it,
   state the failure.
5. Cards declaring no effort still dispatch on all three routes.
6. `templates/stage-card.md` states the per-route behaviour.

## Contract test

- **Test file:** `scripts/effort-flags-smoke.sh` (extended)
- **Assertions digest:** <<fill at dispatch>>

## Out of scope

- Worker-side effort, fixed in card 30.
- Changing the effort vocabulary in `AUTOMETTA_EFFORT_LEVELS`.
- Whether the panel should exist, or its quorum rules.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes

## Verifier handoff

Worker reports: how the panel route now builds its argv and that it reuses the
existing helper; what the pinned SDK version does or does not expose, with the
evidence; which behaviour was chosen for the SDK route and why; and the smoke's
failure output against the pre-fix commit.

## Family-specific notes

The SDK question is answerable from the installed package and its typing rather
than from documentation or memory. Check the version actually pinned, not the
latest release.
