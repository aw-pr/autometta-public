# Stage card 109: a worker retrying a dead API is not working

## Metadata

- **Authored:** 2026-09-06
- **Orchestrator:** Claude Fable 5.1 <claude-fable-5-1@local>
- **Worker:** Codex GPT-5.6 Sol <codex-gpt-5-6-sol@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Base branch:** dev
- **Run branch:** autometta/109-a-worker-retrying-a-dead-api-is-not-working
- **Worker effort:** medium
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/tick.sh, scripts/stall-kill-smoke.sh, docs/tick-loop.md, stage-cards/109-a-worker-retrying-a-dead-api-is-not-working.md
- **Pairing rationale:** cross-family, and the Codex seat writes the transcript-reading code
  because the transcript format belongs to the other vendor's CLI; a Claude
  verifier can produce a genuine `claude -p` transcript with `api_error`
  rows to test it against.
- **Type:** Stall detection and cleanup. Touches `scripts/tick.sh`, so serial.

## Surfacing concern

Stage 75's first worker on 2026-09-03 rendered its frames by 22:38 and
then spent 46 minutes on 40 `Request timed out` errors and ten exhausted
retries, alive and idle, until the wall-clock stall at 45 minutes plus 50%
grace cut it at 23:24 (`docs/runs/2026-09-03-evening-watch.md:23` in
emergence-lab). A `claude -p` worker writes nothing to its log until exit,
so an hour of retries was indistinguishable from work. When the stall
finally fired, `kill -TERM "$worker_pid"` at `scripts/tick.sh:2736` hit the
spawn wrapper only; the `claude` child (pid 58489) survived and had to be
killed by hand.

The transcript under `~/.claude/projects/<escaped-worktree-path>/*.jsonl`
does record every API error as it happens.

## Objective

The stall check reads the worker's transcript and stalls a worker whose
recent history is API errors rather than tool calls, and the stall path
terminates the whole process group so no child survives it.

## Inputs (read these in your own context)

- `scripts/tick.sh:2700-2760`, the stall check and its kill
- `scripts/spawn-worker.sh:251-256`, how the Claude worker is started, and
  whether the wrapper puts it in its own process group (`setsid` or a
  subshell with `set -m`)
- `~/.claude/projects/` on the operator's machine: pick any worktree
  transcript and read the row shapes for `api_error` and for a tool call,
  so the classifier reads real fields
- `docs/tick-loop.md`, the stall section

Do not read anything else unless you need to; keep your context lean.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. `scripts/tick.sh`: during the stall check for a Claude worker, locate
   the transcript for the run worktree and count rows in the last N minutes
   (N = 10, overridable by `AUTOMETTA_API_ERROR_WINDOW_MIN`). If that window
   holds at least five `api_error` rows and no tool-call row, log
   `stage <id> stalled: <k> api errors and no tool call in <N> min` and take
   the existing stall path. A missing transcript is not evidence of
   anything; skip silently.
2. The stall path terminates the process group of the worker (or the
   wrapper plus every descendant found via `pgrep -P`, recursively) and
   confirms with `kill -0` after a short grace, escalating to KILL. Apply the
   same to the verifier stall path.
3. `scripts/spawn-worker.sh`: if the wrapper does not already start the
   agent in its own process group, make it so; record the pgid alongside the
   pid in the active-agents registry if the registry has a slot for it.
4. `scripts/stall-kill-smoke.sh`: (a) a fixture transcript with six
   `api_error` rows in the window and no tool call makes the check stall the
   stage; (b) a transcript with errors interleaved with tool calls does not;
   (c) a fixture wrapper that spawns a `sleep` child is stalled and the child
   is gone afterwards. Frozen block around those assertions.
5. `docs/tick-loop.md`: the stall section states the API-error rule and the
   process-group kill.

## Constraints

- The transcript is read-only input; never write under `~/.claude`.
- The rule is errors *and* no progress. Errors interleaved with tool calls
  are a slow network, not a stall.
- Codex workers have no such transcript; the check must skip them without
  logging noise.
- Do not change the wall-clock stall threshold.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. Fixture (a) stalls the stage and the log names the count; fixture (b)
   does not stall; a stage with no transcript is untouched.
2. After a stall, `pgrep -f` for the worker's command line returns nothing
   within five seconds; the smoke's `sleep` child is gone.
3. `scripts/stall-kill-smoke.sh` passes and cases (a) and (c) fail against
   the pre-change `tick.sh`.
4. `scripts/tui-smoke.sh`, `scripts/tick-cost-smoke.sh` and
   `scripts/state-writable-smoke.sh` are no more red than on clean `dev`.

## Contract test

- **Test file:** scripts/stall-kill-smoke.sh
- **Assertions digest:** `sha256:c275eaafa8e6bc2c97aa35e7c944495b55375b2c73723fbf83c3cd7a85068ce6`

## Out of scope

- Restarting a worker after a network stall; card 108 prevents the next
  dispatch while the network is dead, and the re-queue is the operator's.
- Reading Codex transcripts.

## Budget

- **Worker wall-clock:** 90 minutes
- **Verifier wall-clock:** 45 minutes

## Escalation

If the transcript path cannot be derived deterministically from the
worktree path (Claude Code escapes it; check two real examples), report
the ambiguity and fall back to the newest transcript whose first row's
`cwd` matches, and say so.

## Verifier handoff

Make a real transcript: run `claude -p` in a scratch directory with the
network blocked (`--dangerously-skip-permissions` is not needed) and confirm
the rows it writes match what the classifier reads. Then kill test: start
the fixture wrapper, let the smoke stall it, and check with `ps` that no
descendant survives. The likely wrong pass here is a classifier that
counts any row containing the string `error`; feed it a transcript whose
tool results mention errors and confirm it does not stall.

## Family-specific notes

None

## Seat history (2026-09-06)

The Codex subscription closed at 10:31Z and this batch was re-seated onto
Claude alone; when Claude session windows then drained faster than the batch
was sized for, the verifying seat moved to the free local route
(`gpt-oss:120b` via `codex exec --oss`). The Codex window reopened the same
afternoon and the card is back on the seats it was authored with. Nothing
about the work changed across either move.
