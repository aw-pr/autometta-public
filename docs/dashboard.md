# Cost dashboard

`autometta dashboard` regenerates a static, offline-renderable HTML
dashboard that visualises token spend and stage activity across every
subscribed repo. There is no daemon and no live update — the page is
regenerated on demand and on every successful tick.

## Subcommand

```
autometta dashboard           # regenerate only
autometta dashboard --open    # regenerate and open in default browser
```

The dashboard files live at `~/.phat-controller/dashboard/`:

- `data.json` — aggregated state from all subscribers
- `index.html` — page entry point
- `dashboard.js` — vanilla JS renderer
- `dashboard.css` — dark theme
- `vendor/chart.min.js` — Chart.js 4.4.0, vendored at install time

No external network access happens at render time. Chart.js is fetched
once at install time (`scripts/install-homebrew-local.sh`) with a pinned
SHA256 hash; a mismatch fails the install loudly.

## Regeneration model

`scripts/dashboard.sh`:

1. Runs `scripts/aggregate-dashboard.sh`, which walks
   `~/.phat-controller/subscribers/*.yaml` (excluding `template.yaml`),
   reads each repo's `state/state.yaml`, `state/budget.json`, and
   `state/verifiers/*.json`, and emits a fresh
   `~/.phat-controller/dashboard/data.json`. Read-only on adopter
   repos.
2. Copies the static assets (`index.html`, `dashboard.js`,
   `dashboard.css`, `vendor/chart.min.js`) from the autometta install
   into `~/.phat-controller/dashboard/`.
3. With `--open`, launches the local file via `open` (macOS) or
   `xdg-open` (linux).

The aggregator and copy steps are also wired into `scripts/tick.sh` via
the per-stage `tokens` snapshot — every commit-on-PASS records its
worker / verifier token counts onto the matching stage entry in
`state.yaml`, which `data.json` then surfaces.

## Four breakdowns

1. **Per repo.** One card per subscriber: tokens spent, token cap,
   stage count, and a halt indicator if applicable. Mirrored as a bar
   chart of tokens-spent per repo.
2. **Per stage.** Table of every stage across every repo with status,
   worker / verifier identity, per-stage worker / verifier / total
   token counts, and completion timestamp. Mirrored as a bar chart of
   per-stage totals.
3. **Per model.** Token spend grouped by canonical agent identity
   (e.g. `Claude Opus 4.7 <claude-opus-4-7@local>`,
   `Codex GPT-5.3 <codex-gpt-5-3@local>`,
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
      "stages": [
        {
          "id": "01-...",
          "status": "completed",
          "worker": "Codex GPT-5.3 <codex-gpt-5-3@local>",
          "verifier": "Claude Sonnet 4.6 <claude-sonnet-4-6@local>",
          "orchestrator": "Claude Opus 4.7 <claude-opus-4-7@local>",
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
  "by_model": [{"identity": "...", "tokens": 0}],
  "by_day":   [{"date": "2026-05-26", "tokens": 0}]
}
```

The per-stage `tokens` / `worker_tokens` / `verifier_tokens` fields are
**additive** — older `state.yaml` files without them parse to `0` /
`null` and continue to render.
