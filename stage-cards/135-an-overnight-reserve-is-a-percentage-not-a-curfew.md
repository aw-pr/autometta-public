# Stage card 135: an overnight reserve is a percentage, not a curfew

## Metadata

- **Authored:** 2026-09-11
- **Orchestrator:** Claude Fable 5.1 <claude-fable-5-1@local>
- **Worker:** GPT-6 Astra <gpt-6-astra@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Base branch:** dev
- **Run branch:** autometta/135-an-overnight-reserve-is-a-percentage-not-a-curfew
- **Worker effort:** high
- **Verifier effort:** medium
- **Verifier panel:** false
- **Dispatch:** serial
- **Pairing rationale:** Astra-assessment card. The 2026-09-12 weekend slate
  puts GPT-6 Astra in the worker seat on every hard card across the fleet,
  cross-family verified by Claude, to turn two data points (emergence-lab
  stages 88 and 90) into a measured verdict. This card is a subtle
  control-plane bug in bash with an orchestrator-written oracle, the shape
  Astra did well on in stage 88. Sonnet verifies: the oracle is executable,
  so the verifier's job is to run it and to check the pre-change failure,
  not to exercise judgement the card has already exercised. Serial because
  it touches `scripts/tick.sh`.
- **Type:** Harness defect. Touches the dispatch path, so serial.

## Surfacing concern

Card 124 gave `window_reserve` a schedule so a run could spend the session
down overnight and leave the operator a session by day. It did that by
making one block do two jobs. `quota_reserve_settings`
(`scripts/quota-window.sh:155-200`) reads `overnight.start`/`end` to pick
which percentage applies now. `quota_schedule_permits_dispatch`
(`scripts/quota-window.sh:229-262`), called for every worker at
`scripts/tick.sh:222`, reads the same `start`/`end` as a hard dispatch window
and refuses any new worker outside it. Nothing in the block says "and stop
outside these hours"; declaring a percentage for the night declares the
curfew with it. Card 124's amendment accepted this knowingly ("once a
schedule is declared, the loop starts no new work outside the window"), and
`docs/tick-loop.md:518-540` documents it.

It was the wrong call, and it has now cost a run. On 2026-09-07 the
emergence-lab operator armed "80% cap from 01:00" as an overnight block to
express a *reserve* percentage. The tick then logged, every five minutes
from 21:01:

```
schedule stop worker 82 (claude): clock 21:01 is outside the 01:00-06:00
dispatch window; it next opens at 01:00; no new dispatch this tick
```

The whole run had been confined to 01:00-06:00, the opposite of the
instruction, which was to leave 22:00-01:00 uncapped. There is no way to say
"uncapped tonight, capped from 01:00" in the block as it stands. The remedy
that night was to delete the block and hand-install a one-shot LaunchAgent
to raise the top-level percentage at 01:00, which is the exact workaround
card 124 was written to retire. Write-up:
`emergence-lab/docs/runs/2026-09-07-stages-82-86-watch.md`, "19:43-20:03Z".

## Objective

An overnight block moves the reserve percentage and nothing else. The stop
at the window's edge survives as an explicit opt-in key,
`window_reserve.overnight.stop_outside: true`, so a host that wants card
124's curfew asks for it by name and a host that wants a percentage gets a
percentage. The tick's log names both halves on every resolution: which
rule picked the percentage, and whether a curfew is armed.

## Inputs (read these in your own context)

- `scripts/reserve-schedule-smoke.sh`, the frozen oracle; it fails at
  acceptance 2 on clean `dev`, which is correct
- `scripts/quota-window.sh:130-262`, `quota_reserve_settings` and
  `quota_schedule_permits_dispatch`
- `scripts/tick.sh:158-240`, the two gate call sites and the log lines they
  emit
- `scripts/session-window-smoke.sh:40-56`, card 124's scheduled fixture,
  which sits outside that file's frozen block
- `scripts/drain.sh:170-200`, the `--ignore-reserve` refusal that reads the
  window end
- `templates/phat-controller-mandate.yaml.tpl:31-66`, the documented shape
- `docs/tick-loop.md:480-545`, the prose that currently promises the curfew
- `stage-cards/124-a-daytime-run-leaves-the-operator-a-session.md`, for
  what must not regress

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. `scripts/quota-window.sh`: `quota_schedule_permits_dispatch` refuses only
   when `window_reserve.overnight.stop_outside` is literally `true` and a
   valid `start`/`end` pair is declared. Any other value, or no key, permits
   dispatch and sets `QUOTA_SCHEDULE_STOP_REASON` to a reason containing
   `no curfew declared`. A refusal's reason names the window and the key
   `stop_outside`. A `stop_outside` anywhere but inside the `overnight`
   block is ignored. `quota_reserve_settings` is unchanged in behaviour.
2. `scripts/tick.sh`: the per-dispatch log line that names the resolved
   window (`daytime`/`overnight`/`default`/`drain-ignore-reserve`) also
   states `curfew off` or `curfew on <start>-<end>`, so a log with no
   dispatch in it answers the question the 2026-09-07 operator spent twenty
   minutes on. The `reserve_exempt` stamping and the verifier exemption keep
   their current semantics.
