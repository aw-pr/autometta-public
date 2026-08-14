# Control-plane review — sticky halts, per-repo dash, hygiene (2026-08-01)

Reviewer: Claude Fable 5 (review half; implementation is a separate worker).
Evidence base: the 2026-08-01 evening emergence-lab run — stage
`29-swarmalators-kernel` needed **four** manual state edits (two halt-flag
clears in `budget.json`, one stalled→pending reset in `state.yaml`, one stale
envelope delete) to survive two failures that the controller could have
recovered from itself.

Implementer notes: work in a **worktree** of this repo (the main tree is
dirty and its own subscriber is halted on that). Subscribing repos vendor
their own copies, so nothing here reaches a live loop until the operator
refreshes (`autometta subscribe <repo>` / the repo's `autometta-vendor-check.sh`);
`~/repos/emergence-lab` has a live worker tonight — do not touch it.

---

## 1. Sticky halts and repair semantics

### 1a. Self-clearing halts when the cause is gone

**Where:** `scripts/budget.sh` — `budget_check_caps()` (line 47) returns `2`
the moment `.halted == true` without ever re-testing the cause;
`scripts/tick.sh` lines 583–592 turn that `2` into a log line and a
`return 0`. That is the whole sticky-halt bug: tonight `dirty-working-tree`
stayed set after the tree was cleaned by commits, twice.

**Change:** add `budget_try_autoclear <repo_root>` to `budget.sh`, called
from the tick gate when `budget_check_caps` returns `2`:

- Read `.halt_reason`. Re-testable reasons:
  - `dirty-working-tree` → clear iff `git -C <repo> status --porcelain -- . ':(exclude)state'`
    is empty **and** no stage has a live `worker_pid` (guard below).
  - `token-cap` → clear iff `.tokens_spent < .token_cap_total` (covers the
    operator raising the cap, which tonight also needed a hand-edit of the flag).
  - `tick-cap` → clear iff `.clock_ticks_used < .clock_tick_cap`.
- Non-retestable reasons stay manual: `consecutive-failures` (clearing it
  would re-run the exact thing that failed three times), `wall-clock-cap`
  (elapsed never decreases), `manual`, unknown strings.
- On clear: `budget_write_atomic` the three halt fields back to null/false and
  `log "halt cleared for <repo>: <reason> no longer holds"` — the transition
  must be visible in the tick log.

**Edge cases:**
- A live worker legitimately dirties the tree. The dirty-tree halt is only
  *set* when `current_stage` is empty (`tick.sh` ~355–365, see the comment
  block there), but autoclear must still check for a live `worker_pid` before
  clearing, because a stage can be `in_progress` while the halt predates it.
- Do not autoclear inside `budget_check_caps` itself (it is called from
  several contexts, including `status.sh` render paths); keep the mutation at
  the single tick call site.
- `--reset-halt` (`reset_halts_mode`, `tick.sh:55–78`) stays as the blunt
  manual override; autoclear subsumes its common use but not its semantics.

**Verify:** fixture repo under `/tmp`: set `halted=true, halt_reason=dirty-working-tree`
with a clean tree → one tick clears it and dispatches; repeat with a dirty
tree → halt survives; repeat with `halt_reason=consecutive-failures` and a
clean tree → halt survives.

### 1b. Implement `--repair` (it is currently a stub)

**Where:** `scripts/tick.sh` lines 51–53: `repair_mode()` logs
"repair not yet implemented, no-op". Tonight's operator ran it expecting a
requeue and got nothing — worse than missing, it reads as "repaired".

**Change:** `repair_mode` iterates enabled subscribers (reuse
`sort_subscribers`), and for each repo:

1. Run `budget_try_autoclear` (1a).
2. For every stage with `status` in {`stalled`, `failed`} and
   `repair_attempts` (new integer field, default 0) `< 2`:
   - Confirm the stage card still resolves via the manifest's
     `stage_card_globs` (`manifest_patterns`, `tick.sh:~105`). If the card is
     gone, set `stall_marker: card_missing` and skip — never requeue
     cardless work.
   - Reset: `status: pending`, `started_at: null`, `worker_pid: null`,
     `verifier_pid: null`, delete `stall_marker`, increment
     `repair_attempts`.
   - Delete `state/handoffs/<id>.json` and `<id>.invalid.json` if present —
     tonight a stale round-1 envelope would have been read as round-2's
     completion signal had it not been hand-deleted.
   - If `.current_stage` names this stage, null it.
3. Reset `consecutive_failures` to 0 only if at least one stage was requeued.
4. Log one line per action; end with a summary count. Exit 0.

The `repair_attempts < 2` bound is the loop-breaker: a stage that stalls
twice after repair stays down for the operator, and the field records that
history in `state.yaml`.

**Edge cases:** never touch `in_progress` stages (a live worker owns them —
the normal tick already demotes dead-pid stages to stalled); never touch
`verifier_failed` (that is a verdict, not an infrastructure failure);
tolerate stages missing the `repair_attempts` field (treat as 0).

**Verify:** fixture with one stalled stage + stale envelope → `--repair`
requeues it, envelope gone, `repair_attempts: 1`; run twice more → stage
stays stalled at cap with a log line saying so.

### 1c. `partial` envelopes must dispatch the verifier

**Where:** `scripts/tick.sh` lines 780–786: `fail|partial` both mark the
stage `failed`, copy the notes into `stall_marker`, and skip the verifier.
The vendored `state/handoffs/README.md` contradicts itself: its table says
partial→fail, its prose says "partial is a worker-side annotation; the
verifier decides acceptability". Tonight a complete, verify-green build was
recorded as a failure because the worker honestly deferred the browser-only
criteria — which is exactly what the prose says it should do.

**Change:** split the case. `fail` keeps today's behaviour. `partial`
follows the `pass` path (verifier dispatch), additionally recording
`worker_envelope: partial` on the stage stanza so the verifier prompt
assembly (`spawn-verifier.sh`) can surface "the worker self-reported
incomplete acceptance — treat the deferred criteria as your checklist" —
pass the envelope `notes` through to the verifier prompt, which
`spawn-verifier.sh` already receives per-stage context for.

**Docs to update in the same change:** `docs/handoff-envelope.md`, the
handoffs README template this repo vendors out (grep for the table text —
it ships from `templates/` or `subscribe-repo.sh`'s heredoc), and the
outcome table in `docs/dispatch-contract.md` if it repeats the mapping.
Vendored copies in subscriber repos update on their next refresh; note that
in the commit message rather than editing other repos.

**Verify:** fixture envelope with `status: partial` → tick dispatches
verifier and stage goes to the verifier-pending state, not `failed`.

---

## 2. Per-repo dashboard scoping

The tmux dash (`autometta attach` / auto-ensured by ticks) is three panes
built in `scripts/attach.sh` (lines ~66–75):

| Pane | Runs | Scope today |
|---|---|---|
| 0.0 status | `status-ticker.sh` → `status.sh` | **global** — every repo |
| 0.1 log | `tail -f` newest `~/.phat-controller/log/tick-*.log` | **global** — includes months of other repos' halt spam |
| 0.2 ticker | `agent-ticker.sh <repo>` | per-repo already, but RECENT shows 65-day-old entries |

**Changes:**

- `status.sh`: accept `--repo <path>`; when given, print the header plus
  only that repo's block (`print_repo` already exists per-subscriber — filter
  the subscriber loop on `repo_path`). `status-ticker.sh` (a thin refresh
  loop, 134 lines) passes the flag through. `attach.sh` builds
  `status_cmd` with `--repo "$repo_path"`.
- `attach.sh` log pane: filter the tail —
  `tail -f "$latest" | grep --line-buffered -F "$repo_path"` — with a fallback
  note line so an empty filter is visibly "no lines for this repo yet", not a
  dead pane. Keep the unfiltered tail in the global view only.
- `agent-ticker.sh` RECENT pane (lines ~167–205): before taking
  `files[:5]`, drop entries older than a cutoff
  (`PHAT_CONTROLLER_RECENT_MAX_AGE_DAYS`, default 7). Print
  `(none in the last 7d)` when the filter empties the list. The ACTIVE and
  SCHEDULED panels are already correctly scoped — leave them.
- When a stage is `in_progress`, the ticker should append a
  `tail -n 8` of `state/logs/<stage>-worker.log` (path helper already exists
  in `status.sh` as `latest_stage_log`) so the per-repo dash shows live work
  without the operator hunting for the log path.
- Bare `autometta dashboard` (aggregate web dashboard, `dashboard/` +
  `aggregate-dashboard.sh`) stays the global view — no changes there.

**Verify:** `scripts/attach.sh --dry-run <repo>` prints the three commands —
inspect flags; `scripts/agent-ticker.sh <repo> --once` with a fixture
`recent-agents` dir containing a 65d-old and a 1h-old entry shows only the
recent one.

---

## 3. Control-plane hygiene

### 3a. Dash session lifecycle

**Where:** `tick.sh:563–569` `ensure_tmux_viewer` runs for **every enabled
repo on every tick**, so idle repos keep resurrected dash sessions forever
(tonight: `autometta-autometta`, `autometta-fractals-from-the-90s` for repos
that have been halted for weeks).

**Change:** ensure the viewer only when the repo has a non-null
`current_stage` (the "actually doing work" test the comment above the
function already claims). Add a reaper pass in the tick main loop: for each
`autometta-<slug>` session (list via `tmux ls -F '#S'`), kill it when the
matching repo is disabled, unsubscribed, **or** has had no `current_stage`
for >24h — but never when `tmux list-clients -t <session>` is non-empty (an
attached operator keeps their session). Slug mapping must reuse
`session_slug()` from `attach.sh` (extract to a shared helper or source it)
so the reaper and the spawner cannot drift.

### 3b. Halt-log spam

**Where:** `tick.sh:590` emits `halted <repo> (reason already recorded: …)`
every 5 minutes per halted repo — ~864 identical lines/day/repo; the July log
is mostly this line.

**Change:** with 1a in place the line only fires for genuinely-standing
halts; additionally dedupe: stamp `halt_logged_at` in `budget.json` when the
line is emitted and suppress re-emission for `PHAT_CONTROLLER_HALT_LOG_INTERVAL`
(default 3600s). Log immediately (and reset the stamp) on any halt-reason
*transition*, including autoclear.

### 3c. Retention

- `~/.phat-controller/log/` is already one file per day (`tick-YYYY-MM-DD.log`)
  — add a sweep at the top of each tick: delete files older than
  `PHAT_CONTROLLER_LOG_RETENTION_DAYS` (default 14).
- `state/recent-agents/*.json`: prune entries older than 30d in the same
  sweep (this also caps what the RECENT pane can ever show).
- `state/logs/*.log`: worker/verifier logs are the audit trail — do not
  delete in v1; gzip files older than 30d. (Tonight's 750KB round-1 worker
  log is typical; the folder grows ~1–5MB per stage.)

**Verify:** run the sweep against a fixture dir with dated files; confirm
attached-client guard by attaching to a dash session and ticking with the
repo idle >24h (session must survive).

---

## Explicitly not changing (looked at, leave alone)

- `spawn-worker.sh` stdin/`</dev/null` handling and the op-fetch auth
  routing — tonight's launchd-spawn startup death is a **separate** bug
  (Codex CLI 0.146 under launchd, still undiagnosed) and is not in scope here.
- `reset_halts_mode` (`--reset-halt`) semantics — kept as the manual
  override.
- The dirty-tree guard itself in `commit_state_branch` (`tick.sh` ~340–370)
  — its in-flight-stage exemption is correct and well-commented; only the
  *stickiness* of the halt it sets is being fixed.
- Verifier attempt caps and `verifier_failed` handling (`tick.sh:820–850`)
  — verdicts are not infrastructure failures; repair must not touch them.
- `sort_subscribers` weight ordering, the state-branch commit flow, and the
  web `dashboard/` app.
- Worker identity/model pinning (`scripts/models.sh`) — operator-owned.

## Suggested commit split for the implementer

1. `budget.sh` autoclear + tick gate call + halt-log dedupe (1a, 3b).
2. `tick.sh` repair_mode implementation (1b).
3. `partial` → verifier dispatch + the three doc updates (1c).
4. `status.sh`/`status-ticker.sh`/`attach.sh` per-repo scoping (2).
5. `agent-ticker.sh` RECENT cutoff + live worker-log tail (2).
6. Viewer lifecycle + reaper + retention sweep (3a, 3c).

Each lands green on its own; shellcheck everything touched
(`shellcheck scripts/*.sh` currently has a baseline — do not add new
warnings).
