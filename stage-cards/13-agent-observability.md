# Stage card 13-agent-observability: Per-agent liveness registry, heartbeat watchdog, and tmux agent ticker

## Metadata

- **Authored:** 2026-05-27
- **Orchestrator:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Worker:** Claude Opus 4.7 <claude-opus-4-7@local> (manual orchestrator-led build; same-family rationale: design is the orchestrator's, scope is mechanical scaffolding, no behavioural questions for a separate worker to discover)
- **Verifier:** deferred to operator (cross-family verifier dispatch via Sonnet would re-cover the same ground; the new heartbeat surface is itself the verification mechanism for future dispatches and is best exercised against a real future dispatch)
- **Pairing rationale:** Same-family by exception. The card 13 work is itself the new dispatch observability — verifying it cross-family before any real dispatch uses it would just exercise empty registries. Operator review on commit, then real verification happens on the next dispatched stage.

## Surfacing incident

On 2026-05-27, dispatching the Sonnet verifier for card 12 failed silently: the `--permission-mode bypassPermissions` flag combined with `-p` produced a 0-byte log and an exited process. The orchestrator only noticed when the operator asked "is the worker stuck?" — there was no automated surfacing.

Separately, the tmux viewer (`autometta-<repo>`) is read-only on `state.yaml` and tick logs. Once an orchestrator-internal dispatch (codex exec / claude -p, launched directly by the orchestrator session rather than `spawn-worker.sh`) is in flight, the viewer has no record of it.

## Objective

Add three things:

1. A **per-agent liveness registry** at `state/active-agents/<pid>.json` written by every dispatched agent (worker or verifier). A reaper moves expired entries to `state/recent-agents/` with an outcome. Registration is the responsibility of whichever script dispatches the agent; a `scripts/register-agent.sh` helper exists so manual orchestrator dispatches (codex exec / claude -p launched from a session) can join the registry too.

2. A **heartbeat watchdog** at `scripts/heartbeat.sh`, invoked once at the top of every tick. It checks each active agent for process liveness, log-mtime staleness (default 300 seconds), and budget overrun. Findings are written to `state/heartbeat.json`. The watchdog never kills anything — surfacing only.

3. A **tmux agent ticker** at `scripts/agent-ticker.sh`, suitable for tailing in a third tmux pane. Refreshes every 5 seconds; shows ACTIVE agents (with stall/over-budget flags from the heartbeat), RECENT agents (last 5, with outcomes), and SCHEDULED cards (parsed from the repo's stage-card globs).

`scripts/attach.sh` adds (or replaces) a third pane in the `autometta-<repo>` session that runs the ticker.

## Inputs (read these in your own context)

- `scripts/spawn-worker.sh` — current worker dispatch path.
- `scripts/spawn-verifier.sh` — current verifier dispatch path.
- `scripts/tick.sh` — to wire the heartbeat call after `acquire_repo_lock` and before `_process_repo_locked`.
- `scripts/attach.sh` — to add the third pane.
- `state/state.yaml` — for resolving stage card globs via the existing `manifest_patterns` function.

## Deliverables

Paths are relative to the autometta repo root.

1. `scripts/heartbeat.sh` — new. Args: `<repo_root>`. Walks `state/active-agents/*.json`; for each entry:
   - If `kill -0 $pid` fails, the agent is gone — move the entry to `state/recent-agents/` with `outcome: exited` (the real outcome is set by the reaper in `tick.sh` if it sees a verifier artefact or non-empty diff; heartbeat is conservative).
   - If `now - log_mtime > heartbeat_stall_seconds` (default 300), flag `silent`.
   - If `now - started_at > expected_budget_seconds` (parsed from the card or registry entry), flag `over-budget`.
   - Writes `state/heartbeat.json` with one entry per active agent and the timestamp. Idempotent.
   - Exit 0 always; this is a watchdog, not a gate.

2. `scripts/register-agent.sh` — new. Args: `<repo_root> <pid> <role> <family> <identity> <card_path> <log_path> [<budget_seconds>]`. Writes `state/active-agents/<pid>.json` with all fields plus `started_at` and a generated `agent_id` (UUID-shaped from `pid + nanos` for trace correlation). Idempotent on re-call for the same pid (updates `started_at`).

3. `scripts/agent-ticker.sh` — new. Args: `<repo_root> [--once]`. Default behaviour: loop forever, refreshing every 5 seconds; with `--once`, print once and exit. Output sections:
   - `ACTIVE`: one line per active-agent file, joined with the heartbeat findings.
   - `RECENT`: last 5 entries from `state/recent-agents/` sorted by exit time, with outcome.
   - `SCHEDULED`: stage-card glob walk, classified `done | in_flight | pending` against PLAN.md status table (when present) and `state/active-agents/`.

4. `scripts/list-cards.sh` — new. Helper used by the ticker's SCHEDULED section. Args: `<repo_root>`. Walks `manifest_patterns` (defined in `tick.sh`), classifies each card, emits a `card_id\tstatus` table. Stand-alone callable.

5. `scripts/spawn-worker.sh` — modified. After computing `pid`, call `register-agent.sh` with the worker's identity and the parsed wall-clock budget. On main() exit before `printf '%s\n' "$pid"`, registry write succeeded.

6. `scripts/spawn-verifier.sh` — modified. Same pattern as 5, with `role=verifier`.

7. `scripts/tick.sh` — modified. After `acquire_repo_lock` and the existing `ensure_tmux_viewer` call, call `heartbeat.sh "$repo_root"`. Also: when reaping an exited worker / verifier (the existing `kill -0` reaper), move `state/active-agents/<pid>.json` to `state/recent-agents/<pid>-<stage_id>.json` with the real outcome (`completed | verifier_failed | stalled | exited`).

8. `scripts/attach.sh` — modified. When creating a fresh session, split a third pane (vertical on the right pane) running `scripts/agent-ticker.sh "$repo_path"`. When `--ensure` is used and the session exists but lacks the ticker pane, add it. Idempotent.

9. `examples/self-host/PLAN.md` — modified. Add a row for stage 13. Also fix the stage 12 row to reference commit `d5a13a1` (replacing `pending`).

10. `memory/decision-agent-observability-registry.md` — new. Decision memory recording why registration is per-agent rather than centrally tracked, why the heartbeat surfaces rather than kills, why the ticker is in tmux rather than a separate process or daemon.

11. `docs/observability.md` — updated. New "Per-agent liveness registry" subsection documenting `state/active-agents/`, `state/recent-agents/`, `state/heartbeat.json`. New "Agent ticker" subsection documenting the third tmux pane. `Authoritative surfaces` list extended.

## Acceptance criteria

1. `scripts/heartbeat.sh /tmp/empty-repo` exits 0 with no error when `state/active-agents/` is empty or absent.
2. After registering a synthetic active agent (pid of a `sleep 600`, log path `/tmp/test-log` touched 600s ago, budget 60), heartbeat output flags both `silent` and `over-budget`.
3. After killing that sleep, the next `heartbeat.sh` run no longer lists the agent under ACTIVE; entry has moved to `state/recent-agents/` with `outcome: exited`.
4. `scripts/spawn-worker.sh` dispatched against a test card writes `state/active-agents/<pid>.json` before backgrounding; file contains `role: worker`, the identity from the card, and the parsed budget.
5. `scripts/spawn-verifier.sh` mirrors 4 with `role: verifier`.
6. `scripts/register-agent.sh` is callable standalone; running it with the args produced by an orchestrator-internal `codex exec` registers the agent and the ticker picks it up.
7. `scripts/agent-ticker.sh --once` prints three sections (ACTIVE / RECENT / SCHEDULED), each with a header line, even when sections are empty.
8. `scripts/attach.sh --ensure` against an existing session without a ticker pane adds the third pane; against a session with the pane, it is a no-op.
9. `tick.sh` calls `heartbeat.sh` exactly once per repo per tick, before `_process_repo_locked`.
10. The cd-fix at `9e282f3` is not reverted (regression guard).
11. `docs/observability.md` and `memory/decision-agent-observability-registry.md` reflect the shipped interfaces, with no orphan references.
12. PLAN.md row for stage 12 lists `d5a13a1`; row for stage 13 lists this stage's commit (filled in by orchestrator).
13. No files outside the deliverables set are modified — except this stage card itself.

## Out of scope

- Killing or restarting stalled agents. The heartbeat surfaces only; the operator decides.
- A persistent agent-trace database. `state/recent-agents/` is a flat directory; rotation/compaction is a follow-up if it ever matters.
- Integrating with the dashboard renderer. The dashboard reads `data.json` from the aggregator; cost is its concern, liveness is the ticker's.
- Pushing notifications elsewhere (Slack, email, etc.). Out of scope.

## Budget

- **Worker wall-clock:** 30 minutes (orchestrator-led; same-family rationale above).
- **Verifier wall-clock:** n/a — operator review at commit.
