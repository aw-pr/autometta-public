# Stage card 150: the table ticks while it burns

## Metadata

- **Authored:** 2026-10-11
- **Orchestrator:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Worker:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Verifier:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Base branch:** dev
- **Run branch:** autometta/150-the-table-ticks-while-it-burns
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** dashboard/dashboard.js, dashboard/dashboard.css, scripts/lib/tui/render.py, scripts/tui-smoke.sh, docs/dashboard.md, docs/observability.md
- **Pairing rationale:** the same pair that landed 149 first time on the
  same files: Sol for display work, Opus 5.5 to judge it. Weekly (Fable)
  stood at 89% on 2026-10-11, so Fable is not used.

## Surfacing concern

The operator watched the emergence-lab 116 stage in the browser on
2026-10-11 and saw `Worker tok 0 / Verifier tok 0 / Total tok 0` beside a
`working` status while the worker's transcript stood at 8.15M tokens. The
stages table reads only settled figures, which a role writes when it
finishes, so an in-flight stage reads zero for its whole run. Card 149
put the live figure in the agents table, which is not where the operator
looks.

The TUI is half there. Its run row and status line already show the live
transcript figure, but the agents row and the detail pane's `live` line
read only the SDK's `live_usage` and print `n/a` for every CLI dispatch,
and the detail burn line is built from the TUI's own last eight polls, so
it starts flat each time the TUI opens. When a verifier is live, the run
row shows only the verifier's figure and drops the worker's settled
tokens.

## Objective

An in-flight stage's token figures move at the poll rate in both views. In
the web stages table the running role's column and the total add the live
figure to whatever has settled, marked as live. In the TUI the run row
totals settled plus live, the agents row and the detail `live` line show
the transcript figure, and the detail burn line draws the agent's `burn`
series from card 149. Settled stages and SDK figures read as before.

## Inputs (read these in your own context)

- `scripts/live-stage-tokens-smoke.sh`: the frozen contract and the payload
  shapes; read it first.
- `dashboard/dashboard.js`: `stageSpend`, `renderStagesTable`, `burnCell`.
- `scripts/lib/tui/render.py`: `stage_total`, `agent_lines`, `detail_lines`,
  `sparkline_and_rate`, `live_spend_suffix`.
- `scripts/tui-smoke.sh`: the `poll()` fixture and the 80-column offsets
  block.
- `docs/dashboard.md` section "Live figures" and `docs/observability.md`
  section "The TUI".

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `dashboard/dashboard.js`: a top-level `function stageTokenCells(repo,
   stage)` (two-space indent inside the IIFE, as the smoke lifts it)
   returning `[worker, verifier, total]` cells, used by
   `renderStagesTable`. The settled figures come from `stageSpend` exactly
   as today, with the same `*` mark and unavailable title. When
   `repo.agents` holds an agent for the stage with a figure (`live_usage`
   input plus output when present, else a counted `stage_tokens`), that
   figure is added to the agent's role column and to the total, and both
   cells carry `class="live"`. No figure, no mark, nothing added.
2. `dashboard/dashboard.css`: a style for the live cells using the existing
   theme tokens, legible in both themes. No animation that runs when
   nothing has changed.
3. `scripts/lib/tui/render.py`: `stage_total` returns settled plus live,
   where settled is what it returns today when no agent is live. The agents
   row shows `tick_tokens(stage_tokens)` when there is no `live_usage` and
   a counted figure, instead of `n/a`. The detail pane's `live` line reads
   `<tick_tokens> transcript` in that case. When the agent carries a `burn`
   series of two or more points, the detail burn line reads `burn this run`
   with a sparkline of per-point deltas and the rate over the trailing five
   minutes of points, computed as `burnCell` does; otherwise it keeps
   `burn last 8 polls` exactly as today. SDK figures keep `LIVE`.
4. `scripts/tui-smoke.sh`: its `poll()` fixture gives stage 68's
   `spend.by_stage` row `"tokens": live_tokens`, a settled figure that grows
   with each poll, which no real cost log produces for a role still
   running. Make that row a constant 1,000,000 and change the 80-column
   offsets expectation for 68 from `2,301k` to `3,301k`. Change nothing else
   in that file. A reference implementation passed the whole of
   `tui-smoke.sh` with exactly these two edits.
