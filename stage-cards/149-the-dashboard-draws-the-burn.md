# Stage card 149: the dashboard draws the burn

## Metadata

- **Authored:** 2026-10-11
- **Orchestrator:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Worker:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Verifier:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Base branch:** dev
- **Run branch:** autometta/149-the-dashboard-draws-the-burn
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/lib/transcript-tokens.py, scripts/agent-ticker.sh, scripts/aggregate-dashboard.sh, dashboard/dashboard.js, dashboard/dashboard.css, docs/dashboard.md, docs/observability.md
- **Pairing rationale:** Sol for the worker because the deliverable is
  display work, and cheaper tiers have gamed display smokes before; the
  Codex weekly window is fresh. The verifier is a Claude seat because
  criterion 3 needs a live transcript under `~/.claude/projects/`, which
  only a `claude -p` session in the run worktree produces. Opus 5.5 rather
  than Fable because Weekly (Fable) stood at 89% on 2026-10-11.

## Surfacing concern

Card 146 put what a live agent is doing on the dashboard, but not how fast
it is spending. The web agents table's `Live burn` column reads only
`live_usage`, which only the SDK verifier route writes, so every CLI
dispatch, which is all of them since 147 pinned the verifier to the CLI,
shows `n/a`. The transcript total the reader already computes
(`stage_tokens`, refreshed every five seconds in `--repo` mode) reaches
`data.json` and is never drawn.

That total is also wrong for Claude. Claude Code writes one transcript
record per content block, and each record repeats its message's `id` and
`usage`. The reader sums every record. On 2026-10-11 the emergence-lab 123b
worker transcript held 112 assistant records for 64 messages: the reader
reported 16.9M tokens and 102 turns, while a count keyed on `message.id`
gives 9.7M, of which 9.4M (97%) are cache reads. `scripts/agent-ticker.sh`
carries a copy of the same reader and writes the same registry keys.

## Objective

Each live agent in the `--repo` seam carries a bounded `burn` series
derived from its transcript, built from figures that count each Claude
message once. The web dashboard's `Live burn` cell shows, for a CLI
dispatch, the transcript total, the recent rate, the cache-read share and
a sparkline of the run so far. SDK figures keep their `LIVE` label, and
absence stays absence.

## Inputs (read these in your own context)

- `scripts/agent-burn-smoke.sh`: the frozen contract and the fixture record
  shapes; read it first.
- `scripts/lib/transcript-tokens.py`: the reader you are extending.
- `scripts/agent-ticker.sh`: the `transcript_tokens` function, which shares
  the reader's registry keys.
- `scripts/aggregate-dashboard.sh`: the `--repo` enrichment block (search
  for `transcript-tokens.py`).
- `dashboard/dashboard.js`: `renderAgents`, `tableHtml` (cells accept
  `{html}`), `activityText`.
