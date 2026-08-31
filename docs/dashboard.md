# Cost dashboard

`autometta dashboard` regenerates a static, offline-renderable HTML
dashboard that visualises token spend and stage activity across every
subscribed repo. There is no daemon. The page is regenerated on demand, or on
an interval with `--watch` / `--serve` for a live view; while
the fleet tmux viewer exists, a separate refresh job also regenerates the data
snapshot every 120 seconds. The fleet ticker remains a read-only renderer and
never walks subscriber repos.

The HTML dashboard is one consumer of the aggregate, not a separate data
path. The repo and fleet tickers, and the full-screen `autometta tui`, read the
same payload from `scripts/aggregate-dashboard.sh`; `--repo <path>` narrows it
to the subscriber those terminal surfaces display.

## Subcommand

```
autometta dashboard                    # regenerate the fleet page
autometta dashboard --open             # regenerate and open in default browser
autometta dashboard --repo <path>      # the same page scoped to one subscriber
autometta dashboard --watch            # regenerate every 5s until interrupted
autometta dashboard --serve --open     # live view: regenerate, serve, and open it
```

`--repo` narrows the walk to one subscriber and writes the pair to
`<controller home>/dashboard/repos/<name>/`, never inside the repo it reports
on. It is the same document over a single-entry `repos[]`, so there is one
renderer rather than a second page to keep in step: the page hides the repo
filter and retitles itself, and nothing else differs.

## Reading the page

The header carries two controls. The repo filter narrows every panel, total and
chart to the repos ticked; it is drawn only on the fleet page. The range control
(24h/7d/30d/all) slices the token charts by stage date, and is remembered per
viewer.

Per stage, Failures and Provider windows page at ten rows, with a per-table size
control; the default comes from `AUTOMETTA_DASHBOARD_PAGE_SIZE` at generation
time. Per stage is grouped by repo and ordered by queue time, newest first.

Clicking a Per stage row, or a bar in the stage chart, expands the stage card
that drove it. Card text travels in the payload because a `file://` page cannot
fetch a sibling file; `scripts/attach-card-text.py` attaches it inside the
aggregator's write path, capped at 400 lines.

A stage records its own token totals when it completes, so one that stalled
reports zero. The table and charts fall back to the cost log for those, and mark
the recovered figures with an asterisk.

The dashboard files live at `~/.autometta/dashboard/`:

- `data.json` - aggregated state from all subscribers
- `data.js` - the same object assigned to `window.AUTOMETTA_DATA` for `file://`
- `index.html` - page entry point
- `dashboard.js` - vanilla JS renderer
- `dashboard.css` - dark theme
- `vendor/chart.min.js` - Chart.js 4.4.0, vendored at install time

No external network access happens at render time. Chart.js is fetched
once at install time (`scripts/install-homebrew-local.sh`) with a pinned
SHA256 hash; a mismatch fails the install loudly.

## Regeneration model

`scripts/dashboard.sh`:

1. Runs `scripts/aggregate-dashboard.sh`, which walks
   `~/.autometta/subscribers/*.yaml` (excluding `template.yaml`),
   reads each repo's state, agent registry, heartbeat and cost log, and emits
   fresh `data.json` and `data.js` siblings. A broken `state.yaml` produces a
   red `state_error` row without stopping other subscribers from rendering.
2. Copies the static assets (`index.html`, `dashboard.js`,
   `dashboard.css`, `vendor/chart.min.js`) from the autometta install
   into `~/.autometta/dashboard/`.
3. With `--open`, launches the local file via `open` (macOS) or
   `xdg-open` (linux).
4. With `--watch`, repeats step 1 every `--interval` seconds (default 5) until
   interrupted. Step 2 is not repeated: the assets are already in place, and
   recopying them under a reading browser buys nothing.
5. With `--serve` (which implies `--watch`), binds a `python3 -m http.server`
   to `127.0.0.1:<port>` over the dashboard directory first, and reports that
   URL instead of the `file://` one.

Both are foreground processes that end with the terminal, in the same shape as
`autometta tui`. Nothing supervises them and nothing restarts them, so this is
not the daemon the design rules out: stop the process and the page simply goes
back to being the snapshot it was.

