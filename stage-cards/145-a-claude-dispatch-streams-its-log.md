# Stage card 145: a claude dispatch streams its log

## Metadata

- **Authored:** 2026-10-09
- **Orchestrator:** Claude Fable 5.1 <claude-fable-5-1@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Base branch:** dev
- **Run branch:** autometta/145-a-claude-dispatch-streams-its-log
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/claude-token-log.sh, scripts/spawn-worker.sh, scripts/spawn-verifier.sh, scripts/register-agent.sh, scripts/heartbeat.sh, scripts/log-streams-smoke.sh, docs/lessons.md, docs/observability.md, docs/cost-log.md, CLAUDE.md
- **Pairing rationale:** Terra for the plumbing, which is a flag change, a
  streaming filter and one heartbeat rule. Opus verifies because this card
  touches both spawn scripts, and a wrong flag on a claude dispatch line
  killed every Claude verifier on the fleet in gotcha 12; the verifier's
  seat runs `claude -p` unsandboxed, so it can run the real flag
  combination through the candidate filter rather than read it. Verifier
  effort is high for the same reason: a dispatch-surface change is judged
  by running it.

## Surfacing concern

Gotcha 6: `claude -p` writes its log in one burst at exit. Every claude
worker and verifier is dispatched with `--output-format json`, which
buffers the whole session and prints one document at the end, so a
twenty-minute Claude dispatch shows a 0-byte log the whole way, the
heartbeat has to exempt the claude family from its `silent` flag, and an
operator tailing the log learns nothing until it is over. Codex streams its
log and gets stall detection for free.

The CLI already offers the fix: `--output-format stream-json` prints one
JSON line per message as it happens, and print mode grants it only with
`--verbose`. The Claude Agent SDK is this same stream in a Python wrapper,
so switching the flag is the whole of what "more granular monitoring" costs
on this family. Measured 2026-10-09 with one real dispatch: nine lines,
`system`/`init` first, each `assistant` message with its own `usage`, a
`rate_limit_event` after each turn, and a final `result` line carrying the
cumulative `usage`, `num_turns` and the result text. stderr stayed empty.

## Objective

Every claude dispatch streams its log as it runs. The stdout filter
forwards progress lines as they arrive and still ends the log with the
`Total tokens: N` line the budget parser reads. The registry records that a
dispatch streams, and the heartbeat applies its `silent` flag to such a
dispatch instead of exempting the whole family. Gotcha 6 is amended to say
what is now true.

## Inputs (read these in your own context)

- `scripts/log-streams-smoke.sh`: the frozen contract; read it first.
- `scripts/claude-token-log.sh`: the filter you are rewriting.
- `scripts/spawn-worker.sh` and `scripts/spawn-verifier.sh`: the two
  claude dispatch lines (search for `claude-token-log.sh`).
