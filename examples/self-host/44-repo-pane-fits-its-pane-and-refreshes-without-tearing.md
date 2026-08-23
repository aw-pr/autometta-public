# Stage card 44-repo-pane-fits-its-pane-and-refreshes-without-tearing: the per-repo viewer renders 36 lines into a 15-row pane and blanks itself for three seconds out of every five

## Metadata

- **Authored:** 2026-08-23
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Fable 5 <claude-fable-5@local>
- **Worker effort:** medium
- **Verifier effort:** medium
- **Verifier panel:** false
- **Worker wall-clock:** 60 minutes
- **Verifier wall-clock:** 30 minutes
- **Pairing rationale:** asks 1, 2 and 4 are presentation over data that
  already exists, which is the cheaper Codex tier's ground, exactly as cards
  38 and 41 reasoned. Ask 3 is the exception: it reads a new source and can
  quietly invent a number, so the verifier should check an in-flight figure
  against the same agent's own transcript rather than accept the pane's word
  for it.

## Objective

Card 41 made the fleet pane readable. The per-repo viewer, which is where the
operator actually watches one run, did not get the same treatment and is
worse off than the fleet pane was.

Four asks. Ask 1 is the one that makes the other three visible at all.

## Reported by

Operator, reading `autometta-emergence-lab` on 2026-08-23 at 18:32Z while
stage `57-interestingness-sweep-harness` was in flight, and comparing it with
the `autometta-autometta` fleet pane on the same screen.

### Ask 1: the panels the operator needs are the ones that scroll off the top

The per-repo session's panes are small. Measured on the reporting machine:

```
autometta-emergence-lab  pane 0  40x32   status-ticker.sh
autometta-emergence-lab  pane 1  39x16   tick log tail
autometta-emergence-lab  pane 2  39x15   agent-ticker.sh
```

`scripts/agent-ticker.sh` emitted 36 lines into that 15-row pane. The
terminal keeps the last 15, so what survived on screen was the tail of RECENT
and the whole of SCHEDULED, including three unqueued card names and an "and
20 more". What scrolled away was, in order, Health, ALERTS with five entries
including two `verifier_failed` stages and a `stalled` one, SPEND, ACTIVE and
LIVE. The pane spent its whole render budget showing the least urgent panel
it has and threw away every panel that answers "is anything wrong".

`scripts/status-ticker.sh` in pane 0 has the matching fault in the other
axis: `scripts/status.sh` prints rows of about 110 columns into a 40-column
pane, so each row wraps three ways and the header wraps with it. On the
screenshot the emergence-lab row was there and unreadable.

Render to the pane the renderer is actually in. Take the width and height
from the terminal, not from a constant, and when the content does not fit,
drop or fold the least urgent panel rather than letting the terminal choose
by scrolling. Urgency order is the operator's: what is wrong, what is
running, what it is costing, what ran recently, what is queued. A panel that
has been trimmed should say it was trimmed, with the count it is hiding, so
the pane never quietly under-reports.

The fleet pane is 80 columns wide and reads acceptably. That is why it looks
fixed and this one does not, so do not treat the fleet pane's current
formatting as evidence that fixed widths are fine.

### Ask 2: money and token figures do not match the fleet pane

`agent-ticker.sh` SPEND, rendered live during the reported session:

```
SPEND (USD estimates use list prices)
  window: 12521044 / 100000000 tokens (12.52%)
  today: $7.177687000000001 est  |  7d: $68.145769 est
  mean cache hit today: 38.7%  |  last hour: 0 tokens/h
```

`$7.177687000000001` is float noise from a jq `tostring`, not a figure.
`12521044 / 100000000` is the raw form card 41 replaced with `12.5M/100M` in
the fleet rows. Card 41 put this panel out of scope and asked the fleet rows
to match its formatting, which was the right call then and reads as backwards
now: bring the panel to the fleet pane's units and two decimal places.

The exact figures must stay reachable somewhere, as card 41 required.

### Ask 3: a running agent's token count reads zero for the whole run

ACTIVE, at 1815 seconds into a live Claude worker:

```
ACTIVE
  claude  worker  terestingness-sweep-harness.md pid 87973  1815s  tokens:0  log:0B  fresh
```

Both figures are correct and both mislead. `claude -p` writes nothing until it
exits (lessons.md gotcha 6), so the log is genuinely 0 bytes and the ticker's
log-scraping parser has nothing to scrape. The pane therefore prints
`tokens:0` for the entire life of every Claude dispatch, which is the one
number an operator watching an overnight run wants and the one it cannot
give. A worker that has burned tens of millions of tokens and one that has
burned none render identically.