## Live updates

The page polls for new data every five seconds and re-renders only when
`generated_at` has moved, so a poll against an unchanged file costs one read
and no repaint. A freshness marker sits beside the generated-at stamp: green
while reads are landing, amber once three consecutive reads have failed, which
is what distinguishes a dashboard nobody is regenerating from a genuinely quiet
fleet. Open expander rows are held in renderer state rather than in the DOM, so
a poll does not close a stage card mid-read.

Polling needs something to poll. The page re-reading a file no one is
rewriting is the default arrangement and stays a snapshot; `--watch` is the
half that makes it live.

The TUI polls the per-repo seam every five seconds. Card 74 changed the
aggregator from repeated per-row forks and file scans to set-based passes over
the same inputs, reducing the measured `--repo` call on this repo from 37
seconds to under one second without changing the payload. That speedup is why
the five-second poll is an honest refresh interval rather than a backlog of
old snapshots.

Every commit-on-PASS records worker and verifier token counts onto the matching
stage entry in `state.yaml`. The next aggregator run surfaces those snapshots
in `data.json`; the tick itself does not walk the fleet.

### Live figures

SDK verifiers write cumulative `live_input_tokens`, `live_output_tokens` and
`live_updated_at` into their own `state/active-agents/<pid>.json` registry
entry as usage arrives. The aggregator copies those fields to an in-flight
agent's `live_usage` object in `data.json`; it omits that object when the
registry has no SDK figure. The dashboard labels a present value `LIVE` and
shows `n/a` for a CLI dispatch, rather than treating absence as zero.

Latency is bounded by the SDK usage message, the registry's atomic rename, the
next seam regeneration, and the page poll. `--watch` and `--serve` regenerate
the dashboard every five seconds by default; the fleet snapshot job defaults
to 120 seconds; the TUI reads the per-repo seam every five seconds. A missing
or stale registry timestamp only weakens the display. Settled accounting stays
in `state/cost-log.jsonl`, so live figures are never added to billing totals or
counted again when the dispatch lands.

`autometta attach /path/to/autometta` starts one background refresh job in the
tmux session. Override its 120-second interval with
`AUTOMETTA_FLEET_REFRESH_INTERVAL`. The fleet pane prints the exact
`generated_at` age, and retains the stale warning after
`AUTOMETTA_FLEET_STALE_SECONDS` (default 600).

## Fleet pane

Card 66 applied card 63's discipline (one repo, fits its pane) one level up:
the fleet pane now carries only what an operator acts on. It opens with one
TOTALS line (enabled repos, today's spend, window spend against cap), then
REPOS -- one row per subscriber: name, operational state (`HALTED: <reason>`,
`STALLED: <stage>`, `PAUSED: <reason>`, `running <stage>`, `queued <stage>` or
`idle`), queue depth, today's spend and window spend against cap -- then
ESCALATIONS: every halted, paused, attempt-capped or stale-vendor repo, every
stage in an alert status, every over-budget live agent and every alert younger
than 24 hours, one row each, with a repo, result, stage, role and agent
identity that render whole and a trailing detail column that carries the
ellipsis budget. A repo with nothing outstanding earns no ESCALATIONS row.
The itemised failures list and the per-role spend breakdown moved to
`scripts/failures-history.sh --fleet` (`autometta failures --fleet`), the
fleet-wide sibling of the per-repo command card 63 shipped -- it is reachable
on demand and reads the same aggregated JSON, so it never disagrees with the
live pane. An active drain is named in the header with its effective cap and
expiry.

The renderer is `scripts/lib/fleet-ticker-render.py`, the sibling of
`scripts/lib/repo-ticker-render.py` (card 63) one level up: it reuses the same
column-allocation algorithm, ANSI-safe `fit`/`pad` helpers and short-token
formatting rather than reimplementing them, reads only the already-aggregated
JSON `attach.sh` hands it, and truncates with an ellipsis only in a row's
trailing detail column -- repo names, stage ids, `role`, `result` and agent
identities render whole at 119 columns and wider. `attach.sh` gathers the
JSON (the shared `dashboard/data.json` fleet-wide, or a single repo object
from `aggregate-dashboard.sh --repo` when scoped) and calls the renderer once
per frame; neither reads a subscriber's `state.yaml`, `budget.json` or
`cost-log.jsonl` directly.

The per-repo viewer session's window 0 renders this same page scoped to one
repo (TOTALS and ESCALATIONS for that repo, no REPOS table -- the other rows
are the fleet view's business, not that page's subject). The fleet-wide page
stays reachable as its own tmux window (`fleet`), never the landing view: an
operator attached to one repo's session rarely wants every subscriber.

## Traffic-light rules

Worst condition wins. `FLEET_FRESH_FAILURE_HOURS` defaults to 24.

**RED** (broken, needs a person now):

- `budget.json .halted == true`
- `.consecutive_failures >= .consecutive_failure_cap`
- any heartbeat entry with flag `over-budget`
- any stage in the `alert-statuses.sh` set whose timestamp
  (`completed_at`, else `started_at`, else the verifier artefact mtime) is
  younger than `FLEET_FRESH_FAILURE_HOURS` (default 24)
- repo's `state.yaml` unreadable or unparseable (render the row as
  `state unreadable`, never drop it - today this case kills the aggregator)

