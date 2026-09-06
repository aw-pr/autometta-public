# Stage card 107: status says when the loop is not loaded

## Metadata

- **Authored:** 2026-09-06
- **Orchestrator:** Claude Fable 5.1 <claude-fable-5-1@local>
- **Worker:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Verifier:** Claude Opus 5 <claude-opus-5@local>
- **Base branch:** dev
- **Run branch:** autometta/107-status-says-when-the-loop-is-not-loaded
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/status.sh, scripts/status-loop-smoke.sh, stage-cards/107-status-says-when-the-loop-is-not-loaded.md
- **Pairing rationale:** cross-model, single family (re-seated 2026-09-06, see below). The deliverable is that an absence becomes visible; the seat
  that did not write the check is the one to confirm it fires when the
  LaunchAgent is really gone and stays quiet when it is really there.
- **Type:** Instrumentation. Dispatches first because every later card in this batch is something it would have observed.

## Surfacing concern

On 2026-09-03 the fleet tick LaunchAgent had been unloaded for a profiling
trace at 12:04 on the 2nd and never reloaded. Nothing ran for 34 hours. The
dashboard ticker in tmux stayed alive, so the repo looked live, and
`autometta status` printed every subscriber as `idle` with a healthy tick
count (`docs/runs/2026-09-03-evening-watch.md:11` in emergence-lab, the
first row of its blockers table). A stopped loop and a quiet loop were
indistinguishable from every surface an operator reads.

`scripts/status.sh` reads state and budget files and the latest log
(`print_repo`, `:82`); it never asks launchd whether the job that writes
those files exists.

## Objective

`autometta status` states, on its first lines, whether the fleet tick
LaunchAgent is loaded, and if it is not, says so loudly and names the
command that loads it.

## Inputs (read these in your own context)

- `scripts/status.sh`, all of it; it is 238 lines
- `bin/autometta`, the `status`, `install-launchagent` and
  `uninstall-launchagent` cases, for the plist label and path the loop uses
- `~/Library/LaunchAgents/com.autometta.tick.fleet.plist` exists on the
  operator's machine; read its label from `install-launchagent` rather than
  hardcoding the filename

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. `scripts/status.sh` prints a `loop:` line before the repo table:
   `loop: loaded (label, last fire <age>)` when `launchctl list` shows the
   fleet label, and `loop: NOT LOADED -- run: autometta install-launchagent`
   (or the exact reload command the operator uses) when it does not. The
   last-fire age comes from the newest `~/.phat-controller/log/tick-*.log`
   line, and an age over three times the plist interval reads as a warning
   even when the job is loaded.
2. The same line appears in the compact form used by the ticker, if
   `status.sh` has one; do not add a second code path.
3. `scripts/status-loop-smoke.sh`: with `launchctl` stubbed on `PATH` to
   report the label absent, the line says NOT LOADED and exits 0 with the
   table still printed; stubbed present, it says loaded; with a stale log,
   it warns. Frozen block around those three assertions.

## Constraints

- No new dependency; `launchctl` is already what installs the job.
- `status` must still work on a host with no LaunchAgent installed at all
  (a fresh subscriber checkout), reading NOT LOADED, not erroring.
- Do not change the repo table's columns; `tui-smoke` asserts widths.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. `autometta status` on the operator's machine prints the `loop:` line
   first and it agrees with `launchctl list | grep autometta`.
2. With the agent unloaded (`launchctl bootout gui/501/<label>`, then reload
   it afterwards, the loop is live) the line reads NOT LOADED and names the
   reload command.
3. `scripts/status-loop-smoke.sh` passes and its stubbed-absent case fails
   against the pre-change `status.sh`.
4. `scripts/tui-smoke.sh` is no more red than on clean `dev`.

## Contract test

