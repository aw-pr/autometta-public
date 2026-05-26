# Stage card 11-cost-dashboard: Central per-repo cost dashboard with per-stage / per-model / per-time breakdown

## Metadata

- **Authored:** 2026-05-26
- **Orchestrator:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Worker:** Codex GPT-5.3 <codex-gpt-5-3@local>
- **Verifier:** Claude Sonnet 4.6 <claude-sonnet-4-6@local>
- **Pairing rationale:** Cross-family. Touches bash plumbing (per-stage token snapshot), a new aggregator script, a small JS+HTML dashboard, and docs. Claude verifier confirms the per-stage breakdown is accurate (subtle accounting), the model attribution maps cleanly to the canonical agent-identity table, and the HTML renders without an external CDN.

## Objective

Build a single static HTML dashboard at `~/.phat-controller/dashboard/index.html` that visualises token spend and stage activity across every subscribed repo. Regenerated on demand by `autometta dashboard` (new subcommand) and on every successful tick.

Breakdown axes:

1. **Per repo** — one card per subscriber under `~/.phat-controller/subscribers/`.
2. **Per stage** — token cost of each stage within a repo, with worker / verifier identity, status (`completed`, `verifier_failed`, `stalled`, `pending`), and elapsed wall-clock.
3. **Per model** — aggregated token spend grouped by canonical identity (`Claude Opus 4.7`, `Codex GPT-5.3`, `Claude Sonnet 4.6`, etc., per `~/.claude/rules/mcp-hub-dev-rules.md`).
4. **Per time** — daily token spend rollup (UTC dates), drawn as a small bar/line chart.

No daemon, no live updating. The user runs `autometta dashboard --open` and a browser opens to the local file. Re-runs regenerate. Stage 10 made the input data (tokens_spent) honest going forward; this card makes it consumable.

## Inputs (read these in your own context)

- `scripts/tick.sh` — to wire the per-stage token-snapshot side effect into the commit-on-PASS path.
- `scripts/budget.sh` — `budget_add_tokens` (stage 10).
- `scripts/spawn-worker.sh`, `scripts/spawn-verifier.sh` — confirm token-parser lives where stage 10 placed it.
- `~/.phat-controller/subscribers/template.yaml` and any active subscriber yaml — confirm the subscriber data layout.
- A real adopter `state/state.yaml` for shape reference (e.g. `/Users/AnthonyWest/repos/emergence-lab/state/state.yaml`).
- A real verifier artefact JSON (e.g. `/Users/AnthonyWest/repos/emergence-lab/state/verifiers/01-iteration-counter-side-panel.json`).
- `~/.claude/rules/mcp-hub-dev-rules.md` — the canonical agent-identity table.

Do not read anything else unless needed.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. `scripts/tick.sh` — in the commit-on-PASS branch, after `budget_add_tokens` has run for the just-finished worker and verifier, snapshot the resulting per-stage token total into `state/state.yaml` under the stage entry as a new field `tokens` (integer). On PASS, also record `worker_tokens` and `verifier_tokens` separately if obtainable. (Sub-fix of stage 10: it currently records only the running `budget.tokens_spent`; per-stage attribution requires snapshotting before/after.)
2. `scripts/aggregate-dashboard.sh` — new script that walks `~/.phat-controller/subscribers/*.yaml`, reads each subscriber's `state/state.yaml`, `state/budget.json`, and `state/verifiers/*.json`, and emits a single `~/.phat-controller/dashboard/data.json` with this shape:
   ```jsonc
   {
     "generated_at": "2026-05-26T...",
     "repos": [
       {
         "name": "emergence-lab",
         "repo_path": "/Users/AnthonyWest/repos/emergence-lab",
         "enabled": true,
         "tokens_spent": 0,
         "token_cap_total": 1000000,
         "halted": false,
         "halt_reason": null,
         "stages": [
           {
             "id": "01-iteration-counter-side-panel",
             "status": "completed",
             "worker": "Codex GPT-5.3 <codex-gpt-5-3@local>",
             "verifier": "Claude Sonnet 4.6 <claude-sonnet-4-6@local>",
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
     "by_model": [
       { "identity": "Claude Sonnet 4.6 <claude-sonnet-4-6@local>", "tokens": 0 },
       { "identity": "Codex GPT-5.3 <codex-gpt-5-3@local>", "tokens": 0 }
     ],
     "by_day": [
       { "date": "2026-05-26", "tokens": 0 }
     ]
   }
   ```
3. `scripts/dashboard.sh` — new entrypoint. Regenerates `data.json` via `aggregate-dashboard.sh`, copies the static `dashboard/index.html` + `dashboard/dashboard.js` into `~/.phat-controller/dashboard/`, and (with `--open`) opens the local file in the default browser using `open` on macOS or `xdg-open` on linux.
4. `dashboard/index.html` — static page. Header, four sections (Per Repo, Per Stage, Per Model, Per Day), one `<canvas>` per chart, plain HTML/CSS, no external CDN.
5. `dashboard/dashboard.js` — vanilla JS, fetches `data.json` (same-origin or via `file://` with embedded data fallback), draws four charts using Chart.js **vendored** into `dashboard/vendor/chart.min.js` (download once at install time; small, MIT-licensed). No CDN runtime.
6. `dashboard/dashboard.css` — minimal styling: dark background, card grid for repos, table for stages.
7. `bin/autometta` — add `dashboard` subcommand that delegates to `scripts/dashboard.sh`.
8. `scripts/install-homebrew-local.sh` — extend to download Chart.js (`chart.min.js`, ~75 kB minified, MIT) into `dashboard/vendor/` at install time, with a SHA256 pin, so the brew install is self-contained. Use `curl --fail-with-body` and verify hash.
9. `docs/dashboard.md` — short doc describing the subcommand, the regeneration model, the four breakdowns, and where the file lives.

