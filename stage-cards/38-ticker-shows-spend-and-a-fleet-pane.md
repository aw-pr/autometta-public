# Stage card 38-ticker-shows-spend-and-a-fleet-pane: the operator cannot tell a working loop from a stuck one

## Metadata

- **Authored:** 2026-08-23
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Fable 5 <claude-fable-5@local>
- **Worker effort:** medium
- **Verifier effort:** medium
- **Verifier panel:** false
- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes
- **Pairing rationale:** presentation work over data that already exists, so a
  Codex worker on the cheaper tier is the right call; the verifier's job is to
  check the panels against the underlying files rather than to reason about
  control flow.

## Objective

Card 37 fixes two panels that were wrong. This card fixes what they do not say
at all: an operator looking at the tmux tickers cannot answer "is anything
actually running, and what is it costing me right now".

Three asks, in priority order.

## 1. Token burn on the per-repo ticker

The data already exists and nothing displays it:

- `state/budget.json` — `tokens_spent` against `token_cap_total` for the
  current window, plus `lifetime_tokens_spent`.
- `state/cost-log.jsonl` — one row per dispatched agent with
  `input_tokens`, `cached_input_tokens`, `output_tokens`, `wall_clock_s`,
  `cost_usd_est`, `cache_hit_rate`, `tier`, `auth_route` and `result`.

Add a SPEND panel to `agent-ticker.sh` between ALERTS and ACTIVE:

- window spend as `tokens_spent / token_cap_total` with a percentage, so
  proximity to a halt is visible before it happens;
- today's `cost_usd_est` summed from `cost-log.jsonl`, and the same for the
  last 7 days;
- mean `cache_hit_rate` across today's rows — the prompt-caching work is
  banked and unmonitored, and a collapse in hit rate is the cheapest early
  signal that something regressed;
- rate of burn over the last hour, which is the number that distinguishes a
  running loop from a stalled one at a glance.

Show a spend figure for the ACTIVE rows too. The heartbeat gives elapsed
seconds and log size per live agent; pair each with its running token count
from the same log the reaper parses, so a long-running agent that is silently
producing nothing is visible while it is happening rather than afterwards.

**Constraint:** the ticker refreshes every 5 seconds and must stay read-only
and cheap. Do not re-scan the whole of `cost-log.jsonl` per refresh once it is
large; tail it, or cache a daily rollup keyed on file mtime.

## 2. `autometta-autometta` becomes the fleet summary

Today `scripts/attach.sh` creates one identically-shaped `autometta-<repo>`
tmux session per subscriber, including one for the autometta repo itself. The
autometta session is the least useful of the seven — the control-plane repo's
own stage queue is the thing an operator least often wants — while there is no
single pane that answers "how is the fleet".

Repurpose it. `autometta-autometta` should render a fleet roll-up:

- one row per enabled subscriber: enabled, halted + reason, queue depth,
  window spend against cap, last dispatch age;
- fleet totals for today's spend and token burn;
- the ALERTS union across all repos, so one pane is sufficient to notice a
  halt anywhere.

Much of this exists already in `scripts/status.sh` and
`scripts/aggregate-dashboard.sh`, which walks every subscriber and emits
`~/.phat-controller/dashboard/data.json`. Reuse that aggregation rather than
writing a third walker — the summary pane should be a renderer over
`data.json`, and if that file is stale or missing the pane must say so rather
than render an empty fleet.

Keep the autometta repo's own per-repo view reachable; it becomes a second
window in that session, not the default one.

## 3. Session hygiene

Nothing ever tears a viewer session down. Each holds a `status-ticker`, a
`tail` on a log, and an `agent-ticker` loop, so they cost little, but they
outlive the thing they were watching: on 2026-08-23 seven `autometta-*`
sessions were alive, created on 18, 19 and 22 August, several rendering a
queue that had been empty since they were created, and card 37 explains why
they rendered it as full. That set has since been torn down by hand, which is
the point: by hand is the only way there is.

A second staleness the same day, and the reason this card carries no fixed
subscriber count: a running `agent-ticker.sh` does not pick up edits to its
own script, so the `autometta-autometta` pane went on rendering card 37's
pre-merge panels until it was respawned. Whatever this card changes in that
script, an operator will need to be told to restart the viewer, or attach.sh
will need to do it for them.

Two changes:

- `attach.sh` should reconcile against the enabled subscriber list — create
  sessions for enabled subscribers, and report (not silently keep) an
  `autometta-*` session whose subscriber is disabled or gone.
- Add `autometta detach --all` to tear the viewers down in one command, and
  document the pairing in `MANUAL.md`.

