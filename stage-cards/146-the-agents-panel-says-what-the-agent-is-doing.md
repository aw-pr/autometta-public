# Stage card 146: the agents panel says what the agent is doing

## Metadata

- **Authored:** 2026-10-09
- **Orchestrator:** Claude Fable 5.1 <claude-fable-5-1@local>
- **Worker:** GPT-5.6 Sol <gpt-5-6-sol@local>
- **Verifier:** Claude Fable 5.1 <claude-fable-5-1@local>
- **Base branch:** dev
- **Run branch:** autometta/146-the-agents-panel-says-what-the-agent-is-doing
- **Worker effort:** high
- **Verifier effort:** medium
- **Verifier panel:** false
- **Gate:** stage-completed: 145-a-claude-dispatch-streams-its-log
- **Path claims:** scripts/lib/transcript-tokens.py, scripts/aggregate-dashboard.sh, scripts/lib/tui/render.py, scripts/lib/tui/app.py, dashboard/dashboard.js, scripts/agent-activity-smoke.sh, docs/observability.md, docs/dashboard.md
- **Pairing rationale:** display work takes the premium pairing by standing
  operator feedback (2026-08-25): cheaper tiers softened their own display
  smokes on card 66, so Sol writes the panel and Fable judges what the
  operator will look at. Verifier effort stays at the fleet default because
  the contract test carries the mechanical checks and the verifier's own
  eyes carry the rest; Fable's weekly window stood at 68% when this card
  was designed, and a second attempt has to stay affordable.

## Surfacing concern

While a worker runs, the TUI's agents panel says who is running, for how
long, against what budget, and a transcript token total. It does not say
what the agent is doing. The harness transcripts already do: the stage 144
Claude transcript holds 64 assistant records with 37 timestamped tool calls,
and a Codex rollout from 2026-10-08 holds 129 tool-call items and 130
cumulative usage records. `scripts/lib/transcript-tokens.py` already finds
and reads both, incrementally, every five seconds in the aggregator's
`--repo` mode, and throws away everything but the usage. The operator asked
for progress at a finer grain than "running"; the data is on disk and the
reader is already open. This is a reader card, not a transport card.

## Objective

Each live agent in the `--repo` seam carries an `activity` object derived
from its transcript: turns taken, tool calls made, the last tool and what it
was pointed at, and when. The TUI agents panel and the web dashboard render
it, with an honest blank when nothing has been read. Settled accounting is
untouched.

## Inputs (read these in your own context)

- `scripts/agent-activity-smoke.sh`: the frozen contract and the fixture
  record shapes; read it first.
- `scripts/lib/transcript-tokens.py`: the reader you are extending, and its
  registry-cached offsets.
- `scripts/aggregate-dashboard.sh`: the `--repo` enrichment block (search
  for `transcript-tokens.py`).