- `scripts/register-agent.sh`: the registry writer.
- `scripts/heartbeat.sh`: the `silent` rule (search for `family != "claude"`).
- `docs/lessons.md` gotcha 6, `docs/observability.md` section "Per-agent
  liveness registry", `docs/cost-log.md` row "Claude CLI with JSON output",
  and `CLAUDE.md` headless gotcha 6.

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/claude-token-log.sh`: reads stdin line by line and flushes as
   it goes. For each `assistant` message it writes one short progress line
   naming each `tool_use` block's tool and, for Bash the first line of the
   command and for file tools the path, truncated to one terminal line; any
   `text` block is written as is. `user` tool results, `system` and
   `rate_limit_event` lines are not forwarded. The `result` line yields the
   result text and then exactly one `Total tokens: N` line summing
   `input_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`
   and `output_tokens`. A line that is not JSON passes through unchanged. A
   single `--output-format json` document on stdin, which
   `scripts/phat-controller.sh` still produces, yields the same tail as
   before.
2. `scripts/spawn-worker.sh` and `scripts/spawn-verifier.sh`: the claude
   dispatch lines use `--output-format stream-json --verbose`, with the
   filter still on stdout and stderr still going straight to the log. Set
   `AUTOMETTA_LOG_STREAMS=1` in the environment of the
   `register-agent.sh` call for a claude dispatch.
3. `scripts/register-agent.sh`: when `AUTOMETTA_LOG_STREAMS=1` is set,
   the registry entry carries `"log_streams": true`; otherwise the key is
   absent. No positional argument changes.
4. `scripts/heartbeat.sh`: the `silent` flag applies to an entry whose
   family is `codex`, or whose entry carries `log_streams: true`. A claude
   entry without that key stays exempt, so a manual `claude -p` dispatch
   registered the old way is not misread.
5. Docs: gotcha 6 in `docs/lessons.md` and its one-line form in `CLAUDE.md`
   say the log now streams and name the flag pair; the liveness paragraph in
   `docs/observability.md` describes the per-dispatch rule; the
   `docs/cost-log.md` fidelity row for Claude JSON output names the stream
   format and the result line it reads.

## Constraints

- The frozen block in `scripts/log-streams-smoke.sh` is read-only to you.
  Add fixtures or helpers around it if you must, but a blocker with an
  assertion is reported in the envelope, not edited away.
- `scripts/phat-controller.sh` is not claimed and must not be edited; its
  dispatch keeps `--output-format json`, which is why the filter must still
  accept a single document.
- No change to what the budget parser reads: the `Total tokens:` line keeps
  its exact format, and `budget.sh` is not claimed.
- The heartbeat still never kills for `silent`; this card changes what it
  reports, not what it does.
- British English in prose, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. `bash scripts/log-streams-smoke.sh` passes on the run branch, run by the
   verifier, and `scripts/check-contract-test-gate.sh print
   scripts/log-streams-smoke.sh` prints the digest recorded below.
2. `bash -n` passes on every changed shell file, and
   `scripts/stall-kill-smoke.sh`, `scripts/outlier-warning-smoke.sh`,
   `scripts/tick-cost-smoke.sh` and `scripts/cost-log-smoke.sh` still
   pass; record any failure that already exists on the base commit
   separately, and any new failure fails this card.
3. The verifier runs one short real dispatch through the candidate filter,
   for example `claude -p --output-format stream-json --verbose --model
   claude-haiku-5-5 --max-turns 2 --tools Bash --dangerously-skip-permissions
   "Run echo probe-ok, then reply done" | scripts/claude-token-log.sh >
   /tmp/145-probe.log`, and records that the log named the Bash call and
   ended with a `Total tokens:` line equal to the sum of the four usage
   buckets on the `result` line of the raw stream.
4. `scripts/spawn-verifier.sh --print-transport claude` still resolves to
   `cli` in this repo, and the claude dispatch line in each spawn script
   contains `--output-format stream-json --verbose` and no longer contains
   `--output-format json`.
5. A claude registry entry written by the candidate `spawn-worker.sh` path
   carries `log_streams: true`; the verifier shows this with the smoke's
   registry assertions or by reading the registration call.
6. The four documents in deliverable 5 are updated, say the same thing, and
   none of them still claims the claude log stays at 0 bytes until exit.
7. `git diff --stat` on the run branch touches only the claimed paths.

## Contract test

- **Test file:** scripts/log-streams-smoke.sh
- **Assertions digest:** `sha256:acf4b58aed3c1faac911da9320ee0dd4f5a12537707575f2ee78c04ab4cf71f4`

The orchestrator authored the frozen block on 2026-10-09 from the shape of a
real streamed dispatch. It fails today at its first assertion because the
filter buffers, which is the defect; everything after that assertion is
reachable and was exercised with the assertions softened.

## Out of scope

- Streaming the Codex dispatch: `codex exec` already streams its text log,
  and `--json` is separate work if ever wanted.
- `scripts/phat-controller.sh` and `scripts/spawn-verifier-panel.sh`.
- Tuning `AUTOMETTA_HEARTBEAT_STALL` for claude thinking gaps. After this
  lands, the first long Claude verifier run in the queue (card 146's) shows
  the longest quiet gap; the minder notes it and a later card decides.
- Any reading of the stream beyond progress lines; card 146 reads the
  harness transcript for that.

## Budget

- **Worker wall-clock:** 30 minutes
- **Verifier wall-clock:** 25 minutes
- **Spend basis:** see the 145-147 batch in `stage-cards/PLAN.md`. Planning
  allowance 15M tokens for the batch, subject to live admission; no cap
  change or drain is authorised by this card.

## Dispatch envelope

Write `state/envelopes/145-a-claude-dispatch-streams-its-log.json` using
`schemas/envelope.json`. List changed deliverables, the exact smoke commands
and their results, and any criterion you could not satisfy with why. Do not
self-verify or land your own branch. The verifier writes
`state/verifiers/145-a-claude-dispatch-streams-its-log.json` under the
existing verifier contract, giving a criterion-by-criterion verdict. After
independent PASS the orchestrator lands this stage before its successor is
admitted; if integration is awaiting, stop the batch there.

## Family-specific notes

The worker is a Codex seat under `workspace-write`: it cannot run `claude`
itself, which is why criterion 3 belongs to the verifier. The smoke runs
entirely offline and needs no network grant. Print mode refuses
`--output-format stream-json` without `--verbose` (the binary carries the
message "stream-json requires --verbose"); keep both flags together. The
operator's own user-level hooks fire inside a dispatched session and appear
as `system` lines with `hook_started` and `hook_response` subtypes; the
filter must tolerate them silently.