- **Test file:** scripts/status-loop-smoke.sh
- **Assertions digest:** frame the assertions in a block between the begin
  marker and the end marker, the begin marker naming this card by its
  `card=stage-cards/107-status-says-when-the-loop-is-not-loaded.md` field, and replace this line's text with the real
  digest printed by `scripts/check-contract-test-gate.sh print scripts/status-loop-smoke.sh`. Do not
  write a `sha256:` comment inside the block, and do not spell the marker
  tokens anywhere in this card's prose; the card is in your path claims for
  exactly this edit.

## Out of scope

- Making the tick reload itself. A loop that resurrects itself hides the
  operator's decision to stop it.
- The dashboard ticker; card 87 covers what its panes claim.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes

## Escalation

If `status.sh` turns out to be invoked from a context where `launchctl`
is unavailable (a Linux subscriber, a sandboxed verifier), print
`loop: unknown (launchctl unavailable)` rather than NOT LOADED, and say so in
the envelope. A false alarm on every Linux host is the cry-wolf failure this
card exists to avoid.

## Verifier handoff

Run `autometta status` yourself with the agent loaded and unloaded
(criterion 2 requires the unload; reload it before you finish and confirm
with `launchctl list`). Run the smoke against the pre-change script from
`git show dev:scripts/status.sh` to confirm it has something to catch.
Disbelieve a `loop:` line that is computed from the log alone: stub
`launchctl` to lie and confirm the line follows launchd, not the log.

## Family-specific notes

None

## Re-seat (2026-09-06, Codex subscription exhausted)

Both Codex seats were unavailable from 10:31Z with the subscription window
closed until 14:49Z, and every card in this batch carried one, so the queue
could not move. On the operator's instruction the batch was re-seated onto
Claude alone: high-effort cards run Opus as worker and Sonnet as verifier,
the rest run Sonnet as worker and Opus as verifier, so worker and verifier
are never the same model.

What this keeps: the sandbox boundary, which is what makes worker
self-verification structurally impossible, is a property of the dispatch and
not of the vendor, so it is untouched. What it costs: judgement diversity.
A Claude verifier shares training and failure modes with a Claude worker in
a way a Codex verifier did not, so a wrong assumption the worker makes is
likelier to survive verification. Two different Claude models recover part
of that and not all of it. Read this card's acceptance criteria as needing
more, not less, evidence than usual.

## Re-brief (attempt 2, 2026-09-06, after the Codex subscription closed mid-write)

Attempt 1 was not judged. Its worker was refused by the provider partway
through the run, at 77,488 tokens, and never wrote an envelope: there is no
verdict on this card and nothing below is a criticism of the work.

The work is real and it is preserved at
`4676fdd6aa8e8b5d7187ba7f239c99f78847f9d6` on
`wip/107-status-says-when-the-loop-is-not-loaded-attempt-1`. Restore it
rather than starting over. It carries 131 insertions across three files:

- `scripts/status-loop-smoke.sh`, new, 61 lines.
- `scripts/status.sh`, +75, including a `latest_controller_log` helper
  extracted from an inline loop.
- this card, where the contract-test digest line was edited.

Two things attempt 1 did not reach, both of them the end of the job rather
than a defect in what exists:

1. **The digest is a placeholder.** The card's contract-test line reads
   `sha256:TO_FILL`. Run `scripts/check-contract-test-gate.sh print
   scripts/status-loop-smoke.sh` and put the real digest there. Attempt 1
   wrote the literal `TO_FILL` string into the card and stopped; leaving it
   is an automatic gate failure.
2. **Nothing was run.** Neither the new smoke nor the reworked `status.sh`
   was executed once. Run the smoke, and run `scripts/status.sh` against
   both states the card cares about: the fleet LaunchAgent loaded, and
   bootted out.

This stage is also re-seated. The worker is now Claude Sonnet 5 and the
verifier Claude Opus 5; the batch runs on one family until the Codex window
reopens, and the card's re-seat note says what that costs. Nothing in the
deliverables or the acceptance criteria changed.