**AMBER** (degraded or noteworthy, no action forced):

- `0 < consecutive_failures < cap`
- genuine provider-limit detection in the last 24h (post card 49's banner
  anchoring)
- `tokens_spent / token_cap_total >= 0.85`
- alert-status stages older than the 24h freshness bound (real, but history)
- drain in force covering this repo
- heartbeat `checked_at` older than 600s while stages are in flight

**GREEN**: none of the above.

`data.json` still carries `light` and `light_reason` per repo -- the web view
below reads them for its traffic-light marks (`●`/`◐`/`○` with colour,
`ok`/`WARN`/`FAIL` under `NO_COLOR`). The text-mode fleet pane (previous
section) does not repeat them: its REPOS state column and ESCALATIONS table
already say `HALTED`, `STALLED`, `PAUSED`, `vendor-stale`, `over-budget` or
`provider-limit` in words, so a colour-only signal is never the only one.

## Web view

The browser renders the same lights, agents, queue, failures and spend fields
as the fleet pane. Over HTTP it fetches `data.json`. `autometta dashboard
--open` uses a plain `file://` URL, so `index.html` loads `data.js` first and
the renderer uses `window.AUTOMETTA_DATA` when `fetch` is unavailable. The two
files are emitted from one assembled object by the aggregator; `data.js` is
not a second walker.

The same split governs how the poll re-reads. Served over http it is an
ordinary no-store fetch. On a `file://` origin fetch is blocked by the opaque
file origin, so the poll re-injects `data.js` with a cache-busting query and
reads `window.AUTOMETTA_DATA` again. That path depends on the browser honouring
a query string on a file URL; where it does not, `generated_at` never advances
and the page reads "unchanged" indefinitely, which looks exactly like an idle
fleet. The freshness marker therefore names the transport it is on, and
`--serve` exists to avoid the question entirely.

## Four breakdowns

1. **Per repo.** One card per subscriber: tokens spent, token cap,
   stage count, and a halt indicator if applicable. Mirrored as a bar
   chart of tokens-spent per repo.
2. **Per stage.** Table of every stage across every repo with status,
   worker / verifier identity, per-stage worker / verifier / total
   token counts, and completion timestamp. Mirrored as a bar chart of
   per-stage totals. The status chip shows the stage's `phase`: an
   in-progress stage reads `working` while its worker pid is live and
   `verifying` while its verifier pid is, derived by the seam from
   `state.yaml`; every other status renders as itself. `status` stays
   the loop's raw contract; `phase` is display only.
3. **Per model.** Token spend grouped by canonical agent identity
   (e.g. `Claude Opus 4.8 <claude-opus-4-8@local>`,
   `GPT-5.6 Sol <gpt-5-6-sol@local>`,
   `Claude Sonnet 4.6 <claude-sonnet-4-6@local>`) per
   `~/.claude/rules/mcp-hub-dev-rules.md`. Orchestrator identity is
   read from each stage card's metadata; worker / verifier identity is
   read from `state.yaml`.
4. **Per day.** UTC daily token rollup, drawn as a line chart of
   tokens-per-day.

