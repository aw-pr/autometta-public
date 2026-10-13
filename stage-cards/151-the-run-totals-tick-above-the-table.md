# Stage card 151: the run totals tick above the table

## Metadata

- **Authored:** 2026-10-11
- **Orchestrator:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Worker:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Verifier:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Base branch:** dev
- **Run branch:** autometta/151-the-run-totals-tick-above-the-table
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Gate:** stage-completed: 150-the-table-ticks-while-it-burns
- **Path claims:** dashboard/index.html, dashboard/dashboard.js, dashboard/dashboard.css, docs/dashboard.md
- **Pairing rationale:** the pair that landed 149 and is running 150 on the
  same files. Gated on 150 because both edit `dashboard.js`, and this card
  reuses the live-figure rule 150 lands.

## Surfacing concern

The TUI's status panel carries the run's spend with the in-flight figure
on the end of it (`run spend 20,715k $9.35 actual | worker 18m23s +8,151k
live`). The web page has no run-level figure at all: the operator reads
the Per stage section and has to add the rows up. They asked on 2026-10-11
for the run totals at the top of that table, ticking like the rows below.

## Objective

The Per stage section shows, above the table, one line per visible repo
that has a current run: the run id, stages done of stages in the run, the
run's tokens (settled plus every live figure for a stage in the run) and
its settled cost. The line is marked live while any agent in the run is
running and moves at the page's poll rate.

## Inputs (read these in your own context)

- `scripts/run-totals-smoke.sh`: the frozen contract; read it first.
- `dashboard/index.html`: the Per stage section.
- `dashboard/dashboard.js`: `stageTokenCells` and whatever helper card 150
  landed to read a live agent's figure, `render`, `renderStagesTable`.
- `scripts/lib/tui/render.py`: `live_spend_suffix`, for the shape the TUI
  already uses (read, do not edit).
- `docs/dashboard.md` section "Live figures".

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `dashboard/index.html`: an element `id="run-totals"` inside the Per
   stage section, after its heading and before `stages-table-wrap`.
2. `dashboard/dashboard.js`: a top-level `function runTotals(repo)`
   (two-space indent inside the IIFE, as the smoke lifts it) returning a
   string or `{html}`, empty when `repo.current_run` is absent. Settled
   tokens are `current_run.tokens_total`; to them it adds each agent in
   `repo.agents` whose `stage_id` is a stage of the run, using the same
   live-figure rule as 150 (SDK `live_usage` first, else a counted
   `stage_tokens`, else nothing). Reuse 150's helper rather than restating
   the rule. Cost is `current_run.cost_usd_est`, settled only, two decimal
   places. Stages done counts `status == "completed"`. A live run's markup
   carries `class="live"`. A render-path function writes one line per
   visible repo into `#run-totals` on every render.
3. `dashboard/dashboard.css`: styling for the strip using the existing
   theme tokens and the live style 150 introduced; legible in both themes
   and at phone width.
4. `docs/dashboard.md`: a short paragraph naming the strip, its sources,
   and that its live part is display only.

## Constraints

- The frozen block in `scripts/run-totals-smoke.sh` is read-only to you.
- The aggregator, the charts, `state/cost-log.jsonl` and `budget.json` are
  untouched. The live figure is never added to cost.
- Absence renders as absence: no run, no line; no live figure, no mark.
- British English in prose, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. `bash scripts/run-totals-smoke.sh` passes on the run branch, run by the
   verifier, and `scripts/check-contract-test-gate.sh print
   scripts/run-totals-smoke.sh` prints the digest recorded below.
2. `scripts/live-stage-tokens-smoke.sh`, `scripts/agent-burn-smoke.sh`,
   `scripts/dashboard-liveness-smoke.sh` and `scripts/dashboard-clock-smoke.sh`
   pass; record any failure that already exists on the base commit
   separately, and any new failure fails this card.
3. While it is itself the live agent, the verifier runs
   `scripts/aggregate-dashboard.sh --repo <repo-root>` from the run
   worktree, wraps the result as the repo object, calls `runTotals` in node
   and quotes the line, showing its tokens equal `current_run.tokens_total`
   plus its own `stage_tokens`.
4. `node --check dashboard/dashboard.js` passes and `git diff --stat`
   touches only the claimed paths.

## Contract test

- **Test file:** scripts/run-totals-smoke.sh
- **Assertions digest:** `sha256:3813413029943ee682629e2ce52716b253a73c701c987469562f2014246aa203`

The orchestrator authored the frozen block on 2026-10-11 from the
emergence-lab `current_run` of that afternoon. It fails today at its first
assertion, because the page has no strip. A throwaway reference
implementation built on a sketch of 150 passed every block and kept the
other dashboard smokes green.

## Out of scope

- The TUI, which already shows the run spend with its live tail.
- A live cost figure; cost stays settled.
- The fleet-wide page's live figures, which its agents do not carry.

## Budget

- **Worker wall-clock:** 25 minutes
- **Verifier wall-clock:** 20 minutes
- **Spend basis:** a smaller change than 149 on the same pair (1.46M worker,
  2.32M verifier). Planning allowance 4M tokens under the 2026-10-11 drain.

## Dispatch envelope

Write `state/envelopes/151-the-run-totals-tick-above-the-table.json` using
`schemas/envelope.json`. List changed deliverables, the exact smoke
commands and their results, and any criterion you could not satisfy with
why. Do not self-verify or land your own branch. The verifier writes
`state/verifiers/151-the-run-totals-tick-above-the-table.json` under the
existing verifier contract, giving a criterion-by-criterion verdict.

## Family-specific notes

The worker is a Codex seat under `workspace-write`; every input is in the
tree. Criterion 3 belongs to the verifier, because only a Claude seat has
a transcript under `~/.claude/projects/` while it runs.