5. `docs/dashboard.md` and `docs/observability.md`: say that in-flight
   figures add the live transcript or SDK figure to the settled ones, how
   they are marked, and that they are display only. Fix the paragraph order
   card 149's verifier flagged in `docs/observability.md`, where "It polls
   the same aggregate-dashboard.sh --repo seam" now reads as if "It" meant
   the burn series.

## Constraints

- The frozen block in `scripts/live-stage-tokens-smoke.sh` is read-only to
  you.
- Charts, the cost-log fallback, `state/cost-log.jsonl`, `budget.json` and
  the aggregator are untouched: live figures are display, never billing or
  state, and are never added into the per-stage or per-day charts.
- Absence renders as absence: an agent with no figure adds nothing and
  marks nothing.
- Fits-its-pane discipline from cards 44 and 63: no TUI line wraps that did
  not wrap before, and the 80-column run rows keep constant offsets.
- British English in prose, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. `bash scripts/live-stage-tokens-smoke.sh` passes on the run branch, run
   by the verifier, and `scripts/check-contract-test-gate.sh print
   scripts/live-stage-tokens-smoke.sh` prints the digest recorded below.
2. `scripts/tui-smoke.sh`, `scripts/tui-heartbeat-smoke.sh`,
   `scripts/agent-activity-smoke.sh`, `scripts/agent-burn-smoke.sh`,
   `scripts/dashboard-liveness-smoke.sh`, `scripts/dashboard-clock-smoke.sh`,
   `scripts/repo-ticker-smoke.sh` and `scripts/ticker-fit-smoke.sh` pass;
   record any failure that already exists on the base commit separately,
   and any new failure fails this card.
3. `git diff dev -- scripts/tui-smoke.sh` shows only the two edits named in
   deliverable 4.
4. While it is itself the live agent, the verifier runs
   `scripts/aggregate-dashboard.sh --repo <repo-root>` from the run
   worktree, feeds the result to `stageTokenCells` in node and to the TUI
   renderer in python, and quotes its own stage's three web cells and its
   own TUI run row, agents row, `live` line and burn line. The figures must
   match its own `stage_tokens`.
5. `node --check dashboard/dashboard.js`, `python3 -m py_compile
   scripts/lib/tui/render.py` and `bash -n scripts/tui-smoke.sh` pass.
6. `git diff --stat` on the run branch touches only the claimed paths.

## Contract test

- **Test file:** scripts/live-stage-tokens-smoke.sh
- **Assertions digest:** `sha256:6a16655011ef80689fcff949e895863caa9dacf03b8aac9f78506f7f9cf275ff`

The orchestrator authored the frozen block on 2026-10-11 from the
emergence-lab `--repo` seam of that afternoon. It fails today at its first
assertion, because `stageTokenCells` does not exist; the TUI block fails
on the `n/a` agents row. A throwaway reference implementation (not
committed) passed every block, and with deliverable 4's two fixture edits
kept `tui-smoke.sh`, `agent-burn-smoke.sh`, `agent-activity-smoke.sh` and
both dashboard smokes green.

## Out of scope

- The fleet-wide dashboard, whose agents carry no transcript figure.
- A role split for `spend.by_stage`; the worker column of a stage whose
  verifier is live keeps today's settled rendering.
- The charts, which stay on settled figures.
- `attach-card-text.py` rewriting `data.json` in place; a separate card.

## Budget

- **Worker wall-clock:** 40 minutes
- **Verifier wall-clock:** 25 minutes
- **Spend basis:** card 149 on the same pair cost 1.46M worker and 2.32M
  verifier tokens. Planning allowance 6M tokens, subject to live admission,
  under the 2026-10-11 drain that already covers this repo.

## Dispatch envelope

Write `state/envelopes/150-the-table-ticks-while-it-burns.json` using
`schemas/envelope.json`. List changed deliverables, the exact smoke
commands and their results, and any criterion you could not satisfy with
why. Do not self-verify or land your own branch. The verifier writes
`state/verifiers/150-the-table-ticks-while-it-burns.json` under the
existing verifier contract, giving a criterion-by-criterion verdict.

## Family-specific notes

The worker is a Codex seat under `workspace-write`; every input is in the
tree or the smoke's fixtures. Criterion 4 belongs to the verifier, because
only a Claude seat has a transcript under `~/.claude/projects/` while it
runs.
