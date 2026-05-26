# Stage card 10-token-usage-tracking: Parse and accumulate worker/verifier token usage into budget.json

## Metadata

- **Authored:** 2026-05-26
- **Orchestrator:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Worker:** Codex GPT-5.3 <codex-gpt-5-3@local>
- **Verifier:** Claude Sonnet 4.6 <claude-sonnet-4-6@local>
- **Pairing rationale:** Cross-family. Touches both spawn-worker.sh and spawn-verifier.sh plus budget.sh; Claude verifier confirms the parser handles both Codex (`tokens used\nN`) and Claude (`Total tokens: N`) output formats and that the side-channel handoff to budget.json is correct.

## Objective

`state/budget.json` carries a `token_cap_total` (default 1,000,000) and a `tokens_spent` field that is currently **never incremented**. Workers and verifiers do produce token-usage information in their stdout — visible in adopter worker logs as `tokens used\n117,339` (Codex format) or `Total tokens: N` (Claude format) — but the autometta loop discards it.

Adopters running the loop unattended cannot tell how much budget they have actually spent and the token cap is decorative. Make it real:

1. Parse the token count from the worker / verifier process's stdout when the process exits.
2. Increment `tokens_spent` in `budget.json` atomically.
3. The existing `budget_check_caps` already compares `tokens_spent >= token_cap_total`, so once the field is fed, the cap becomes enforceable (and once stage 09 lands, the halt will correctly report `token-cap`).

## Inputs (read these in your own context)

- `scripts/spawn-worker.sh`
- `scripts/spawn-verifier.sh`
- `scripts/budget.sh`
- `scripts/tick.sh` (read-only — to confirm where worker/verifier exit is detected)
- A real adopter worker log to confirm output format, e.g. `/Users/AnthonyWest/repos/emergence-lab/state/logs/02-fractal-defaults-and-cycling-worker.log` (read-only)

Do not read anything else.

## Deliverables

All files listed here must be created or modified. Paths are relative to repo root.

1. `scripts/budget.sh` — add `budget_add_tokens` helper:
   ```bash
   budget_add_tokens() {
     local repo_root="$1"
     local tokens="$2"
     [[ "$tokens" =~ ^[0-9]+$ ]] || return 0
     budget_write_atomic "$repo_root" ".tokens_spent += ${tokens}"
   }
   ```
2. `scripts/spawn-worker.sh` — wrap the worker dispatch so that on process exit, the script greps the captured worker log for a token count and calls `budget_add_tokens`. Support both formats:
   - Codex: line `tokens used` followed by a line containing a comma-formatted number (strip commas before parsing).
   - Claude: line containing `Total tokens:` followed by a digit run.
   - If neither pattern matches: log a warning and proceed; the worker still ran successfully.
3. `scripts/spawn-verifier.sh` — same parsing logic applied to the verifier log. (Verifiers also burn tokens; both should count.)
4. `scripts/tick.sh` — when reaping a finished worker/verifier (the path where it was running last tick but `kill -0` now fails), call the new parser AFTER the artefact-found check so token-accounting runs once per phase.
5. `docs/dispatch-contract.md` — document the token tracking model: who increments, when, and from what.

## Constraints

- Bash 3.2 compatible.
- The parser must be tolerant of comma-formatted, whitespace, and trailing-text variants. Examples it must handle:
  - `tokens used\n117,339\n` (Codex)
  - `tokens used\n  142672\n` (no commas)
  - `Total tokens: 23,450` (Claude inline)
  - `Total tokens: 4 567` (with space, unlikely but defensive)
- If multiple token counts appear in a single log (e.g. a worker that retried), the last match wins.
- Parser must not block the loop. Failure to parse is non-fatal: log + continue.
- Token cap enforcement is automatic via existing `budget_check_caps` — no new gate is added.
- Worker / verifier code paths are unchanged in their dispatch semantics; only the post-exit accounting changes.
- Worker does NOT self-commit. Orchestrator commits per the new model. Subject prefixed `10-token-usage-tracking: ...`.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. `bash -n` is green on all three scripts.
2. `budget_add_tokens` exists in `budget.sh` and rejects non-numeric input.
3. `spawn-worker.sh` contains a regex or grep-driven parser for both `tokens used` and `Total tokens:` patterns. Greppable.
4. `spawn-verifier.sh` contains the same parser (or sources a shared helper).
5. Scenario test: feed a fake worker log containing `tokens used\n117,339\n` to the parser; confirm `tokens_spent` increments by 117339 (not 117 or 117,339 as a string).
6. Scenario test: feed a fake worker log with no token line; confirm parser warns and returns without mutating `tokens_spent`.
7. Scenario test: feed a log with both Codex and Claude format token lines; confirm exactly one token count is recorded (last-match-wins or first-match-wins — worker's choice, but documented).
8. `docs/dispatch-contract.md` describes the token-accounting flow.
9. No files outside the deliverables set are modified — except this stage card itself.
10. Publish-guard pre-push hook passes.

## Out of scope

- Per-model cost weighting (Opus vs Sonnet vs Haiku vs GPT-5.x). Token total only.
- Streaming token accounting during a long run. Post-exit only.
- Surfacing tokens_spent in `autometta status` more prominently (small follow-up).
- Token cap auto-doubling, rollover, or reset on a schedule.

## Budget

- **Worker wall-clock:** 35 minutes
- **Verifier wall-clock:** 15 minutes

## Verifier handoff

Worker returns:

- Commit SHA(s).
- Sample of a real adopter worker log line that the parser successfully matched.
- The three scenario test results.
- Confirmation that no `git commit` was invoked from the worker phase.

## Family-specific notes

- Codex worker: `</dev/null` stdin redirect; **do not run `git commit`**.
- Claude verifier: cross-family. Verify the parser handles both Codex and Claude token-line formats; spot-check at least one real adopter worker log to confirm the match.
