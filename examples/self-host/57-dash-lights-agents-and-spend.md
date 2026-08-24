# Stage card 57: the dash shows its lights, its agents, and its spend

## Metadata

- **Authored:** 2026-08-24
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Verifier:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Base branch:** dev
- **Run branch:** autometta/57-dash-lights-agents-and-spend
- **Worker effort:** high
- **Verifier effort:** medium
- **Verifier panel:** false
- **Pairing rationale:** a wide presentation card spanning shell renderers,
  a jq aggregation seam, and the web dashboard's JS; Claude works the
  breadth, Codex verifies cross-family against fixtures where the failure
  mode is a light or a number that reads plausibly but derives from the
  wrong field.

## Objective

Card 49 landed the fleet pane's sections. The design review at
`docs/proposals/tmux-dash-review.md` takes the next step: a per-repo
traffic light with testable rules, live conditions split from history,
an aggregator that survives one broken subscriber, and the drain made
visible. This card implements that review plus the operator's additions
of 2026-08-24:

- **Agents, deployed and queued.** The operator watching the pane cannot
  currently see who is working: which agent is live, on which card, in
  which role, under which model identity, how long it has run against its
  budget. Nor what comes next: the queued stages and the worker and
  verifier models they are targeted for. Both lists exist in state
  (`state/active-agents/`, heartbeat, `state.yaml` stage entries) and
  reach no renderer.
- **Failures and the tokens they burned.** A failed, stalled, or aborted
  attempt spends real tokens (`state/cost-log.jsonl` carries a `result`
  field per dispatch). Show the failures with their tokens lost, and the
  sum, so the cost of requeues is a number rather than a feeling.
- **Where all the tokens went.** One summary table rolling up
  `cost-log.jsonl`: by repo and role, tokens in / cached / out, estimated
  cost, split visible between productive (pass) and lost (everything
  else) spend. It must reconcile with the TOTALS line.
- **The web dashboard is in scope.** The review scoped it out; the
  operator scopes it back in. `dashboard/` renders from `data.json`
  alone, so every new fact the pane gains must land in `data.json` and
  the web view renders the same lights, agents, failures, and spend from
  it. No new walkers in the browser or anywhere else.

This is a prototype: function and correct derivation over polish. A
plain table that shows the right number beats a styled one that walks
the repos itself.

## Inputs (read these in your own context)

- `docs/proposals/tmux-dash-review.md` — the design: light rules table,
  ATTENTION/HISTORY split, mockup, implementation path. Follow it unless
  it conflicts with this card; this card wins.
- `scripts/attach.sh` (`render_fleet_once`, `fleet_style_init`) — the
  fleet renderer card 49 restructured.
- `scripts/aggregate-dashboard.sh` — the one walker; everything new
  flows through its `data.json`.
- `scripts/agent-ticker.sh`, `scripts/repo-ticker-proto.py` — the
  correct paint/fit/NO_COLOR pattern lives in the proto.
- `state/active-agents/` schema via `scripts/register-agent.sh`;
  `state/heartbeat.json` via `scripts/heartbeat.sh`.
- `docs/cost-log.md` — the cost-log schema, including `result` and the
  cached/uncached token fields.
- `dashboard/dashboard.js`, `dashboard/index.html` — the web consumer.
- `scripts/budget.sh` (`budget_drain_active`, `budget_effective_token_cap`).

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/repo-light.sh` — one function mapping a repo's `data.json`
   entry to `green|amber|red` plus a reason string naming the rule that
   fired; the rules table from the review, every input a field that
   exists today; sourced by the fleet renderer and usable by `status.sh`.
2. `scripts/aggregate-dashboard.sh` — per-subscriber failure isolation
   (an unreadable `state.yaml` yields a `state_error` entry and the run
   still writes `data.json` for the rest); drain fields
   (`drain_active`, `drain_cap`, `drain_expires_at`); per-alert
   timestamps; an `agents` array (live registrations joined with
   heartbeat: pid, role, family, identity, stage id, started_at,
   elapsed, budget_seconds); a `queue` array per repo (pending stages in
   dispatch order with their worker and verifier identities); a `spend`
   rollup from `cost-log.jsonl` (by repo and role: tokens in / cached /
   out, `cost_usd_est`, split by pass versus non-pass results, plus each
   non-pass dispatch itemised with its stage, role, result, and tokens).
3. `render_fleet_once` in `scripts/attach.sh` — the light glyph column;
   ATTENTION (live, recomputed, empty renders one quiet line) and
   HISTORY (7d, newest first, max 8 rows, aged) replacing the single
   ALERTS union; DRAIN banner while in force; an AGENTS section (one
   line per live agent: light-adjacent glyph, stage, role, model
   identity, elapsed against budget; then the next queued stages with
   their targeted worker and verifier models); a FAILURES view showing
   each recent non-pass dispatch with its tokens lost and the sum; a
   SPEND summary table; a single TOTALS that the spend table reconciles
   with.
4. `dashboard/dashboard.js` (and `index.html` as needed) — the same
   lights, agents, queue, failures, and spend rendered from `data.json`
   alone. Fix the standing breakage first: `autometta dashboard --open`
   opens the page as `file://`, where Chrome refuses `fetch("data.json")`
   and the page dies with "Failed to load data.json". Have the
   aggregator emit a `data.js` sibling (`window.AUTOMETTA_DATA = <the
   same object>;`) next to `data.json`, include it from `index.html`,
   and fall back to it when fetch fails, so the page renders opened
   straight from disk with no server. `data.js` is the same seam, not a
   second walker.