3. `scripts/drain.sh`: the `--ignore-reserve` refusal of an `--hours` that
   outlives the overnight window applies only when `stop_outside` is armed.
   Without a curfew a drain outliving the percentage window is harmless and
   must be accepted.
4. `scripts/session-window-smoke.sh`: add `stop_outside: true` to the
   scheduled fixture at lines 41-51 so card 124's frozen assertions, which
   assert the curfew, keep passing unchanged. Do not touch its frozen block.
5. `templates/phat-controller-mandate.yaml.tpl`: the commented shape gains
   `stop_outside` with one sentence saying what it does and that it defaults
   off. `docs/tick-loop.md` and `docs/runbook.md`: the curfew paragraphs say
   it is opt-in, and the sentence "once a schedule is declared, the loop
   starts no new work outside the window" is replaced with the truth.
6. `scripts/reserve-schedule-smoke.sh` passes. Add fixtures or scaffolding
   outside its markers if needed; the frozen block is not yours to edit.

## Constraints

- No default changes for a host that declares no `overnight` block: byte-for-
  byte the same resolution, as card 124 promised.
- No new file, key or mechanism beyond `stop_outside`. Do not add a separate
  `dispatch_window` block; the curfew lives where the window is declared.
- Do not kill an in-flight agent, add a daemon, or touch token-cap logic.
- Do not edit any frozen `AUTOMETTA-CONTRACT` block, in this card's smoke or
  in card 124's.
- Codex sandbox: the smokes need no network and no GUI. If a smoke cannot
  run under `workspace-write`, record the exact error in the envelope rather
  than widening the sandbox.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. `bash scripts/reserve-schedule-smoke.sh` passes on the run branch, and
   the same file fails at "reserve-only schedule permits dispatch at 09:00"
   against clean `dev`. Record both runs.
2. `bash scripts/session-window-smoke.sh` passes, and
   `bash scripts/check-contract-test-gate.sh --worktree` reports its card-124
   digest unchanged.
3. `bash scripts/quota-window-smoke.sh` and `bash scripts/budget-cap-smoke.sh`
   are no more red than on clean `dev`.
4. With the reserve-only mandate from the smoke copied into a scratch
   `AUTOMETTA_HOME`, `AUTOMETTA_SCHEDULE_CLOCK=09:00` and an unknown quota
   reading, `quota_gate_role_dispatch` for a worker returns 0 and the tick
   log for that call contains both the resolved window name and `curfew off`.
5. `grep -n 'stop_outside' templates/phat-controller-mandate.yaml.tpl
   docs/tick-loop.md docs/runbook.md` finds all three, and
   `grep -n 'starts no new work outside the window' docs/tick-loop.md`
   finds nothing.
6. `bash -n` passes on every touched shell file.

## Contract test

- **Test file:** scripts/reserve-schedule-smoke.sh
- **Assertions digest:** `sha256:0ab6479e76e066fd13c4bc7e628413f6b4749113a4a84d4adf23cabc06d92b01`

The file and its frozen block are already written by the orchestrator. Do
not author, extend or edit the block: satisfy it by changing the
implementation. If you become convinced an assertion is wrong, stop and
surface it as a blocker; the verifier recomputes this digest and fails the
stage if the assertions moved.

## Out of scope

- Per-family or per-repo schedules.
- Any change to how the quota reading is taken or to the reserve gate's
  fail-open behaviour on unknown readings.
- The vendor freshness line that shared the 2026-09-07 log with this stop;
  that is card 136.
- Repairing the live mandate at `$AUTOMETTA_HOME`, which is operator-owned.

## Budget

- **Worker wall-clock:** 75 minutes
- **Verifier wall-clock:** 40 minutes

## Escalation

If the frozen assertions cannot be satisfied without changing
`quota_reserve_settings`' output for a mandate that declares no `overnight`
block, stop and report: that output is card 124's byte-for-byte promise and
this card must not trade one regression for another.

## Dispatch envelope

The worker envelope carries the usual `status`, `summary` and touched-file
list, plus an **Astra scorecard** block the slate is scored on:

- `deliverables_landed`: which of deliverables 1-6 are complete on this
  attempt, by number.
- `tokens_used`: the worker's own reading of its total tokens for the
  attempt, from its final usage line.
- `sandbox_blocked`: anything the Codex `workspace-write` sandbox refused
  (command and error text), or `none`.
- `oracle_first_failure`: which assertion in
  `scripts/reserve-schedule-smoke.sh` failed first before your change, so the
  verifier can confirm you ran it before editing.

## Family-specific notes

Codex: the smokes source `scripts/tick.sh` and write only under a
`mktemp -d` fixture and the fixture's `AUTOMETTA_HOME`, which
`workspace-write` permits. Do not pass `--add-dir` for `$HOME/.autometta`;
nothing here should touch the live controller home.