- `scripts/lib/tui/render.py`: `agent_lines` and `live_spend_suffix`.
- `dashboard/dashboard.js`: `renderAgents`.
- `docs/dashboard.md` section "Live figures" and `docs/observability.md`
  section "The TUI".

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/lib/transcript-tokens.py`: alongside `stage_tokens`, each agent
   gains `activity`: `{"turns", "tool_calls", "last_tool", "last_detail",
   "last_at"}`, or `null` when no transcript was read. For claude, turns
   count `assistant` records, tool calls count `tool_use` blocks,
   `last_detail` is the first line of a Bash `command` or the `file_path`
   of a file tool, and `last_at` is the record's `timestamp`. For codex,
   turns count `token_count` events, tool calls count `custom_tool_call`
   and `function_call` response items, `last_tool` is the item's `name`,
   and `last_detail` surfaces the command inside the item's `input` or
   `arguments` where one can be found, else the first 80 characters of it.
   Counts accumulate across the claude branch's incremental reads, so they
   live in the registry entry next to the offset. Timestamps stay in the
   transcript's own ISO form.
2. `scripts/aggregate-dashboard.sh`: the `--repo` seam passes `activity`
   through unchanged for every live agent; the fleet-wide pass is untouched.
3. `scripts/lib/tui/render.py` (and `app.py` only if wiring needs it): the
   agents panel shows `turn N`, the last tool, its age as `Ns ago` / `Nm ago`
   / `Nh ago`, and the detail, fitted to the panel width with the detail
   truncated first. An agent whose `activity` is null shows no counts and no
   zeros; the existing line is left as it is.
4. `dashboard/dashboard.js`: the agents table gains an `Activity` column
   carrying the same facts, blank when absent.
5. `docs/observability.md` and `docs/dashboard.md`: a short paragraph each
   naming the fields, the data path (transcript, reader, registry, seam,
   panel) and the latency bound, which is the five-second poll in `--repo`
   mode and the 120-second fleet snapshot elsewhere.

## Constraints

- The frozen block in `scripts/agent-activity-smoke.sh` is read-only to you.
- The transcript is read incrementally exactly as today; this card adds
  parsing to the bytes already consumed, not a second pass over the file.
- `state/cost-log.jsonl`, `budget.json`, the heartbeat and the tick are
  untouched: activity is display, never billing or state.
- Absence renders as absence. A missing transcript, an unparseable record
  or a tool with no detail never becomes a `0` or an empty-string tool.
- Fits-its-pane discipline from cards 44 and 63: the agent line never
  wraps and never pushes the queued rows out of the panel.
- British English in prose, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. `bash scripts/agent-activity-smoke.sh` passes on the run branch, run by
   the verifier, and `scripts/check-contract-test-gate.sh print
   scripts/agent-activity-smoke.sh` prints the digest recorded below.
2. `scripts/tui-smoke.sh`, `scripts/tui-heartbeat-smoke.sh`,
   `scripts/repo-ticker-smoke.sh`, `scripts/ticker-fit-smoke.sh` and
   `scripts/dashboard-liveness-smoke.sh` still pass; record any failure
   that already exists on the base commit separately, and any new failure
   fails this card.
3. While it is itself the live agent, the verifier runs
   `scripts/aggregate-dashboard.sh --repo <repo-root>` from the run worktree
   and shows its own registry entry carrying an `activity` whose
   `last_tool` is the tool it had just used. The verifier is a `claude -p`
   session whose working directory is the run worktree, so its transcript
   is the one the reader resolves.
4. The verifier renders the TUI run page offline against the smoke's
   payload shape at widths 120 and 180 (`render.render(state, width, 50)`)
   and confirms the agent line fits without wrapping at both, with the
   detail truncated before the tool name or the age.
5. `python3 -m py_compile` passes on both Python deliverables, `node --check`
   on `dashboard/dashboard.js`, and `bash -n` on
   `scripts/aggregate-dashboard.sh`.
6. `git diff --stat` on the run branch touches only the claimed paths.

## Contract test

- **Test file:** scripts/agent-activity-smoke.sh
- **Assertions digest:** `sha256:601bda4aab0720eb69a7596a470af5d30fdaaa8e948c4e5e51d8112151abafcd`

The orchestrator authored the frozen block on 2026-10-09 from real record
shapes. It fails today at its first assertion because the reader emits no
`activity`; the renderer, dashboard and aggregator assertions after it are
reachable and were exercised with the assertions softened. The token-total
assertions in the block already pass and must keep passing.

## Out of scope

- Any change to how a dispatch is launched; card 145 owns the log, this
  card reads the transcript.
- Per-agent activity in the fleet-wide aggregator pass (too costly every
  120 seconds across the fleet; the `--repo` mode is where the TUI reads).
- A history of activity, a per-turn timeline or a scrollable transcript
  view. One line per live agent.
- Reading the streaming log from card 145 instead of the transcript.

## Budget

- **Worker wall-clock:** 40 minutes
- **Verifier wall-clock:** 25 minutes
- **Spend basis:** see the 145-147 batch in `stage-cards/PLAN.md`. Planning
  allowance 15M tokens for the batch, subject to live admission; no cap
  change or drain is authorised by this card.

## Dispatch envelope

Write `state/envelopes/146-the-agents-panel-says-what-the-agent-is-doing.json`
using `schemas/envelope.json`. List changed deliverables, the exact smoke
commands and their results, a captured agent line at 120 and 180 columns,
and any criterion you could not satisfy with why. Do not self-verify or
land your own branch. The verifier writes
`state/verifiers/146-the-agents-panel-says-what-the-agent-is-doing.json`
under the existing verifier contract. After independent PASS the
orchestrator lands this stage before its successor is admitted; if
integration is awaiting, stop the batch there.

## Family-specific notes

The worker is a Codex seat under `workspace-write`. Every input it needs is
in the tree or in the smoke's fixtures; reads of `$HOME` are permitted but
nothing here needs the real transcripts. Criterion 3 belongs to the
verifier because only a claude seat has a transcript under
`~/.claude/projects/<run-worktree-slug>/` while it runs. Do not read other
people's real transcripts into the envelope; the fixture is the evidence.
