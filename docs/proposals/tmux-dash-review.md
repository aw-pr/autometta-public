# Tmux dashboard review: the Autometta fleet and repo panes

Read-only design review, 2026-08-24. Everything below was read from the live
tree at `/Users/AnthonyWest/repos/autometta`, the five subscriber repos, and
`~/.phat-controller/`. Nothing was edited.

## What the instrumentation shows today

### Fleet pane (`autometta-autometta`, window `fleet`)

- **Renderer:** `scripts/attach.sh` `render_fleet_once`, looped by
  `fleet_ticker` every 5s (`PHAT_CONTROLLER_STATUS_TICKER_INTERVAL`).
- **Data:** only `~/.phat-controller/dashboard/data.json`, written by
  `scripts/aggregate-dashboard.sh`, which walks every subscriber's
  `state/state.yaml`, `state/budget.json`, `state/cost-log.jsonl`,
  `state/verifiers/*.json` and runs `scan-usage-limits.sh` over
  `state/logs/*.log` (24h mtime window). A tmux background job
  (`--fleet-refresh`) regenerates it every 120s while the session lives.
- **Sections:** header + generated-at age, TOTALS, REPOS table, ALERTS
  (fleet union), optional OVERLAP. Emits **zero colour**.
- **Failure modes, all observed:**
  1. **Stale alerts persist by construction.** Stage alerts are any stage
     whose status is in `alert-statuses.sh` (`failed`, `verifier_failed`,
     `stalled`). Those are terminal statuses that sit in `state.yaml` until
     someone requeues or supersedes the card, so a May failure renders
     identically to one from this morning (emergence-lab's
     `05-math-formula-rendering`, verifier_failed 2026-05-26, is still on
     the pane). No timestamps reach the alerts table at all.
  2. **Prose as provider-limit alerts.** `scan-usage-limits.sh` phrase-matches
     log text; the two current autometta "provider-limit" rows are markdown
     prose from cards 45/46 quoted inside worker logs ("**Why the last
     attempts died.** Attempt 1 hit the Claude session limit.", "no rate
     limits, no").
  3. **Wrapping.** The detail column is printed with `printf %s`, never
     truncated, so a long detail wraps and misaligns everything below it.
  4. **Queue-empty rendered as an alert**, one row per healthy idle repo,
     burying real failures.
  5. **No per-repo isolation in the aggregator.** `aggregate-dashboard.sh`
     runs under `set -euo pipefail`; `state_yaml_to_json` is a bare
     `yq -o=json`. Autometta's own `state/state.yaml` is **corrupt right
     now** (a stage block for card 51 was appended *after* the trailing
     top-level keys `last_tick_at`/`tick_count`, at 16:09Z; `.bak` and
     `.pre-reorder` siblings sit next to it), `yq` exits 1, and the next
     aggregator run dies mid-fleet. `fleet_refresher` swallows that
     (`>/dev/null 2>&1 || true`), so `data.json` silently stops updating
     and the pane only admits it after the 600s stale threshold. One bad
     repo freezes the whole fleet view.
  6. **Duplicated TOTALS / dead space.** One TOTALS block is printed; the
     second one in the screenshot is a residue/duplication artefact of the
     repaint, and the bottom ~60% of the pane is blank because the frame is
     short and nothing uses the space (no running-agent detail, no history).
  7. Nothing on the pane names the **live agent** (stage 48's claude worker
     is registered in `state/active-agents/50983.json` and flagged fresh by
     the heartbeat, and appears nowhere), and nothing names the **drain**
     (`~/.phat-controller/drain.json` is in force right now: cap 250M, all
     repos, expires 23:53Z; no renderer reads it - the only `drain` grep hit
     in `agent-ticker.sh` is the word "drained" in a comment).

### Per-repo status pane (pane 0)

`scripts/status-ticker.sh`: `status.sh --repo <path>` table plus a global
COMPLETED panel (parses every subscriber's `state.yaml` as text), 5s loop,
pane-fitted and tear-free since card 44 (frame built first, one
`\033[H...\033[J` write, python `fit()` truncation). Monochrome.

### Log pane (pane 1)

`tail -f` of the newest `~/.phat-controller/log/tick-*.log`, grepped for
lines naming the repo path. Falls into a bare shell when no log exists.

### Agent ticker (pane 2)

`scripts/agent-ticker.sh`: ALERTS, SPEND (bounded 5000-row tail of
`cost-log.jsonl` + `budget.json`), ACTIVE (heartbeat entries + registry +
incremental transcript token reads from `~/.claude/projects` /
`~/.codex/sessions`), LIVE (worker log tail while `in_progress`), RECENT
(`state/recent-agents/`, 7d cap), SCHEDULED (`list-cards.sh`). Pane-fitted
and tear-free.

**Colour bug worth naming:** the python bodies emit ANSI red for alerts and
failed RECENT rows, but `render_once`'s `fit()` does
`return plain if len(plain) <= width` on the ANSI-**stripped** string - the
escapes are removed on every line, fitting or not. The reds are written and
never displayed. `repo-ticker-proto.py`'s `fit()` is the correct version
(truncates on printable width, keeps escapes, `NO_COLOR` fallback); it is a
prototype wired into nothing.

### Web dashboard

`dashboard/` (index.html, dashboard.js, Chart.js vendored) renders the same
`data.json` on demand via `autometta dashboard`. Out of scope here beyond
noting that any field the fleet pane needs must land in `data.json` first,
because the fleet ticker is contractually forbidden from walking repos.

## What each repo holds

**autometta** - 34 parseable stages: 27 completed, 1 failed
(`36-ship-fixes-and-recover-emergence-lab`), 1 in_progress
(`48-refresh-all-repos-and-warn-when-stale`, live claude worker pid 50983,
registered and heartbeat-fresh), 5 pending (49, 50, 52a follow-ons, 54...),
plus the orphaned card-51 block stranded below the trailing top-level keys
that makes the file invalid YAML. Budget 138.3M/150M spent (92%, nearing
cap), not halted, 0 consecutive failures. Cost log: 48 rows, ~$98.51 today.
Two false provider-limit alerts from card 45/46 log prose.

**emergence-lab** - 44 stages: 33 completed, 7 pending (58-64), 1 failed
(`16-sandpile-larger-slower`), 1 stalled (`15-boids`, 2026-08-23), 2
verifier_failed (`14-fractal-colour-cycle-pacing` 2026-08-23 and
`05-math-formula-rendering` from **2026-05-26**, three months stale). Budget
3.6M/100M, clean counters. The May failure is the poster child for
undated alerts. Three sibling subscribers (`-gpu`, `-surface`, `-surface-v2`)
are `.disabled`; `emergence-viewer-deep-zoom.yaml` is enabled:false.

**aegis-guardrails** - 1 completed stage, empty queue, 0/100M spent, last
dispatch 2026-08-13. Healthy and idle; today it earns a queue-empty "alert".

**agentic-rag-kimble** - same shape: 1 completed stage, empty queue, 0/100M,
last dispatch 2026-08-14. Healthy and idle.

**fractals-from-the-90s** - 22 completed plus one stage with status `done`,
a status no script's vocabulary knows (not completed, not alert-worthy: it
is invisible to every counter). 8M cap, 0 spent this window, idle since
2026-07-26.

**Host** - `~/.phat-controller/`: 5 enabled subscribers; `drain.json` active
(operator drain, cap 250M fleet-wide, started 15:53Z, self-expires 23:53Z);
no pane shows it, and the REPOS window column still shows resting caps
(458M total), so the fleet is deliberately over-window tonight and the
dashboard would call it an overrun if anyone taught it to look.

## Recommended dashboard

### Per-repo traffic light

One glyph column at the left of each fleet row: `●` painted green, amber or
red (fallback text `ok` / `WARN` / `FAIL` when colour is off). Rules, worst
condition wins, every input a field that exists today:

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
- `tokens_spent / token_cap_total >= 0.85` (autometta is at 92% now)
- alert-status stages older than the 24h freshness bound (real, but history)
- drain in force covering this repo (deliberate, but the operator should
  see the raised cap while it lasts)
- heartbeat `checked_at` older than 600s while stages are in flight

**GREEN**: none of the above. Sub-states shown in the state column:
`run <stage>` when `in_flight > 0`, `queued n` when pending work waits,
`idle` when the queue is empty (a value, never an alert - card 49 already
decided this).

Fleet-level lights on the header line: data age (red past stale limit),
DRAIN banner (amber while `drain.json` is unexpired, naming cap and expiry),
build drift (amber, already computed).

### One line per repo

Replace the current REPOS table with rows of fixed, truncating columns:

```
● repo(22) | state(24) | q(5) | window(13) | today(14) | last(5)
```

`state` is the most informative single fact: the running stage id (with role
and elapsed), or `idle 10d`, or `HALTED: <reason>`. The constant `running`
column dies. Exact figures stay reachable in `data.json`, per cards 41/44.

### LIVE vs HISTORY, in place of one ALERTS table

- **ATTENTION (live)** - recomputed every refresh from current file state,
  disappears the moment the file no longer says it: halts, over-cap,
  failure-cap, fresh failures (<24h), stuck/over-budget agents, unreadable
  state, stale data. This is what the traffic lights summarise; the section
  is the detail behind a red or amber light. Renders one quiet `(none)`
  line when empty.
- **HISTORY (recent events, bounded)** - newest first, hard cap ~8 rows,
  7-day window: old terminal failures with an age column (`vf 92d` for the
  May stage), provider-limit hits with the log mtime as their timestamp and
  the reset time where the banner carries one, recent passes. Old failures
  never dress as live problems again, and the dead bottom of the pane
  finally earns its keep.

### Column and width discipline

- Every cell truncated **at source** to its column width with a trailing
  ellipsis; the detail column last so truncation costs least. No rendered
  line may exceed the pane width; card 49 criterion 4 already demands the
  capture-based proof at 80 and 120 columns.
- Provider-limit detail is normalised at scan time to a short phrase
  ("claude session limit, resets 18:50"), never a raw log line, and card
  prose never reaches the table once the scanner is banner-anchored.
- Below ~100 columns, drop `today` before `window`; below 80, fold `state`
  onto a second indented line rather than wrapping (the status-ticker
  compact-row precedent).

### Colour mechanics

- One shared helper, `scripts/colour.sh`, sourced the way
  `alert-statuses.sh` is: `tput setaf`-based, disabled when not a tty, when
  `tput colors < 8`, or when `NO_COLOR`/`NO_COLOUR` is set; glyphs fall back
  to `ok/WARN/FAIL` text so the frame is identical in shape either way.
  `repo-ticker-proto.py` already contains the correct pattern (paint,
  strip_ansi, printable-width fit).
- Fix `agent-ticker.sh`'s `fit()` to preserve escapes instead of stripping
  them from every line; its panels already emit red that nobody sees.
- Colour is emphasis, never the only signal: the word (`HALTED`, `stalled`,
  `92%`) always carries the meaning.

### Delete outright

- The duplicated TOTALS block: print once, at the top, and end every frame
  with erase-below so no residue survives.
- Queue-empty as an alert row (queue column value, amber cell at most).
- The `enabled` column (only enabled repos render; disabled ones are a
  footnote count).
- The constant `running` state string.
- Dead space: HISTORY and a RUNNING section absorb it; remaining blank rows
  are simply blank, but the frame should not be 40% shorter than the pane
  while three sections' worth of known facts go unshown.

## ASCII mockup

Proposed fleet pane at 120 columns. Colour noted per line in brackets;
`●` green, `◐` amber, `○` red in the glyph column.

```
autometta 6be77a9  fleet  16:12:04Z   data 45s   DRAIN cap 250M all repos, expires 23:53Z (7h40m)      [header dim; DRAIN amber]
TOTALS  5 repos   today 111.3M tok / $100.00   window 141.9M / 458M (drain 250M)                       [dim; drain figure amber]

  st  repo                    state                     queue  window          today            last
  ◐   autometta               run 48-refresh-all-repos  5      138.3M/150M 92% 107.8M  $98.51   3m     [amber: 92% of cap]
      └ claude worker  pid 50983  4m49s/90m  30.1M tok  +1.2M/min                                      [green detail row]
  ◐   emergence-lab           queued 58-kernel-preset   7      3.6M/100M   4%  3.6M    $1.49    15h    [amber: aged failures]
  ●   aegis-guardrails        idle 11d                  0      0/100M      0%  0       $0.00    11d    [green]
  ●   agentic-rag-kimble      idle 10d                  0      0/100M      0%  0       $0.00    10d    [green]
  ●   fractals-from-the-90s   idle 29d                  0      0/8M        0%  0       $0.00    29d    [green]

ATTENTION (live, clears when resolved)
  (none)                                                                                               [dim green]

HISTORY (7d window, newest first, max 8)
  16:05  autometta        52-a-reset-time-just-past     pass         verifier PASS, $0.62               [dim]
  y'day  emergence-lab    15-boids-density-motion       stalled 25h  worker exceeded wall clock         [amber]
  y'day  emergence-lab    14-fractal-colour-cycle       vf 24h       FAIL crit 3: pacing regression     [amber]
  aug23  autometta        46-verifier-bake-off          limit 25h    claude session limit, reset 18:50  [amber]
  may26  emergence-lab    05-math-formula-rendering     vf 92d       requeue or supersede               [dim amber]

Refresh: 5s                                                                                            [dim]
```

Red variants (not on screen today, rules above): a `HALTED: budget` state
cell, a failure younger than 24h, `state unreadable` for the corrupt
`state.yaml` case, and the `data 1240s STALE` header once the aggregator
stops writing.

## Implementation path

Smallest change per win, mapped to the files that exist:

1. **Aggregator survives one bad repo** (`aggregate-dashboard.sh`): wrap the
   per-subscriber body so a `yq` failure yields
   `{name, state_error: "unparseable state.yaml"}` and continues; the fleet
   renderer paints that row red. This is urgent and observed live today;
   without it every other improvement renders stale data.
2. **Timestamps into `data.json`** (`aggregate-dashboard.sh`): stages
   already carry `started_at`/`completed_at` through; add log mtime to each
   `scan-usage-limits.sh` alert row (`find -newer` data is already in hand)
   so ages need no new walker. Card 49 deliverable 4 assumes exactly this.
3. **Traffic-light column + LIVE/HISTORY split** (`attach.sh`
   `render_fleet_once`): pure presentation over fields data.json will then
   hold; the rules table above is the spec and each rule is one `jq` test.
4. **Colour helper** (`scripts/colour.sh`, new, shared): sourced by
   `attach.sh`, `agent-ticker.sh`, `status-ticker.sh`; port
   `repo-ticker-proto.py`'s paint/fit pattern to bash once.
5. **Fix `agent-ticker.sh` `fit()`** to keep escapes (three-line change,
   mirrors the proto's `fit`).
6. **Drain visibility** (`attach.sh` header + `aggregate-dashboard.sh`):
   read `budget_drain_active` from `budget.sh` or the file directly; one
   amber banner line and an adjusted effective-cap figure.
7. **RUNNING detail** on the fleet pane: needs the aggregator to copy
   `state/active-agents/*.json` summaries into `data.json` (the fleet
   ticker must not walk repos); flag this seam - card 49 asks for the
   section but its inputs list reads the registry directly, which its own
   one-walker constraint forbids.

**What card 49 already covers** (do not duplicate): section restructure
(RUNNING/QUEUE/FAILURES/LIMITS), queue-empty reclassification, banner-anchored
`scan-usage-limits.sh` with negative fixtures, ages on FAILURES/LIMITS,
no-wrap truncation, colour with `NO_COLOR` fallback, relative-time formatter,
REQUIRED ACTIONS section, box-drawing tables, tail-erase repaint, and
`fleet-pane-smoke.sh`. What I would change in 49: (a) require the
LIVE/HISTORY separation explicitly - its FAILURES section still mixes a 92-day
verifier_failed with this morning's unless a freshness bound is stated;
(b) name the data.json seam for RUNNING rather than implying a registry read;
(c) bound FAILURES/HISTORY to a row count; (d) reconsider deliverable 9's
box-drawing borders at 39-column panes - a ruled header and right-aligned
numerics earn their keep, full `┌┬┐` borders spend six columns the narrow
panes do not have.

**Proposed follow-up stage card: "fleet pane traffic lights"** (queued after
49 lands, since it builds on 49's sections):

- **Objective:** the restructured fleet pane still requires reading every
  row to answer "is the fleet fine". Give each repo a single computed
  status light with explicit rules, separate live conditions from history,
  surface the host drain, and make the aggregator survive one unparseable
  subscriber instead of freezing the whole fleet silently.
- **Deliverables:**
  1. `scripts/repo-light.sh` - one function mapping a repo's data.json
     entry to `green|amber|red` plus a reason string; the rules table from
     this review, each rule readable from named fields; sourced by the
     fleet renderer and available to `status.sh`.
  2. `aggregate-dashboard.sh` - per-subscriber failure isolation: a repo
     whose state cannot be read appears as `state_error`, and the run
     still writes data.json for the rest; drain fields
     (`drain_active`, `drain_cap`, `drain_expires_at`) from
     `budget_drain_active`; per-alert timestamps.
  3. `render_fleet_once` - light glyph column, ATTENTION (live, recomputed,
     empty renders as one quiet line) and HISTORY (7d, newest first, max 8
     rows, aged) replacing the single ALERTS union; DRAIN banner; single
     TOTALS.
  4. `scripts/fleet-lights-smoke.sh` - fixtures per rule, both colour and
     `NO_COLOR` renderings captured.
  5. `docs/dashboard.md` documents the rule table verbatim.
- **Acceptance criteria (house style):**
  1. Against a fixture fleet holding one halted repo, one over-85%-cap
     repo, one repo with a 3-day-old verifier_failed, one idle-clean repo
     and one whose state.yaml is truncated mid-block, the lights read
     red, amber, amber, green, red respectively, and each reason string
     names the rule that fired.
  2. The truncated-state fixture still yields a data.json naming every
     other repo, and the pane renders the broken repo as a red
     `state unreadable` row rather than a stale frame.
  3. With a fixture drain.json in force the header names the lifted cap
     and expiry; with it expired or absent, no banner.
  4. A condition cleared in the fixture between two renders leaves
     ATTENTION on the second render; a 6-day-old failure appears in
     HISTORY with its age and not in ATTENTION.
  5. No rendered line exceeds 80 or 120 columns in the respective
     captures; TOTALS appears exactly once per frame.
  6. With colour available the three lights are visibly distinct; with
     `NO_COLOR=1` the same frame carries `ok/WARN/FAIL` text. Both
     captured.
  7. `fleet-lights-smoke.sh` passes and every existing offline smoke
     script still passes; `sdk-cache-smoke.sh` needs live credentials and
     is not run: say so.
- **Out of scope:** the per-repo tickers (44), section order and scanner
  anchoring (49), the web dashboard, anything that writes to a subscriber.

Separately, and not part of any pane card: autometta's `state/state.yaml`
needs repairing by hand (move the card-51 block back inside `stages:` above
`last_tick_at`), and `fractals`' stray `done` status wants normalising to
`completed` - both are one-line operator fixes the corrupt-state red light
would have surfaced.