The figure exists. Both CLI families write a live session transcript with
per-message usage:

- Claude Code: `~/.claude/projects/<path-slug>/<session-uuid>.jsonl`, one
  object per message with a `usage` block. For the reported worker that file
  was being appended to as the pane was read, and summing its usage blocks
  gave 30,074,356 tokens against the pane's `tokens:0`.
- Codex: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`.

Give ACTIVE an in-flight token figure from that source for both families, or
say plainly that it is unavailable. `tokens:0` is the one answer that is not
acceptable, because it is indistinguishable from a real zero.

Two things make the lookup harder than it looks, and the worker should solve
them rather than guess around them:

- The Claude slug is derived from the **run worktree** path
  (`-Users-...-emergence-lab-run-57-interestingness-sweep-harness`), not from
  the repo root, because card 39 gave every run its own worktree.
- `state/active-agents/<pid>.json` records pid, family, role, card, log and
  `started_at`, and does **not** record the working directory the agent was
  launched in. That is the field that keys the Claude transcript, and adding
  it at registration is a smaller and more honest fix than reconstructing the
  slug from a card id.

Codex rollouts are not keyed by path at all, so matching one to a pid needs a
deliberate answer; `started_at` is already in the registry.

### Ask 4: the refresh blanks the pane for most of every cycle

Both tickers loop as `clear; render; sleep 5`. Measured on the reporting
machine:

```
status-ticker.sh --once   0.32s
agent-ticker.sh --once    3.72s
```

So the agent pane is cleared and then drawn a panel at a time over three and
a half seconds, and is a partially drawn pane for about three quarters of
every five-second cycle. That is what a reader sees as flicker, and it is why
a screenshot of the status pane caught a table header with no rows under it.
It also destroys the scrollback each cycle and moves the cursor about while
the operator is trying to read.

Repaint each frame in one write over the previous one, rather than clearing
to blank and drawing into the gap. Build the frame first, then put it on
screen in a single pass. Keep the refresh interval and keep the "Refresh: Ns"
footer, this is about how a frame is painted, not how often.

Whether a slow render deserves a smaller interval, a longer one, or a
first-paint-then-refill is the worker's call, but a pane that is never
observed half-drawn is the acceptance bar.

## Inputs (read these in your own context)

- `scripts/agent-ticker.sh` - all five panels, the render loop, and the
  ACTIVE token parser that scrapes logs.
- `scripts/status-ticker.sh` - the second render loop, and the COMPLETED
  panel it adds to `status.sh`.
- `scripts/status.sh` - `print_repo`, whose `printf` widths are the wrapping.
- `scripts/attach.sh` - `render_fleet_once` for the formatting to match, and
  the pane layout that fixes these geometries in the first place.
- `scripts/register-agent.sh` and its callers in `scripts/spawn-worker.sh`,
  `scripts/spawn-verifier.sh`, `scripts/spawn-verifier-panel.sh` - for ask 3's
  missing field.
- `scripts/claude-token-log.sh` and the `--output-format json` dispatch in
  `spawn-worker.sh` - why nothing lands in the log until exit.
- A live transcript under `~/.claude/projects/` and one under
  `~/.codex/sessions/`. Read a real one before designing the parser.
- `scripts/repo-ticker-proto.py` - a working prototype of all four asks,
  written while this card was drafted and wired into nothing. It resolves a
  transcript for both families, tracks the total incrementally from a byte
  offset, fits 39x15, and repaints in one write. Read it for the shape of the
  answer, not as the answer: it is a long-lived Python process, and the two
  shipped tickers are bash that re-spawns a dozen subprocesses per frame.
- `scripts/ticker-spend-smoke.sh` and `scripts/alerts-table-smoke.sh` - the
  fixture style to follow.
- `docs/observability.md`, `docs/cost-log.md`, `docs/dashboard.md`,
  `MANUAL.md`, `docs/lessons.md` gotcha 6.

## Deliverables

- `scripts/agent-ticker.sh` - fit to pane, spend formatting, in-flight
  tokens, tear-free repaint.
- `scripts/status-ticker.sh` and `scripts/status.sh` - fit to pane, tear-free
  repaint. Keep `status.sh` usable on its own at a full-width terminal.
- `scripts/register-agent.sh` and its callers, if ask 3 takes the recorded
  working directory route.
- `scripts/ticker-fit-smoke.sh` - new. Asserts the pane-fit and repaint
  behaviour and the spend formatting, against fixtures.
- `docs/observability.md`, `MANUAL.md`, and `docs/lessons.md` if the
  transcript route earns a gotcha.

## Constraints

- Read-only on every repo, adopter repos included, apart from the
  `state/active-agents` field ask 3 may add.
- No new walker and no new daemon. The two tickers stay the only per-repo
  renderers, as cards 38 and 41 required.
- Bounded refresh cost. A transcript file reaches tens of megabytes within one
  long run, so read a bounded tail or track an offset. Do not parse a whole
  transcript every five seconds, and do not make the render slower than it is
  now.
- Fail soft on every new source. No transcript, an unreadable one, or a family
  with no equivalent must degrade to a stated unknown, never to a crash and
  never to a zero.
- The transcript directories belong to the harnesses and are read-only here.
  Nothing in this repo writes to them, and nothing depends on their being
  present.
- Both families throughout. A fit that only works for Claude, or an in-flight
  figure only Codex can produce, fails the two-family invariant.
- Do not change what counts as an alert, what is queued, or any budget.
- British English, no em dashes.

## Acceptance criteria

1. In a pane of 39 columns by 15 rows, `agent-ticker.sh` shows the alert
   panel and the running agent, no line wraps, and any panel it dropped or
   truncated is named with the count it is hiding. Demonstrate by rendering at
   that size, not by reading the code.
2. In a pane of 40 columns, the `status-ticker.sh` repo row is readable with
   no wrapped line, and at 120 columns it still shows the fields it shows
   today.
3. SPEND shows money to two decimal places and token counts in the fleet
   pane's short units, and the exact figures remain reachable. One figure
   checked against a hand computation from `state/cost-log.jsonl`.
4. For a live agent of each family, ACTIVE shows a token figure that matches
   that agent's own transcript within a stated tolerance, or states that the
   figure is unavailable. A Claude worker with a 0-byte log must not render
   `tokens:0`. Show a real dispatch or a fixture transcript, and show the
   unavailable path too.
5. Neither ticker is ever observed half-drawn: capture the pane repeatedly
   across several refresh cycles and show that every capture is a complete
   frame. Report the render time of each ticker before and after.
6. `scripts/ticker-fit-smoke.sh` passes, and every existing offline smoke
   script still passes. `sdk-cache-smoke.sh` requires live API credentials and
   is not run: say so.

## Out of scope

- The fleet pane's own renderer and its formatting, which card 41 settled.
  Match it; do not rewrite it.
- The tmux pane layout and sizes in `attach.sh`. This card makes the
  renderers fit whatever pane they are given.
- The web dashboard under `dashboard/`.
- Switching the Claude dispatch to `--output-format stream-json`. The
  transcript is readable without touching how workers are launched, and
  changing the dispatch format would put every budget parse at risk for a
  display figure.
- Budgets, caps, halt logic, and what counts as alert-worthy.

## Budget

- **Worker wall-clock:** 60 minutes
- **Verifier wall-clock:** 30 minutes

## Notes for the worker

- Do ask 1 first. Asks 2 and 3 are invisible until the panels they touch
  survive the render.
- Resist a fixed 80-column layout as the fix. The pane is 39 columns, and
  the next operator's pane is some third number.
- On ask 3, read a real transcript before designing anything. Sum the usage
  keys rather than assuming one of them is the total: cache reads dominate a
  long run and dropping them understates spend by an order of magnitude. The
  two families need different arithmetic: Claude records per-message usage, so
  the total is a running sum; Codex records a cumulative `total_token_usage`,
  so the total is the last one seen. Summing the Codex figure would multiply
  it by the turn count.
- Resolve the transcript on every frame until it is found, and cache only a
  success. A CLI does not create its transcript when it execs: op-fetch, the
  prompt assembly and CLI start-up put seconds between the registry entry
  appearing and the first transcript byte. The prototype cached that first
  miss and pinned the pane to "tokens unavailable" for the rest of the run,
  which is the same defect as `tokens:0` wearing a different label. Say
  "waiting" during the opening seconds and "unavailable" only once the wait
  is no longer normal, so the two cases are not one message.
- `repo-ticker-proto.py` settles three questions the worker would otherwise
  spend the budget on. The agent's working directory, which keys the Claude
  transcript, comes from `lsof -a -p <pid> -d cwd` without touching the
  registry. Codex rollouts carry their `cwd` in the `session_meta` first line,
  so they are matched by reading one line per recent file and caching the
  index. A run worktree is reused across dispatches, so its Claude project
  directory holds the previous agent's transcript too, and the file has to be
  chosen by mtime against `started_at` rather than by being the only one
  there.
- Criterion 6 excludes `sdk-cache-smoke.sh` deliberately: it needs
  `ANTHROPIC_API_KEY` and this repo bills on the subscription route. Cards 39
  and 41 both burned a verifier attempt on that wording before it was fixed.
