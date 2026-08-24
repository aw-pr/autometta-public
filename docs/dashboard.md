# Cost dashboard

`autometta dashboard` regenerates a static, offline-renderable HTML
dashboard that visualises token spend and stage activity across every
subscribed repo. There is no daemon. The page is regenerated on demand; while
the fleet tmux viewer exists, a separate refresh job also regenerates the data
snapshot every 120 seconds. The fleet ticker remains a read-only renderer and
never walks subscriber repos.

## Subcommand

```
autometta dashboard           # regenerate only
autometta dashboard --open    # regenerate and open in default browser
```

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

Every commit-on-PASS records worker and verifier token counts onto the matching
stage entry in `state.yaml`. The next aggregator run surfaces those snapshots
in `data.json`; the tick itself does not walk the fleet.

`autometta attach /path/to/autometta` starts one background refresh job in the
tmux session. Override its 120-second interval with
`AUTOMETTA_FLEET_REFRESH_INTERVAL`. The fleet pane prints the exact
`generated_at` age, and retains the stale warning after
`AUTOMETTA_FLEET_STALE_SECONDS` (default 600). Set
`AUTOMETTA_FLEET_ABSOLUTE_TIME=true` when the absolute ISO timestamp is
needed alongside the relative age.

## Fleet pane

The fleet pane starts with one TOTALS line and one traffic-light row per repo.
ATTENTION is recomputed from current conditions. HISTORY is a seven-day event
view, newest first and capped at eight rows. AGENTS shows live registrations,
then pending stages with their intended worker and verifier. FAILURES itemises
non-pass cost-log rows and their token loss. SPEND splits fresh input, cached
input and output by repo and role; its token total is the TOTALS today figure.
An active drain is named in the header with its effective cap and expiry.

All tabular sections use one pane-width-aware renderer. Cells are truncated
with an ellipsis before a row can wrap, numeric columns are right-aligned, and
important states are emphasised. Colour-capable UTF-8 terminals use box-drawing
borders and state colours. `NO_COLOR=1`, a non-UTF-8 locale, or a terminal
without colour capabilities selects readable ASCII borders and plain text.
The renderer retains per-line erase-to-end repainting in the live ticker.

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

**GREEN**: none of the above. Sub-states shown in the state column are
`run <stage>` when work is in flight, `queued <stage>` when pending work waits,
and `idle` when the queue is empty.

With colour enabled the marks are `●`, `◐`, and `○`. With `NO_COLOR=1` or
`NO_COLOUR=1`, they are `ok`, `WARN`, and `FAIL`, so colour is never the only
signal.

## Web view

The browser renders the same lights, agents, queue, failures and spend fields
as the fleet pane. Over HTTP it fetches `data.json`. `autometta dashboard
--open` uses a plain `file://` URL, so `index.html` loads `data.js` first and
the renderer uses `window.AUTOMETTA_DATA` when `fetch` is unavailable. The two
files are emitted from one assembled object by the aggregator; `data.js` is
not a second walker.

## Four breakdowns

1. **Per repo.** One card per subscriber: tokens spent, token cap,
   stage count, and a halt indicator if applicable. Mirrored as a bar
   chart of tokens-spent per repo.
2. **Per stage.** Table of every stage across every repo with status,
   worker / verifier identity, per-stage worker / verifier / total
   token counts, and completion timestamp. Mirrored as a bar chart of
   per-stage totals.
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