5. `scripts/fleet-lights-smoke.sh` — fixtures per light rule and per new
   section, colour and `NO_COLOR` captures, locale pinned both ways (the
   card 49 lesson: `LC_ALL` UTF-8 for the box-drawing capture, `LC_ALL=C`
   for the ASCII one).
6. `docs/dashboard.md` — the rule table verbatim, plus the `data.json`
   schema for `agents`, `queue`, `spend`, and the drain fields.

## Contract test

- **Test file:** None
- **Assertions digest:** None

## Acceptance criteria

1. Against a fixture fleet holding one halted repo, one over-85%-cap
   repo, one repo with a 3-day-old verifier_failed, one idle-clean repo,
   and one whose `state.yaml` is truncated mid-block, the lights read
   red, amber, amber, green, red respectively, and each reason string
   names the rule that fired.
2. The truncated-state fixture still yields a `data.json` naming every
   other repo, and the pane renders the broken repo as a red
   `state unreadable` row rather than a stale frame.
3. With a fixture `drain.json` in force the header names the lifted cap
   and expiry; with it expired or absent, no banner.
4. A condition cleared between two renders leaves ATTENTION on the
   second render; a 6-day-old failure appears in HISTORY with its age
   and not in ATTENTION.
5. AGENTS: a fixture with one live registration renders the stage id,
   role, model identity, and elapsed against budget on one line; the
   queued list beneath names the next pending stages with the worker
   and verifier identities from `state.yaml`, in dispatch order.
6. FAILURES: a fixture cost-log holding one `fail`, one `aborted`, and
   one `stalled` dispatch shows each with its stage, role, and tokens
   lost, and the sum of tokens lost matches the fixture.
7. SPEND: the summary table derives only from the fixture
   `cost-log.jsonl`, its total equals the TOTALS line's today figure,
   the repo-and-role split is visible, and cached versus uncached input
   tokens are distinguishable.
8. The web dashboard, opened against the fixture `data.json`, shows the
   same lights, agents, queue, failures, and spend figures with no
   fetch beyond `data.json`; opened as a plain `file://` page with
   fetch unavailable it renders identically from the emitted `data.js`
   fallback rather than the failure banner.
9. No rendered pane line exceeds 80 or 120 columns in the respective
   captures; TOTALS appears exactly once per frame; with colour
   available the three lights are visibly distinct and with `NO_COLOR=1`
   the same frame carries `ok/WARN/FAIL` text; both captured with the
   locale pinned.
10. `fleet-lights-smoke.sh` passes and every existing offline smoke
    still passes; `sdk-cache-smoke.sh` needs live credentials and is not
    run: say so.

## Out of scope

- The per-repo tickers (card 44) and scanner anchoring (card 49, landed).
- Writing to any subscriber repo.
- Historic cost-log backfill or schema migration; render what the log
  already holds.

## Budget

- **Worker wall-clock:** 90 minutes
- **Verifier wall-clock:** 30 minutes

## Verifier handoff

Return the light verdict per fixture repo with the rule each reason
named, the AGENTS and queued lines as rendered, the tokens-lost sum
against the fixture's expected value, the spend-table total against the
TOTALS line, and the web dashboard's figures against the same fixture.

## Family-specific notes

None