Related, and a **decision for the operator rather than the worker**: the
emergence-lab family has repeatedly had several subscribers enabled at once,
each with its own repo, budget and 400-tick allowance. At the time of writing
`emergence-lab-surface`, `emergence-lab-surface-v2` and `emergence-lab-gpu`
carry the `.disabled` suffix and `emergence-lab` does not, but that has
changed more than once. Surface the overlap in the fleet pane by reading the
registry; do not disable anything as part of this card.

## Inputs (read these in your own context)

- `scripts/agent-ticker.sh` - the per-repo ticker. The SPEND panel goes
  between ALERTS and ACTIVE.
- `scripts/attach.sh` - creates the `autometta-<repo>` viewer sessions.
- `scripts/status.sh`, `scripts/status-ticker.sh` - existing renderers,
  already scoped to one repo by card 33.
- `scripts/aggregate-dashboard.sh` - the fleet walker. Reuse it.
- `~/.phat-controller/dashboard/data.json` - its output, and the fleet pane's
  data source.
- `~/.phat-controller/subscribers/*.yaml` - the subscriber registry. A
  `.disabled` suffix marks a disabled subscriber; read the set, never hardcode
  a count.
- Each subscriber's `state/budget.json` and `state/cost-log.jsonl`, read-only.
- `docs/cost-log.md` - the cost-log schema and the prompt-caching notes.
- `docs/observability.md` - the panel contract, as updated by cards 33 and 37.
- `docs/dashboard.md` - the existing web dashboard, whose `data.json` you are
  consuming.
- `bin/autometta` - subcommand dispatch. `attach` is at line 96; `detach` is
  new.
- `MANUAL.md` - the command table.
- `examples/self-host/37-idle-ticks-consume-the-day.md` - the queue-depth
  definition this builds on, landed in 98673a5.

## Deliverables

- `scripts/agent-ticker.sh` - SPEND panel, per-ACTIVE-row token counts.
- `scripts/attach.sh` - fleet roll-up as the default window of
  `autometta-autometta`, per-repo view as a second window, orphan reporting.
- `bin/autometta` - `detach [--all]`.
- `scripts/aggregate-dashboard.sh` - only if the roll-up needs a field it does
  not already emit.
- `scripts/ticker-spend-smoke.sh` - new. Asserts the panel figures against a
  fixture `cost-log.jsonl` and `budget.json`, and carries the refresh-cost
  measurement criterion 3 asks for.
- `MANUAL.md`, `docs/observability.md` - document both.

## Constraints

- Read-only on every repo, adopter repos included. The ticker must never write
  to a subscriber's `state/`.
- The 5-second refresh must not re-scan the whole of `cost-log.jsonl`. Tail it,
  or cache a daily rollup keyed on file mtime.
- Reuse `aggregate-dashboard.sh`'s walk. A third walker over the subscriber set
  is a defect, not an implementation detail.
- If `data.json` is stale or missing, the pane says so. An empty fleet must
  never render as a healthy one.
- Label `cost_usd_est` as an estimate against list prices. On the subscription
  route the token figures are the load-bearing ones.
- The autometta repo's own per-repo view stays reachable as a second window.
- Do not enable, disable or consolidate any subscriber.
- No new runtime dependencies beyond bash 3.2, jq, yq, tmux and git.
- British English, no em dashes.

## Acceptance criteria

1. The per-repo ticker shows window spend against cap, today's and 7-day
   `cost_usd_est`, mean cache-hit rate, and last-hour burn rate, each matching
   a hand-computed figure from `budget.json` and `cost-log.jsonl`.
2. Each ACTIVE row carries a running token count alongside its elapsed time.
3. A full ticker refresh on the largest current `cost-log.jsonl` costs no more
   wall-clock than the present implementation; state the measured figure.
4. `autometta-autometta` renders the fleet roll-up by default, covering every
   subscriber the registry reports as enabled at the time it runs, and says so
   plainly when `data.json` is stale.
5. The autometta repo's own per-repo view is still reachable in that session.
6. `attach.sh` reports orphaned sessions; `autometta detach --all` removes the
   viewers; both are documented in `MANUAL.md`.
7. Every panel remains read-only on adopter repos.

## Out of scope

- Consolidating the emergence-lab subscribers. Surface the overlap in the
  fleet pane; the decision is the operator's.
- Changing any cap or budget value.
- The web dashboard under `dashboard/`. Only its `data.json` is consumed.
- The queue-depth definition itself. That is card 37, landed.
- Anything `tick.sh` dispatches, or how it dispatches it.
- tmux sessions that are not `autometta-<repo>` viewers.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes

## Notes for the worker

- Land card 37 first. Its `list-cards.sh` change alters what "queue depth"
  means, and building the fleet pane on the current definition would bake the
  wrong number into a second place.
- `cost_usd_est` on the subscription auth route is an estimate against list
  prices, not a bill. Label it as an estimate in the panel; the operator's real
  constraint is subscription quota, not dollars, so the token figures are the
  load-bearing ones and the dollar figure is context.