## Constraints

- **No daemon.** The dashboard is a regenerated static file. The user re-runs `autometta dashboard` to refresh.
- **No external CDN at runtime.** Chart.js is vendored at install. If the install step fails to download Chart.js, the install must fail loudly — the dashboard cannot silently fall back to "no chart, just numbers".
- **No new runtime dependencies.** bash 3.2, jq, yq, python3 (already present), curl (already present on macOS / linux). No Node.js, no Python web framework.
- **Bash 3.2 compatible.** No associative arrays.
- **Read-only on adopter repos.** `aggregate-dashboard.sh` reads state files but must not write to any adopter repo.
- The new per-stage `tokens` field is **additive** — existing state.yaml files without it must still parse. Default to `null` / `0` when absent.
- Worker does NOT self-commit. Orchestrator commits per the new dispatch model. Subject prefix `11-cost-dashboard: ...`.
- Atomic commits per `~/.claude/rules/mcp-hub-dev-rules.md`. Multiple atomic commits are encouraged (e.g. one per: per-stage snapshot in tick.sh, aggregator, HTML+JS, install fetch, docs).
- Publish-guard pre-push hook must pass.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. `bash -n` is green on `scripts/tick.sh`, `scripts/aggregate-dashboard.sh`, `scripts/dashboard.sh`, `scripts/install-homebrew-local.sh`, `bin/autometta`.
2. `autometta dashboard` (no args) regenerates `~/.phat-controller/dashboard/data.json` and `~/.phat-controller/dashboard/index.html`. Running it twice produces a `data.json` with a later `generated_at` but otherwise identical content for unchanged state.
3. `autometta dashboard --open` opens the local dashboard file (worker confirms by manual invocation; verifier confirms the flag is parsed and the `open` / `xdg-open` invocation is correct).
4. `data.json` schema matches the example in deliverable #2 (the verifier confirms by `jq` queries against a real run).
5. Running against the live adopter state at `/Users/AnthonyWest/repos/emergence-lab`, the dashboard shows at least one stage per real status (`completed`, `verifier_failed`) and the per-model section lists at least `Claude Opus 4.7`, `Codex GPT-5.3`, and `Claude Sonnet 4.6` identities.
6. Per-stage `tokens` field is populated for any stage that completes after this card lands (verifier checks one stage with the new path active).
7. Chart.js is vendored under `dashboard/vendor/chart.min.js` and its SHA256 is pinned in `scripts/install-homebrew-local.sh`. The install script fails loudly if the hash mismatches.
8. No external network access at dashboard runtime (verifier checks by reading the HTML / JS for `https?://` references; only same-directory paths should appear).
9. `docs/dashboard.md` describes the regeneration model and the four breakdowns.
10. No files outside the deliverables set are modified — except this stage card itself (exempt per `memory/feedback-acceptance-criterion-stage-card-exemption.md`).
11. Publish-guard pre-push hook passes.

## Out of scope

- Daemon / auto-refresh / WebSocket live updates.
- Per-model cost weighting in dollars (token counts only — converting to USD is a separate decision that depends on which Anthropic / OpenAI pricing tier the user wants to assume).
- Authentication / multi-user.
- Exporting CSV / PDF.
- Drill-down into the verifier artefact (links to the JSON file are fine; rendering the criteria themselves is a follow-up card).
- A `--watch` mode that rebuilds on filesystem change.
- A `--clear` flag to reset historic per-stage token snapshots.

## Budget

- **Worker wall-clock:** 90 minutes
- **Verifier wall-clock:** 25 minutes

## Verifier handoff

Worker returns:

- Commit SHA(s) (one per atomic concern, multiple expected).
- Output of `autometta dashboard --open` (a screenshot is not required; a description of what rendered is sufficient).
- The four canonical chart titles / IDs used.
- Vendored Chart.js version and pinned SHA256.
- Confirmation that no external HTTP fetch happens at dashboard-render time.
- Confirmation that `git publish` succeeded on both remotes and the brew reinstall passed.
- One-line confirmation that no `git commit` was invoked from the worker phase (per the new dispatch model — orchestrator commits on verifier-pass).

## Family-specific notes

- Codex worker: `</dev/null` stdin redirect; **do not run `git commit`** in your phase. Pay particular attention to bash 3.2 idioms when writing `aggregate-dashboard.sh` — it will have non-trivial jq pipelines.
- Claude verifier: cross-family per `memory/project-cross-family-verification-validated.md`. The verifier should both `jq`-inspect the generated `data.json` for schema and open the HTML in a real browser (or use a headless check) to confirm the four charts render against live emergence-lab state.