## Schema

`data.json` shape (excerpt):

```jsonc
{
  "generated_at": "2026-05-26T20:00:00Z",
  "repos": [
    {
      "name": "emergence-lab",
      "repo_path": "/Users/.../emergence-lab",
      "enabled": true,
      "tokens_spent": 0,
      "token_cap_total": 1000000,
      "halted": false,
      "halt_reason": null,
      "today_tokens": 12345678,
      "today_cost_usd_est": 3.455,
      "seven_day_cost_usd_est": 12.34,
      "last_hour_tokens": 456789,
      "last_dispatch_at": "...",
      "state_error": null,
      "light": "green",
      "light_reason": "no dashboard rule fired",
      "drain_active": false,
      "drain_cap": null,
      "drain_expires_at": null,
      "heartbeat_checked_at": "...",
      "agents": [
        {
          "pid": 12345,
          "stage_id": "49-fleet-pane",
          "role": "worker",
          "family": "codex",
          "identity": "GPT-5.6 Sol <gpt-5-6-sol@local>",
          "started_at": "...",
          "elapsed_seconds": 120,
          "elapsed": 120,
          "budget_seconds": 5400,
          "flags": []
        }
      ],
      "queue": [
        {
          "stage_id": "50-next-stage",
          "worker": "GPT-5.6 Sol <gpt-5-6-sol@local>",
          "verifier": "Claude Sonnet 5 <claude-sonnet-5@local>"
        }
      ],
      "spend": {
        "scope": "today_utc",
        "input_tokens": 1000,
        "cached_input_tokens": 8000,
        "output_tokens": 500,
        "tokens_total": 9500,
        "cost_usd_est": 0.12,
        "productive": {"tokens": 7000, "cost_usd_est": 0.08},
        "lost": {"tokens": 2500, "cost_usd_est": 0.04},
        "by_role": [],
        "failures": []
      },
      "stages": [
        {
          "id": "01-...",
          "status": "completed",
          "phase": "completed",
          "worker": "GPT-5.6 Sol <gpt-5-6-sol@local>",
          "verifier": "Claude Sonnet 4.6 <claude-sonnet-4-6@local>",
          "orchestrator": "Claude Opus 4.8 <claude-opus-4-8@local>",
          "started_at": "...",
          "completed_at": "...",
          "tokens": 142672,
          "worker_tokens": 117339,
          "verifier_tokens": 25333,
          "verifier_overall": "PASS"
        }
      ]
    }
  ],
  "drain_active": false,
  "drain_cap": null,
  "drain_expires_at": null,
  "drain": {"active": false, "cap": null, "expires_at": null, "repos": []},
  "spend": {
    "scope": "today_utc",
    "input_tokens": 1000,
    "cached_input_tokens": 8000,
    "output_tokens": 500,
    "tokens_total": 9500,
    "cost_usd_est": 0.12,
    "productive": {"tokens": 7000, "cost_usd_est": 0.08},
    "lost": {"tokens": 2500, "cost_usd_est": 0.04},
    "by_repo_role": [],
    "failures": [
      {"repo": "emergence-lab", "stage_id": "48-example", "role": "worker", "result": "fail", "tokens_lost": 2500}
    ]
  },
  "by_model": [{"identity": "...", "tokens": 0}],
  "by_day":   [{"date": "2026-05-26", "tokens": 0}]
}
```

The per-stage `tokens` / `worker_tokens` / `verifier_tokens` fields are
**additive**: older `state.yaml` files without them parse to `0` /
`null` and continue to render.

`agents` is the live registration joined to the matching heartbeat row by
PID. `queue` preserves `state.yaml` order and includes pending stages only.
Per-repo `spend` and top-level `spend.by_repo_role` cover the current UTC day,
which is why `spend.tokens_total` reconciles with `fleet_totals.today_tokens`.
`spend.failures` uses a seven-day window and treats every result other than
`pass` as lost. Each failure retains the three token buckets and their sum in
`tokens_lost`. The top-level `drain` object summarises enabled repos whose
per-repo drain fields are active.

The fleet pane shortens token counts for scanning and rounds estimated USD to
two decimal places. The exact token and cost values remain in `data.json`.