- `docs/dashboard.md` section "Live figures" and `docs/observability.md`
  section "The TUI".

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/lib/transcript-tokens.py`, Claude branch: a record whose
   `message.id` equals the previous assistant record's adds no usage and no
   turn, while its `tool_use` blocks still count as tool calls. The last
   seen id lives in the registry beside the offset, so a message whose
   records straddle two reads is still counted once. A record without a
   `message.id` keeps today's behaviour.
2. Same file: each agent gains `burn`, `{"bucket_seconds": 60, "points":
   [{"t", "tokens", "cached", "turns"}, ...]}` or `null` when no usage was
   read. `t` is the bucket start in epoch seconds; each point holds the
   cumulative figures at the last usage record in that bucket. For Claude,
   `tokens` is the deduplicated total, `cached` the cumulative
   `cache_read_input_tokens`, and the series persists in the registry across
   incremental reads. For Codex, each `token_count` event with a
   `total_token_usage` contributes `total_tokens` and `cached_input_tokens`,
   and the series is rebuilt from the window already read. At most 240
   points: past that, `bucket_seconds` doubles and points regroup onto the
   new width, keeping the last point of each group. The final point always
   equals `stage_tokens`.
3. `scripts/agent-ticker.sh`: its Claude token count keys on `message.id`
   the same way and honours the same registry key for the last seen id, so
   alternating the two readers over one registry never counts a message
   twice. Its output is otherwise unchanged.
4. `scripts/aggregate-dashboard.sh`: only if needed, so that `burn` reaches
   the `--repo` seam for every live agent. The fleet-wide pass is untouched.
5. `dashboard/dashboard.js`: a top-level `function burnCell(agent)` (two-space
   indent inside the IIFE, as the smoke lifts it) returning a string or a
   `{html}` cell, used by `renderAgents` for live rows. With `live_usage` it
   renders exactly what the column renders today. Without it, and with a
   counted `stage_tokens`, it shows the total labelled as a transcript
   figure, the rate over the trailing five minutes of points (from the
   newest point back to the latest point at or before five minutes earlier,
   or the first point when none is that old; no rate from one point), the
   newest point's cache-read share as `N% cached`, and an inline SVG
   sparkline of cumulative tokens when there are two or more points.
   `waiting` reads `waiting`; anything else uncounted reads `n/a`. No new
   vendored dependency and no Chart.js instance per row. Any styling goes
   in `dashboard/dashboard.css` and follows its existing theme tokens.
6. `docs/dashboard.md` and `docs/observability.md`: name the `burn` fields,
   the bucket and the bound, the deduplication and why it lowers Claude
   totals against earlier readings, and that the series is a display figure
   only: settled accounting stays in `state/cost-log.jsonl`.

## Constraints

- The frozen block in `scripts/agent-burn-smoke.sh` is read-only to you.
- The transcript is read incrementally exactly as today; this card adds
  parsing to the bytes already consumed, not a second pass over the file.
- `state/cost-log.jsonl`, `budget.json`, the heartbeat, the tick and both
  spawn scripts are untouched: the burn is display, never billing or state.
- Absence renders as absence: no transcript, no usage or one point never
  becomes a `0`, an empty sparkline or an invented rate.
- `scripts/agent-activity-smoke.sh` must keep passing unchanged: its
  fixture gives every message a distinct id.
- The registry entry is rewritten every five seconds; keep the series
  bounded as specified, and do not add a second registry file.
- British English in prose, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. `bash scripts/agent-burn-smoke.sh` passes on the run branch, run by the
   verifier, and `scripts/check-contract-test-gate.sh print
   scripts/agent-burn-smoke.sh` prints the digest recorded below.
2. `scripts/agent-activity-smoke.sh`, `scripts/dashboard-liveness-smoke.sh`,
   `scripts/dashboard-clock-smoke.sh`, `scripts/tui-smoke.sh` and
   `scripts/repo-ticker-smoke.sh` still pass; record any failure that already
   exists on the base commit separately, and any new failure fails this card.
3. While it is itself the live agent, the verifier runs
   `scripts/aggregate-dashboard.sh --repo <repo-root>` from the run worktree
   and shows its own entry carrying a `burn` whose final point equals its
   `stage_tokens`, and whose `turns` equals the number of distinct
   `message.id` values among the assistant records in its own transcript
   (count them with `jq`, not by reading the reader).
4. The verifier runs the reader on branch and base over a copy of one real
   Claude transcript with repeated message ids, and shows the branch total
   equal to an independent `jq` sum over unique ids, and the base total
   higher. Then it runs `scripts/agent-ticker.sh`'s reader and the library
   reader alternately over one registry and shows the total unchanged by
   the alternation.
5. The verifier renders the agents table in node from a `data.json`-shaped
   fixture with one SDK agent, one CLI agent with a series and one waiting
   agent, and quotes the three `Live burn` cells as text.
6. `python3 -m py_compile` passes on the Python deliverable, `node --check`
   on `dashboard/dashboard.js`, and `bash -n` on every touched shell script.
7. `git diff --stat` on the run branch touches only the claimed paths.

## Contract test

- **Test file:** scripts/agent-burn-smoke.sh
- **Assertions digest:** `sha256:a6f38bb09cde9cffcb9cea3a36cc79da1ad87f3564f4ad776a0bd2e27113fb50`

The orchestrator authored the frozen block on 2026-10-11 from the record
shapes in the live 123b worker transcript. It fails today at its first
assertion, because the reader counts a split message twice. A throwaway
reference implementation (not committed) passed every block, kept
`agent-activity-smoke.sh` and `dashboard-liveness-smoke.sh` green, and
read the real 123b transcript as 10.18M tokens over 66 turns in 12 points,
97% cached.

## Out of scope

- The TUI. Its total corrects itself through the reader; a TUI sparkline is
  a later card.
- Burn in the fleet-wide aggregator pass, for the cost reason card 146 gave.
- Keeping a series after the agent exits; settled figures live in the cost
  log.
- An expandable large chart per agent; one cell per live agent.
- Splitting `cached` into cache creation and cache reads.

## Budget

- **Worker wall-clock:** 40 minutes
- **Verifier wall-clock:** 25 minutes
- **Spend basis:** `state/cost-log.jsonl` on 2026-10-11, worker median 1.1M
  and p95 3.9M, verifier median 1.3M and p95 4.2M tokens. Planning
  allowance 6M tokens, subject to live admission. No cap change or drain
  is authorised by this card.

## Dispatch envelope

Write `state/envelopes/149-the-dashboard-draws-the-burn.json` using
`schemas/envelope.json`. List changed deliverables, the exact smoke commands
and their results, the three `Live burn` cells from deliverable 5 as text,
and any criterion you could not satisfy with why. Do not self-verify or
land your own branch. The verifier writes
`state/verifiers/149-the-dashboard-draws-the-burn.json` under the existing
verifier contract, giving a criterion-by-criterion verdict.

## Family-specific notes

The worker is a Codex seat under `workspace-write`. Every input it needs is
in the tree or in the smoke's fixtures; nothing here needs the real
transcripts, and the worker should not copy one into the envelope.
Criteria 3 and 4 belong to the verifier, because only a Claude seat has a
transcript under `~/.claude/projects/<run-worktree-slug>/` while it runs.
macOS `date` has no `-d`; the smoke already falls back for both.
