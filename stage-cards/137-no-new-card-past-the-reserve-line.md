# Stage card 137: no new card starts past the reserve line

## Metadata

- **Authored:** 2026-09-19
- **Orchestrator:** Claude Fable 5.1 <claude-fable-5-1@local>
- **Worker:** Claude Fable 5.1 <claude-fable-5-1@local>
- **Verifier:** none (interactive orchestrator change, smoke-verified)
- **Base branch:** dev
- **Run branch:** dev
- **Worker effort:** high
- **Dispatch:** interactive
- **Pairing rationale:** Codex was at 100% of its 5-hour window when this
  was raised and the change is the guard that stops that being spent on
  dispatch, so it was made in the orchestrator session rather than queued
  behind the window it protects. The contract smoke is the verifier.
- **Type:** Harness defect. Touches `scripts/quota-window.sh`,
  `scripts/spawn-worker.sh` and two lines of `scripts/tick.sh`.

## Surfacing concern

On 2026-09-19 the operator found Codex at 100% of its 5-hour window with
the plan drawing on purchased top-up credit, and asked for a hard line: no
new card starts past 80% of a session window, for either family, on by
default, switchable off. The mechanism already existed
(`window_reserve` in the controller mandate, card 54 onwards, scheduled by
124 and 135) and this host had it set to 25% hold. Two things kept it from
being that line.

First, it was off by default. The template ships `percent:` empty and
`quota_reserve_settings` resolved empty, absent or unparseable to `0 off`.
A host that never answered the setup question, or a fresh machine, had no
reserve at all, and the only clue was one word in a log line nobody reads
until the window is gone.

Second, only the tick applied it. `scripts/spawn-worker.sh` is the one
door every worker goes through, and it never looked at the reading. The
tick gates before it calls spawn-worker, so loop dispatch was covered; an
orchestrator dispatching by hand (the documented manual pattern in
`CLAUDE.md`) was not. The morning's burn itself came from interactive
Codex sessions, which no autometta guard can or should touch, but the same
gap would let a manual dispatch start a 30-minute worker at 99%.

## Objective

The reserve is on unless the operator turns it off, and every worker
spawn honours it. Default 20% unspent, action `hold`: no new card starts
once any reported window of that family (5-hour or weekly) is at or past
80%. An explicit `percent: 0` or `action: off` in the mandate switches it
off; an unanswered or invalid value takes the default. The default lives
in the mandate file, which `init-host` now installs from the template; a
host with no mandate at all (every fixture controller home in the smokes)
stays off, so the contract suite never reads the host's live quota through
a default it did not ask for. A manual spawn past
the line exits 4 with the window, the reserve and the override named, and
writes nothing. The tick keeps its own gate and its pause-until-reset
behaviour unchanged.

## Deliverables

1. `scripts/quota-window.sh`: `QUOTA_RESERVE_DEFAULT_PERCENT=20`,
   `QUOTA_RESERVE_DEFAULT_ACTION=hold`; `quota_reserve_settings` resolves
   an empty or invalid `percent` and an unknown `action` to the default.
   Valid zero and `off` still disarm; no mandate file is still off.
   `scripts/init-host.sh` installs the template mandate. New
   `quota_spawn_permits <repo> <family>`: the pure form of the tick's
   gate (no pause, no write) for a spawn outside the tick, honouring
   `AUTOMETTA_IGNORE_RESERVE=1` and `AUTOMETTA_RESERVE_GATED=1`.
2. `scripts/spawn-worker.sh` calls `quota_spawn_permits` before any
   auth resolution or launch and exits 4 on a hold, naming the override.
3. `scripts/tick.sh` sets `AUTOMETTA_RESERVE_GATED=1` on both of its
   spawn-worker call sites, because it has already applied the gate this
   tick and a refusal from spawn-worker would halt the repo with a
   `dispatch-configuration-fault`.
4. `templates/phat-controller-mandate.yaml.tpl`, `templates/phat-controller-seed.md.tpl`,
   `scripts/render-controller-seed.sh`, `docs/tick-loop.md`,
   `docs/runbook.md`, `CLAUDE.md` (manual dispatch pattern): the prose
   says the default is 20% hold and how to switch it off.
5. `scripts/reserve-default-smoke.sh` passes.

## Constraints

- Verifier spawns are not gated at the spawn level: a verifier finishes a
  card that is already in flight, and the tick's own verifier gate and
  `reserve_exempt` handling are unchanged.
- No new reading, poller or network request. The manual gate reads the
  same snapshot files the tick reads.
- Unknown readings fail open on both paths, as before.

## Acceptance criteria

1. `bash scripts/reserve-default-smoke.sh` passes.
2. `bash scripts/quota-window-smoke.sh`, `bash scripts/reserve-schedule-smoke.sh`
   and `bash scripts/session-window-smoke.sh` pass, and
   `bash scripts/check-contract-test-gate.sh --worktree` reports their
   digests unchanged.
3. With the shipped template copied in unanswered, `quota_reserve_settings`
   prints `20\thold`; with no mandate file it prints `0\toff`.
4. `grep -n 'AUTOMETTA_RESERVE_GATED=1' scripts/tick.sh` finds both
   spawn-worker call sites and nothing else.
5. `bash -n` passes on every touched shell file.

## Contract test

- **Test file:** scripts/reserve-default-smoke.sh
- **Assertions digest:** `sha256:9b86408b7085bc299feaf43901c2f17d3c943fc5a36c1f12cb573ea39f04a392`

## Out of scope

- Gating interactive Codex or Claude sessions. The reserve protects
  dispatch; a person at a prompt is outside it by design.
- A per-repo override of the default. The mandate is host-wide and the
  window is host-wide.
- The external-dependency bootstrap (the quota publisher, op-fetch,
  agent-whoami) that a fresh machine needs before this reading exists at
  all: see `docs/proposals/external-dependencies.md`.
