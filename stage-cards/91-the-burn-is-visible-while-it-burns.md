# Stage card 91: the burn is visible while it burns

## Metadata

- **Authored:** 2026-08-31
- **Orchestrator:** Claude Fable 5 <claude-fable-5@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Opus 5 <claude-opus-5@local>
- **Base branch:** dev
- **Run branch:** autometta/91-the-burn-is-visible-while-it-burns
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Gate:** stage-completed: 90-the-verifier-reaches-for-the-sdk-first
- **Path claims:** scripts/verify-sdk.py, scripts/verify-sdk-openai.py, scripts/aggregate-dashboard.sh, scripts/tui.sh, dashboard/dashboard.js, docs/dashboard.md
- **Pairing rationale:** premium pairing for display work per the standing
  feedback memory: cheap tiers game display smokes, so the strongest Claude
  tier verifies what the operator will actually look at, while the codex
  workhorse does the plumbing.

## Objective

Today a token figure exists only after a dispatch completes and the tick
parses its log, so the TUI and dashboard are real-time to the file but
per-completion for spend: a 20-minute dispatch shows nothing until it ends,
and a `claude -p` dispatch cannot show anything mid-flight at all (gotcha
6). The SDK routes change what is possible: they see usage per message.

Make in-flight burn visible. The SDK verifier entrypoints append a running
usage line to the dispatch's registry entry under `state/active-agents/`,
the seam aggregator carries a `live_usage` figure for in-flight dispatches
into `data.json`, and the TUI run page and dashboard render it, visually
distinct from settled cost-log figures. CLI dispatches show an honest "no
live figure" marker rather than a zero.

## Inputs (read these in your own context)

- scripts/verify-sdk.py
- scripts/aggregate-dashboard.sh
- scripts/tui.sh (the run page's data path)
- docs/dashboard.md (the seam and poll model)
- docs/observability.md (the registry contract)

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/verify-sdk.py` and `scripts/verify-sdk-openai.py`: after each
   SDK message, update the agent's own registry JSON with cumulative
   `live_input_tokens`, `live_output_tokens`, `live_updated_at`. Atomic
   write (temp file + rename); a write failure warns and never interrupts
   the verification.
2. `scripts/aggregate-dashboard.sh`: in-flight dispatches gain `live_usage`
   in `data.json`, sourced from the registry; absent fields simply omit it.
3. `scripts/tui.sh` run page and `dashboard/dashboard.js`: render the live
   figure with a marker distinguishing it from settled spend; absence
   renders as a dash or "n/a", never 0.
4. `docs/dashboard.md`: a short "live figures" subsection stating the data
   path, the poll cadences that bound the latency (SDK message -> registry
   -> seam regeneration -> page poll), and that settled truth remains
   `state/cost-log.jsonl` with no double counting.

## Constraints

- The registry entry is the only new write surface; no new files, daemons or
  sockets. The seam and page keep their existing poll cadences.
- `state/cost-log.jsonl` and `budget.json` accounting are untouched: live
  figures are display, never billing.
- A missing or stale `live_updated_at` must degrade the display, not the
  dispatch or the seam.
- British English in prose, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

1. `bash -n` passes on both shell deliverables and `python3 -m py_compile`
   on both SDK entrypoints.
2. A fixture registry entry with live fields flows into `data.json` on one
   seam regeneration, shown by jq.
3. With a fixture entry updating every few seconds, the served dashboard
   page shows the figure moving without a manual reload, and the TUI run
   page shows it within one 5s poll.
4. A CLI-family fixture entry (no live fields) renders the honest marker in
   both surfaces, not 0.
5. One real SDK verifier dispatch on this repo shows a live figure in the
   TUI while the verifier is still running, and the figure disappears into
   the settled cost-log row when the stage lands.
6. `git diff --stat` on the run branch touches only the six claimed paths.

## Contract test

- **Test file:** None
- **Assertions digest:** None

## Out of scope

- Live figures for CLI dispatches: gotcha 6 makes the claude side
  structurally impossible and the codex side is separate work.
- Worker-role live figures (workers are CLI by design).
- Any budget enforcement based on live figures.

## Budget

- **Worker wall-clock:** 3000s
- **Verifier wall-clock:** 2400s

## Verifier handoff

Leave the working tree dirty. Report the jq evidence for criterion 2, how
the moving figure was observed for criterion 3, and the TUI capture for
criterion 5.

## Family-specific notes

The real-dispatch evidence in criterion 5 needs a claude-family SDK
verifier run, which after card 90 is the default for this repo's
subscription auth; no API key is required.
