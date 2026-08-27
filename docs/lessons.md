# Lessons

This document records the failure patterns that shaped pass 1 of Autometta. It extends the protocol in [dispatch-contract step model](dispatch-contract.md#the-seven-steps) with incident context, failure modes, and mitigations.

## Headless gotcha 14: a zero-byte process log is not zero usage

### One-sentence summary
A live Claude process writes no final log until exit, so log scraping reports a false zero throughout the run even while its harness transcript records usage.

### Incident origin
On 2026-08-23 the repo ticker showed `tokens:0` for a 1,815-second Claude worker whose live transcript totalled 30,074,356 tokens. The run worktree, not the subscribed repo root, keyed the Claude transcript; Codex stored its working directory inside `session_meta` instead.

### Failure mode if ignored
An idle process and a high-spend overnight worker look identical. Parsing the whole transcript on every five-second refresh fixes the number but makes frame cost grow with files that reach tens of megabytes.

### Mitigation
Record `working_dir` in `state/active-agents/<pid>.json`. Resolve Claude by its path slug and start time, and Codex by `session_meta.cwd` and start time. Sum Claude's four usage keys incrementally while persisting a byte offset and total in the active registry; use the latest Codex cumulative `total_token_usage` rather than summing it. Read at most 16 MiB per refresh, retry misses until the transcript appears, and distinguish `waiting` from `unavailable`.

## Headless gotcha 1: stdin hang

### One-sentence summary
A headless worker can block on stdin after parsing prompt arguments, then burn budget without producing output.

### Incident origin
Source project: fractals-from-the-90s, the named inputs identify this as a canonical headless gotcha in real use.

### Failure mode if ignored
The worker appears alive but never progresses, the stage times out, and the orchestrator gets no useful artefact.

### Mitigation
Apply the dispatch safeguards in [Step 3: Worker dispatch and sandbox](dispatch-contract.md#step-3-worker-dispatch-and-sandbox), including stdin redirection from `/dev/null`.

## Headless gotcha 2: card-sync race

### One-sentence summary
Worker and verifier can read different versions of the stage card when writes and reads are not serialised.

### Incident origin
Source project: fractals-from-the-90s, documented in the named inputs as a recurring race across worktrees or write timing.

### Failure mode if ignored
The worker executes one contract while the verifier checks another, which creates false failures or false passes.

### Mitigation
Use the controls in [Step 1: Stage card authoring](dispatch-contract.md#step-1-stage-card-authoring) and [Step 4: Acceptance command](dispatch-contract.md#step-4-acceptance-command), with one stable card snapshot before dispatch.

## Headless gotcha 3: opaque log paths

### One-sentence summary
Unstable harness-generated log paths make post-run diagnosis slow and unreliable.

### Incident origin
Source project: fractals-from-the-90s, identified in the named inputs as a repeated operational issue.

### Failure mode if ignored
Verifier and operator cannot find the right worker output quickly, so acceptance and failure triage stall.

### Mitigation
Follow [Step 2: Worker prompt assembly](dispatch-contract.md#step-2-worker-prompt-assembly) and [Step 3: Worker dispatch and sandbox](dispatch-contract.md#step-3-worker-dispatch-and-sandbox), and pin a predictable path such as `/tmp/codex-<stage-id>.log`.

## Headless gotcha 4: sandbox-as-role-boundary

### One-sentence summary
The worker sandbox is not just safety, it enforces separation between implementer and verifier.

### Incident origin
Source projects: fractals-from-the-90s and agentic-rag-kimble, both inputs frame this as a load-bearing boundary.

### Failure mode if ignored
If a worker can self-verify, it can report green without external evidence, which weakens the gate.

### Mitigation
Keep role separation from [Step 3: Worker dispatch and sandbox](dispatch-contract.md#step-3-worker-dispatch-and-sandbox) and [Step 4: Acceptance command](dispatch-contract.md#step-4-acceptance-command), with verifier checks outside the worker sandbox.

## Headless gotcha 5: prior-gate regressions

### One-sentence summary
A stage can pass local checks but still break a previously passing acceptance gate.

### Incident origin
Source project: fractals-from-the-90s, listed in the named inputs as a known headless regression class.

### Failure mode if ignored
A later stage ships with hidden regressions, then earlier guarantees silently rot.

### Mitigation
Run full-gate checks per [Step 4: Acceptance command](dispatch-contract.md#step-4-acceptance-command) and enforce reconciliation in [Step 6: Orchestrator integration](dispatch-contract.md#step-6-orchestrator-integration).

## Kimble production quirk 1: codex sandbox flag default

### One-sentence summary
Codex sandbox mode selection is a first-order control for what a worker can claim or change.

### Incident origin
Source project: agentic-rag-kimble pass 28-29, detail TBD, reconstruct from source project.

### Failure mode if ignored
A mismatched sandbox setting can block required writes or allow behaviour the stage did not intend.

### Mitigation
Declare and verify sandbox mode during [Step 3: Worker dispatch and sandbox](dispatch-contract.md#step-3-worker-dispatch-and-sandbox), with family-specific notes when needed.

## Kimble production quirk 2: state.yaml as the authority

### One-sentence summary
Loop decisions in pass 2 rely on a single authority file for current state.

### Incident origin
Source project: agentic-rag-kimble pass 28-29, described in named inputs as a core scaffold pattern.

### Failure mode if ignored
Multiple state sources drift, then dispatch decisions and status reporting diverge.

### Mitigation
For pass 1, treat this as outside the one-stage contract and anchor current control flow in [What the contract does not cover](dispatch-contract.md#what-the-contract-does-not-cover) and [Pass-2 layer](dispatch-contract.md#pass-2-layer).

## Kimble production quirk 3: publish-guard exemption for autonomous commits

### One-sentence summary
Autonomous commit flows may require a defined exemption path from standard publish guards.

### Incident origin
Source project: agentic-rag-kimble pass 28-29, detail TBD, reconstruct from source project.

### Failure mode if ignored
Autonomous runs can fail at commit or publish boundaries, or bypass policy without an explicit contract.

### Mitigation
Keep attribution and commit boundary explicit in [Step 7: Commit](dispatch-contract.md#step-7-commit), and document any exemption policy only when pass-2 artefacts are introduced.

## Kimble production quirk 4: result.json rename convention

### One-sentence summary
Verifier handoff naming conventions affect traceability of worker versus verifier outcomes.

### Incident origin
Source project: agentic-rag-kimble pass 28-29, the inputs note the `result.json` to `result.worker.json` rename question.

### Failure mode if ignored
Result files become ambiguous, then the orchestrator cannot tell which artefact reflects worker output and which reflects verifier judgement.

### Mitigation
Keep output ownership explicit through [Step 5: Verifier handoff](dispatch-contract.md#step-5-verifier-handoff) and [Step 6: Orchestrator integration](dispatch-contract.md#step-6-orchestrator-integration), with stable naming agreed in the stage card.

## Headless gotcha 8: codex prefers $CODEX_HOME/auth.json over OPENAI_API_KEY

### One-sentence summary
The Codex CLI uses `$CODEX_HOME/auth.json` (default `~/.codex/auth.json`) ahead of the `OPENAI_API_KEY` env var; if that file is in `auth_mode: "chatgpt"`, an api-mode dispatch silently bills the subscription regardless of the injected key.

### Incident origin
Source project: autometta self-host on 2026-05-27. After card 14 shipped the per-family auth route toggle, `autometta auth check codex` returned PASS with a resolved API key, but the actual `codex exec` dispatch in fract-cl was still billing against the ChatGPT subscription. Root cause: `~/.codex/auth.json` was in `chatgpt` mode from earlier `codex login`. Codex consulted it ahead of the `OPENAI_API_KEY` that op-fetch had injected. The op-fetch + env-var path was a no-op for billing.

### Failure mode if ignored
The operator believes they are spending the OpenAI API budget; in reality they are spending the ChatGPT subscription tokens the toggle was meant to spare. There is no error and no log line because both auth modes succeed at the provider level. The mistake compounds across every dispatched stage.

### Mitigation
Stand up an isolated sibling `CODEX_HOME` whose `auth.json` carries `auth_mode: "apikey"`:

```sh
mkdir -p ~/.codex-api-only && chmod 700 ~/.codex-api-only
op-fetch --print "$OP_REF_OPENAI_API_KEY" | \
  CODEX_HOME=~/.codex-api-only codex login --with-api-key
```

In autometta, `scripts/spawn-worker.sh` and `scripts/spawn-verifier.sh` resolve the sibling via `$AUTOMETTA_CODEX_HOME` (default `~/.codex-api-only`) and pass it through op-fetch with `--pass CODEX_HOME` whenever codex is in api mode. They fail closed if the sibling is missing or its `auth_mode` is not `apikey`. `autometta auth check codex` verifies both the ref resolution and the sibling state — run it before any dispatch.

Claude has no equivalent: `claude -p` honours `ANTHROPIC_API_KEY` directly, so no sibling is needed for `claude` family api mode.

## Headless gotcha 9: claude worker subshell receives SIGHUP when LaunchAgent tick exits

### One-sentence summary
When `phat-controller` tick is driven by a LaunchAgent, bash sends SIGHUP to background subshells (`( ... ) &`) on exit, which silently kills any in-flight claude worker before it finishes.

### Incident origin
Source project: autometta self-host on 2026-05-27. Claude workers dispatched via the autonomous loop exited after ~21s with a 0-byte log. Direct invocation (`op-fetch + claude -p` from an interactive shell) worked correctly. Root cause: `spawn-worker.sh` wrapped the claude dispatch in a bash subshell `( cd "$repo_root" && ... ) &`. When the tick job returned, the LaunchAgent's bash sent SIGHUP to that subshell, which propagated to op-fetch and then to claude.

Codex workers use a direct `&` without a wrapping subshell and manage their own process group, so they are unaffected.

### Failure mode if ignored
Claude workers silently exit with a 0-byte log. The heartbeat suppresses `silent` for the claude family (gotcha 6), so the agent ticker shows no alert. The stage either stalls at `worker_pid` polling or, if the heartbeat grace window expires first, transitions to `stuck`. The operator sees no error and no output.

### Mitigation
Call `disown "$pid"` immediately after capturing `$!` from the background job. This removes the job from bash's job table so it no longer receives SIGHUP when the shell exits:

```sh
( cd "$repo_root" && op-fetch ... -- claude -p ... ) &
pid=$!
disown "$pid" 2>/dev/null || true
```

Applied in `scripts/spawn-worker.sh`, `scripts/spawn-verifier.sh`, and `scripts/spawn-verifier-panel.sh` (commit `237c8a6`).

`disown` addresses shell job-control SIGHUP, but it is not the whole fix. launchd separately reaps the tick's entire process group when the `tick` job exits. The complementary mitigation is `AbandonProcessGroup` in the LaunchAgent plist (`templates/launchagent.plist.tpl`, commit `2cc42c2`), which tells launchd not to send the group that signal. Keep both: `disown` for the shell, `AbandonProcessGroup` for launchd.

### Verified
Confirmed on 2026-05-29 with a real LaunchAgent dispatch (not a manual tick): a claude/Haiku worker spawned by the `RunAtLoad` tick survived the tick process exiting, ran to completion, and wrote its handoff envelope; the log stayed 0 bytes until the single burst at completion (gotcha 6), and a cross-family codex verifier returned PASS. Both fixes hold together; the unattended launchd loop is no longer a known blocker.

## Headless gotcha 10: a tick can destroy the gitignored state.yaml, and the state branch cannot back it up

### One-sentence summary
`state/state.yaml` is gitignored, so `commit_state_branch`'s `git add state/state.yaml` is a silent no-op — the state branch never persists it — and a tick that derives a degenerate document from a transient read error can overwrite the only on-disk copy with an empty `stages: []` skeleton, with no recovery point.

### Incident origin
Source project: autometta self-host on 2026-05-29. A live `launchctl kickstart` tick (fired to verify the LaunchAgent loop) left `state/state.yaml` reduced to a two-line `stages: []` stub; the populated file (`current_stage: 22`, full stage list) was gone. The tick log showed a `json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)` — `state_apply_json` had a tmp file that was empty at validation time — followed by `refusing state branch checkout` because the working tree was dirty (a `models.sh` `644 -> 755` mode flip from re-running `install-homebrew-local.sh`). Recovery was only possible from an APFS Time Machine local snapshot, because `state.yaml` is gitignored and the `phat-controller/state` branch had never actually tracked it.

### Failure mode if ignored
The loop's entire stage-progress record vanishes on a single bad tick. Because the next pending stage is selected as the first `status: pending` entry, a re-init to `stages: []` (or a stale recovery) makes the loop either go idle or re-run already-committed stages. There is no remote copy: the gitignored file lives only on the operator's disk.

### Mitigation
Three layers, all in `scripts/tick.sh`:
1. `state_apply_json` reads the current state with a guard (refuse to derive from an unreadable/empty document), validates the *result* is a non-empty JSON object still carrying a `.stages` array before writing, and never `mv`s a degenerate document over good state.
2. `state_apply_json` writes a rolling `state/state.yaml.bak` before every replacement — the only recovery point for a gitignored file.
3. A top-of-tick integrity guard (`_process_repo_locked`) refuses to dispatch against a corrupt/empty `state.yaml`: it auto-restores from `state.yaml.bak` when that is valid, otherwise halts with reason `state-corrupt` rather than proceeding or silently re-initialising.

Open follow-up: `commit_state_branch` still cannot persist `state.yaml` while `state/` is gitignored; the durable backup is the local `.bak`. A real off-disk copy would need either a force-added state file on the state branch or an explicit export step.

## Headless gotcha 11: `op read` blocks forever on a TCC prompt no one can approve

### One-sentence summary
On macOS Sequoia, `op` can trip the "access data from other apps" TCC prompt even in service-account mode, and from a launchd/cron context on a locked machine that prompt is unanswerable — `op read` blocks indefinitely and the dispatched worker hangs with an empty log.

### Incident origin
2026-07-24, emergence-viewer-deep-zoom stage 30: the loop's claude worker sat 9 hours at `op-fetch → op read` with the lid shut; the tick only caught it via the wall-clock stall detector (8114 s). The pending TCC dialog surfaced at next login.

### Failure mode if ignored
Every overnight claude-family dispatch gambles on 1Password's TCC state; a single pending prompt silently converts a 90-minute stage into a stalled run and burns the tick budget.

### Mitigation
`op-fetch` now wraps every `op read` in a watchdog (`OP_FETCH_TIMEOUT`, default 60 s) and exits 124 with a "TCC prompt or locked 1Password?" diagnostic, so the spawn chain fails in seconds and the tick reaps a dead worker instead of a zombie. Approve the TCC prompt once per context at the machine (or grant `op` Full Disk Access) to prevent the prompt recurring; the service-account token in `~/.config/op/service-account.env` already avoids desktop-app unlock dependencies. Verified end-to-end from launchd: `op-fetch → claude -p` round-trip in 10 s.

**The approval does not survive a cask upgrade.** TCC keys the grant to the binary's full path, and `brew upgrade 1password-cli` installs into a new versioned Caskroom path (`.../1password-cli/<version>/op`) — macOS treats it as a brand-new app and re-prompts. Worse, the prompt's default-highlighted button is **Don't Allow**, so a reflexive click records a denial (observed 2026-07-24: the 2.34.0→2.35.0 upgrade re-prompted, the deny landed at 06:12, and the next launchd dispatch failed at the watchdog). After any 1password-cli upgrade, trigger one headless `op-fetch --print` from a launchd context and click **Allow** on the resulting prompt; confirm with `sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db "SELECT client, auth_value FROM access WHERE service='kTCCServiceSystemPolicyAppData' AND client LIKE '%1password%'"` — the current version's row must not be 0.

## Headless gotcha 12: `IFS` without a space turns an intended word split into a silent no-op

### One-sentence summary
Every spawn script sets `IFS=$'\n\t'`, so an unquoted expansion of a space-joined flag string never splits: `--effort high` reaches the CLI as one argument whose option name contains a space, and the `# shellcheck disable=SC2086` above it documents the intent while hiding the failure.

### Incident origin
2026-08-14, `emergence-lab` stage 34: a Claude verifier declared `Verifier effort: high` on its card and its entire log was one line, `error: unknown option '--effort high'`. Note the quoting in that message — the CLI is reporting a single unknown option, not an unknown `--effort`. The flag is supported and correctly spelled on claude 2.1.232; only its delivery was wrong. `models.sh` emitted `--effort high` as one string and both spawn scripts expanded it unquoted, trusting a word split that `IFS` had already ruled out.

### Failure mode if ignored
The dispatch dies in well under a second with a 38-byte log, and each attempt still burns one of the three `verifier_attempt_cap` retries. A stage with a Claude verifier and any effort declared exhausts its attempts and is marked `stalled` without a verifier ever running.

The codex side of the same defect was silent, and worth recording because the obvious conclusion is wrong. `-c model_reasoning_effort=high` also arrived as one argument, but clap accepts an attached value on a short option, so codex saw `-c` with the value `" model_reasoning_effort=high"`, and its override parser tolerates the leading space. Confirmed on codex-cli 0.147.0: `codex debug -c " model_provider=doesnotexist" prompt-input` fails with `Model provider 'doesnotexist' not found`, exactly as the two-argument form does. Codex has been honouring the declared effort throughout. A long option has no such forgiveness, which is why only the claude family crashed.

### Mitigation
`effort_flags_for_family` in `scripts/models.sh` now prints one argv element per line, and `effort_argv_for_family` reads those into the global array `AUTOMETTA_EFFORT_ARGV`. Both spawn scripts expand it as `${AUTOMETTA_EFFORT_ARGV[@]+"${AUTOMETTA_EFFORT_ARGV[@]}"}` — quoted, so it survives any `IFS`, with the `+alternate` guard because bash 3.2 (the system bash on macOS) treats `"${arr[@]}"` on an empty array as unbound under `set -u`. `IFS=$'\n\t'` stays; it is there deliberately.

The general rule: an array is the only safe way to carry a multi-token argument list through a shell. Reaching for word splitting means depending on a variable set 180 lines away in another file, and `shellcheck disable=SC2086` silences the one tool that would have asked about it. `scripts/effort-flags-smoke.sh` asserts on the constructed argv, captured from a stub `op-fetch` on `PATH`, so the regression is caught with no auth, no network and no spend.

## Headless gotcha 13: the only safety failed silently while the run looked like a success

### One-sentence summary
`budget_check_caps` was consulted once per tick and never at the point of spend, so a loop that had already blown its token cap kept dispatching, and the daily window reset then zeroed the counters that proved it, leaving a 149x overrun that produced good work, a clean-looking state file, and no alarm at any point.

### Incident origin
2026-08-15, `emergence-lab-gpu`: 149,752,682 tokens against a `token_cap_total` of 1,000,000, and 470 ticks against a `clock_tick_cap` of 400, over an estimated 1,175.99 USD in one day. The queue drained, stages 34 to 39c all completed and the work was good. Nothing surfaced any of it; the overrun was found the next morning by reading `state/budget.json` for an unrelated reason.

The arithmetic was never wrong. `tokens_spent` matched the day's `cost-log.jsonl` total to the token, and the cap did fire correctly the first time: cumulative spend crossed 1,000,000 during the stage-35 verifier at 07:42:03Z and the tick log records `halted ... due to token-cap` at 07:47:04Z, the very next tick. The check was in the wrong place, and what it produced was a latch that several things could quietly unlatch.

Three defects compounded, and only the first is about the comparison:

1. **The cap gated the tick, not the dispatch.** `budget_check_caps` had exactly one call site, at the top of `_process_repo_locked`, before the reap. One tick then reaps a finished agent, charging its tokens through `budget_account_tokens_from_log`, and goes on to spawn the next role against a budget read taken before that charge. The mean dispatch on this repo cost 4,830,731 tokens and 18 of the 31 dispatches individually exceeded the entire cap, so a budget consulted only between ticks could not bind however correct its arithmetic.
2. **The window reset erased the evidence.** `budget_ensure_window` zeroes `tokens_spent`, `clock_ticks_used` and `consecutive_failures` and clears `halted` when a UTC day boundary is crossed into a halted-or-at-cap budget. Run against the incident file it turns 149,752,682-spent-and-halted into `tokens_spent: 0, halted: false` with the caps untouched. So `token_cap_total` was never a total; it was a per-day allowance that renewed itself silently, and by the following morning the file read like a healthy repo.
3. **The first cap hit was the only one recorded.** The four caps are tested in a fixed order and the function returned on the first match, so a budget over both wrote `halt_reason: "token-cap"` and nothing else. The 470-against-400 tick breach, the simpler failure of the two and one needing no token parsing to evaluate, was never named anywhere.

`requeue-stage.sh` also cleared `.halted` unconditionally, on the reasoning that the tick re-halts if a condition genuinely persists. That is true of the tick check and it makes a routine hand re-queue an unlatch of the only safety in the design.

### Failure mode if ignored
The dangerous shape is not the money, it is that **every visible signal says success**. Stages complete, commits land, the verifier passes, the dashboard is green. The one artefact that disagrees is a gitignored JSON file nobody reads while things are working, and the daily reset means that by the next morning it agrees too. "Budget file, not retries" is load-bearing precisely because there is nothing behind it: no circuit breaker, no backoff, no second line. A budget file that does not stop dispatch is not a weak safety, it is the absence of one, presented as its presence.

### Mitigation
`budget_gate_dispatch` in `scripts/budget.sh` is the cap check that guards a *spawn* rather than a tick, and `tick.sh` calls it immediately before both the worker and the verifier dispatch, after any reap in that tick has been charged. It halts the repo before refusing and fails closed on any unexpected return code. Replaying the real 2026-08-15 sequence through it halts after 2 of 31 dispatches at 5,676,364 tokens rather than 149,752,682.

That number is the honest bound and worth stating plainly: 5,676,364 is still 5.7x the cap, because the dispatch that crossed it was a 5,599,240-token verifier and the cap is enforced after the fact, per dispatched process. One dispatch of overshoot is the floor for an after-the-fact cap. Pre-dispatch estimation remains future scope (`docs/phat-controller.md`, "Deferred"); until it exists, a cap smaller than a typical dispatch is decorative, and the number to set is one an overshoot of a single worker or verifier can still be afforded.

For the evidence: `lifetime_tokens_spent` is monotonic and nothing resets it, and `budget_record_breach` writes an append-only `breaches[]` entry, holding counters, caps and reasons as they stood, both when a cap halts the loop and immediately before `budget_ensure_window` zeroes anything. The reset keeps its legitimate purpose, so a new day still resumes a repo that halted for a real reason; it simply no longer destroys the record on its way through. `halt_reasons` carries every cap that was over, so a tick breach is never masked by a token breach again. `requeue-stage.sh` now clears a failure-cap halt (that is what re-queueing means) and refuses, non-zero and loudly, to clear one whose spend cap is still blown.

`scripts/budget-cap-smoke.sh` asserts all of it against temporary budget files with no auth, network or spend, and carries the 31 real dispatch sizes as its replay fixture. Run against the pre-fix commit it reports `halted after 31 of 31 dispatches at 149752682 tokens`, the incident's own figure.

The general rule: a safety check belongs at the point of the action it guards, not at the top of the loop that eventually performs it. And any mechanism that resets a safety counter must first write down what it is resetting, or the failure it is hiding is the one nobody will ever be shown.

## Headless gotcha 14: the sandbox refused the one write the loop was waiting for

### One-sentence summary
A run worktree's `state/` is a symlink out of the tree, codex's `workspace-write` sandbox makes only the `-C` root writable, so a sandboxed role did its work, passed, and was recorded as a failure because the single artefact proving it had passed was the one write the sandbox refused.

### Incident origin
2026-08-16, stage `31-budget-cap-did-not-stop-dispatch`. The verifier ran three times, reached `"overall": "PASS"` all three times, and said so in its own log:

> Operational blocker: state is a symlink to `../autometta/state` outside the permitted writable root, so the sandbox refused creation of `state/verifiers/31-budget-cap-did-not-stop-dispatch.json`. This JSON is therefore returned here but was not written to disk.

`ensure_run_worktree` points `state/` at the subscriber's real state dir so every role shares one set of envelopes, logs and budget rather than a per-worktree copy, which is correct and worth keeping. But codex is invoked with `-C "$work_dir" --sandbox workspace-write`, and the symlink target sits outside `$work_dir`. codex resolves the link when it checks a write, so the refusal is on the physical path and no amount of worktree-relative addressing avoids it.

`tick.sh` uses the envelope as its *sole* completion signal. No artefact is read as a failed attempt. Three of those tripped `consecutive_failure_cap`, the stage was marked `stalled`, and 8.8M tokens of verified, correct work sat in a worktree that nothing was going to merge. The stage that was lost this way was, with some irony, the fix for the budget cap.

Two things made it expensive rather than merely annoying. The verifier's own prose *named the cause exactly*, in a log nobody reads while a stage looks like it is simply failing. And the retry was the worst possible response: the refusal is deterministic, so every retry re-ran a full verifier dispatch, paid for it, and failed identically.

### Failure mode if ignored
This is the inverse of gotcha 13 and the more insidious of the two. There the visible signals said success and the hidden file said failure; here the visible signal says failure and the work is fine. An operator reading `stalled` and `consecutive_failures: 3` concludes the model could not do the task, re-briefs the card, and pays again for work that was already correct — while the actual defect is one flag in the dispatch line. Any completion signal carried by a *side effect* rather than a return value inherits the permissions of the thing producing it, and a permission failure is then indistinguishable from a work failure.

### Mitigation
`codex_state_argv_for_repo` in `scripts/models.sh` emits `--add-dir <resolved state dir>`, and both spawn scripts pass it on every codex dispatch. It widens the sandbox to the symlink's target and nothing else. The path is deliberately the resolved physical one (`pwd -P`), since that is what codex checks against. A repo with no `state/` yields an empty argv rather than failing, so a caller that has not adopted worktree-per-run dispatch is unaffected. Claude roles are unsandboxed and need nothing.

Verified A/B against the real CLI with the same prompt and sandbox, the flag the only difference: without it, `Write failed: unable to create state/.probe`; with it, the write lands in the shared dir. `scripts/state-writable-smoke.sh` asserts the argv construction, the symlink resolution that is the whole point, and the graceful degradation when `state/` is absent, against a stub `op-fetch` so it needs no auth, network or spend. It fails closed on a pre-fix tree.

The general rule: when a loop treats "artefact absent" as "agent failed", make sure the agent could physically have written it. A sandbox boundary that cuts through a completion signal converts every permission error into a false verdict about the work — and the retry that follows is guaranteed to cost the same and fail the same way.

## Headless gotcha 15: the tick counter measured the clock, and the dashboard measured the wrong file

### One-sentence summary
`clock_tick_cap` was documented as bounding work and implemented as bounding elapsed polling, so every repo with an empty queue reached its cap on a fixed schedule and was halted before the window it was meant to work in opened, while the panel the operator was watching read a queue the controller does not dispatch from, so it showed the empty queue as full.

### Incident origin
2026-08-23. Every enabled subscriber, read at 10:50Z:

| Repo | `clock_ticks_used` / cap | `tokens_spent` | `wall_clock_elapsed_seconds` | halted at |
|---|---|---|---|---|
| aegis-guardrails | 400/400 | 0 | 0 | 04:13:32Z |
| agentic-rag-kimble | 400/400 | 0 | 0 | 04:13:32Z |
| autometta | 400/400 | 0 | 0 | 04:13:32Z |
| fractals-from-the-90s | 400/400 | 0 | 0 | 04:13:33Z |
| emergence-lab-surface | 180/180 | 0 | 0 | 07:32:47Z |
| emergence-lab | 400/400 | 5,921,327 | 0 | 03:28:18Z |

Five of the six consumed an entire day's tick allowance and spent zero tokens and zero wall-clock seconds doing it. `aegis-guardrails` holds exactly one stage, that stage is `completed`, and it burned 400 ticks establishing there was nothing to dispatch.

`budget_increment_tick` was called on the unconditional fall-through at the end of the per-repo tick as well as on the early-return paths above it, so the counter advanced whether or not an agent was dispatched. `schemas/budget.json` had described the field as "ticks that have done work on this repo" since it was written; nothing in the code made that true. The window reset at midnight, the fleet spent the allowance through the small hours, and every subscriber was halted well before the 22:00 evening window opened. The overnight window had nothing to do with whether the overnight window opened.

Three things compounded it.

**A second fleet-wide tick job halved the time to cap.** `com.autometta.tick.fleet.plist` carries the comment "Do not add a second tick job per repo", written after three per-repo jobs tripled the rate and left the fleet halted through the 2026-08-15 window. `com.autometta.tick.emergence-lab-surface-v2.plist`, added 2026-08-19, is named for one repo but its `ProgramArguments` are `autometta tick` with no repo argument, so it iterated the whole fleet too. Both were loaded at `StartInterval` 300, and the controller log showed 24 ticks an hour per repo, one every 150 seconds, against an intended 12.

**`--reset-halt` could not recover any of it.** It wrote `.halted = false | .halt_reason = null | .halted_at = null` and never touched `clock_ticks_used`, which is the counter that caused the halt. A run against all seven subscribers reported "reset halt state" seven times and all seven were back to `halted: true, halt_reason: tick-cap` inside one tick interval, still reading 400/400. The fleet was unstuck by hand, zeroing the counters directly in each `budget.json`.

**The panel said the queue was full.** `agent-ticker.sh` renders SCHEDULED from `list-cards.sh`, which classified a card as done only if it appeared as a done row in `examples/self-host/PLAN.md` (now `stage-cards/PLAN.md`) or in `state/recent-agents/` with `outcome=completed`. It never read `state/state.yaml`, the file the controller dispatches from. `PLAN.md` is autometta's own file and exists in no other subscriber, so every card in a subscriber's `docs/stages/` was reported `pending` forever. The ticker showed `emergence-lab` with sixteen pending stages while `state.yaml` recorded 31 `completed`, 3 `verifier_failed`, 2 `stalled` and not one `pending`.

### Failure mode if ignored
This is the same class of miss as the 2026-08-13 weekend, where ~9.4M tokens went on ticking against an empty queue, except here the operator had a display that actively said the queue was full. Two numbers named for one thing and measuring another: a cap called a work budget that measured elapsed time, and a panel called SCHEDULED that measured a file the scheduler does not read. Each on its own is survivable. Together the fleet spent its whole allowance doing nothing, halted itself out of the window where there was something to do, and reported a healthy backlog throughout.

The reset command made it self-sustaining. A recovery path that reports success and changes nothing is worse than no recovery path, because the operator stops looking.

### Mitigation
`budget_increment_tick` takes a kind. `clock_ticks_used` counts work ticks only (supervised a stage in flight, reaped or killed an agent, transitioned a stage, dispatched a queued one) and is the counter `clock_tick_cap` still halts on, so the cap binds exactly where it was always documented to. Idle polling is counted in `idle_ticks_used`, which halts nothing unless an operator sets the optional `idle_tick_cap`. Unknown kinds charge as work, so a dispatch path added later that forgets to classify itself is bounded rather than unbounded.

`budget_reset_halt` clears `clock_ticks_used`, `idle_ticks_used` and `consecutive_failures` with the flag, writes a `breaches[]` record first, and reports any spend cap still over. `tokens_spent` moves only under `--reset-tokens`: a polling artefact can be zeroed freely, real spend cannot.

`scripts/health-check.sh` counts loaded launchd jobs that run the fleet tick and fails when there is more than one. It matches on what a job runs rather than what it is called, because the duplicate was named for a repo, and a label-pattern check would have missed it. The comment in the plist is now enforced rather than merely written down.

`list-cards.sh` treats `state.yaml` as authoritative for every card it records and falls back to `PLAN.md` / `recent-agents` only for cards it has never seen. A card on disk the controller has never been given is a real category and gets its own label, `unqueued`, so an empty queue is visible as an empty queue. The ticker prints queue depth as a number whether or not it is zero, and the ALERTS panel raises an empty queue on an enabled subscriber.

`scripts/idle-tick-smoke.sh` asserts both directions against temporary budget files with no auth, network or spend: a simulated full day of idle polling does not halt, work ticks still halt at the cap, `--reset-halt` leaves a capped repo able to tick again, and a second loaded tick job fails the health check.

The general rule: when a counter's name and its increment site disagree, the name is what everyone reasons about and the increment site is what happens. And a status panel must read the file the thing it reports on actually reads, or it is a second, independently-wrong source of truth that is at its most confident when it is at its most wrong.

## Headless gotcha 16: a criterion the verifier's seat cannot satisfy fails exactly like broken code

### One-sentence summary
An acceptance criterion that asks for evidence the verifying seat has no way to produce returns `FAIL` in the same field, with the same weight, as a criterion the code genuinely misses, so the loop spends its whole retry cap proving the same thing over and over and parks working code in a terminal state.

### Incident origin
2026-05-27, `emergence-lab` stages 13 to 16. Each carried one browser-smoke criterion among seven or eight, each landed its implementation on `dev` (`a0ba582`, `6af7104`, `38b5e6d`, `8099310`), and each failed on the browser criterion alone. The verifier artefacts say so plainly: "Overall is FAIL only because the required browser smoke test could not be executed to completion in this sandbox", and, from stage 13, a list of four different ways it had tried to get a browser and failed. Stage 15's worker had flagged it in advance: "I could not perform the browser smoke test (acceptance criterion 4) from this environment."

Nothing in the loop distinguished that from a worker that got the code wrong. All four sat terminal for three months. Stage 16 spent its entire attempt cap without any role ever forming an opinion about the code, and a requeue on 2026-08-16 reproduced the position rather than changing it, because the criterion, not the code, was what had to change.

The part worth sitting with: `e2e/smoke.spec.ts` had been in that repo the whole time. Playwright, `headless: true`, its own Vite `webServer`, canvas screenshots per simulation route. It is exactly the evidence the four criteria wanted. No card mentioned it, so three verifiers went looking for a browser on their own, each found a different way not to have one, and each wrote FAIL.

### Failure mode if ignored
The terminal state is quiet and it reads as a code problem. An operator scanning `state.yaml` sees `verifier_failed` and reasonably concludes the worker got it wrong; the artefact that says otherwise is one field deep in a JSON file. The retry cap makes it worse rather than better, because every retry is deterministic: the seat that could not look still cannot look. Three attempts buy three copies of the same verdict.

This is the mirror of gotcha 4. There the sandbox boundary is exploited deliberately, because a worker that cannot verify itself is the point. Here the same boundary silently decides an acceptance criterion, and nothing declares that it has.

### Mitigation
Step 5 of `templates/verifier-prompt.md` (`7c7f22b`, 2026-08-22) makes the method explicit for every verifier in the fleet: any browser check runs fully headless, launching the verifier's own headless Chromium against a dev server it starts itself, never attaching to the operator's Chrome. That closes the "I could not obtain a browser" case for an unsandboxed seat. `Requires GUI` in `templates/stage-card.md` closes the sandboxed-codex case, and closes only that one: it widens the codex sandbox and nothing else, so declaring it for a Claude role grants that role nothing while reading as though it does.

The authoring rule those two support: **before writing a criterion, name the seat that will judge it and the command that produces its evidence.** A criterion whose evidence has no command behind it is a manual gate wearing an acceptance criterion, and a manual gate belongs to the operator, not to the retry cap. Where the repo already has a harness, the card points at it by path, because a verifier that has to invent the method will sometimes invent one that does not work in its seat.

Where a criterion has already failed this way, the fix is a re-brief that names the method and leaves the claim alone, not a requeue and not a softened criterion. The worked example is `docs/incidents/2026-08-16-emergence-lab-five-broken-stages.md`, which carries the four verdicts and the re-brief that followed them.

## Headless gotcha 17: a reset time just past is not tomorrow

### One-sentence summary
A provider banner gives a reset clock but no date, so resolving every clock that is earlier than `now` as tomorrow can turn a reset that happened seconds ago into a 24-hour pause.

### Incident origin
On 2026-08-24 a Claude worker for stage 46 was refused at 12:06 local with `You've hit your session limit · resets 12:10pm (Europe/London)`. The tick reaped the process seconds after that clock and recorded:

```text
2026-08-24T11:10:02Z stage 46-verifier-bake-off-local-against-cloud-free worker was refused by the provider, not failed: You've hit your session limit · resets 12:10pm (Europe/London)
2026-08-24T11:10:02Z   stage left untouched; dispatch paused until 2026-08-25 12:10 BST
```

The refusal handling was correct: it burned no attempt and left the worktree standing. The date inference was not. At 12:10:02 BST, the parser constructed today's 12:10, found it two seconds earlier than `now`, added one day, and parked an unattended repo for roughly 25 hours after the refusal.

### Failure mode if ignored
A healthy self-resuming pause can sleep through the next working window. The stage remains pending and looks safely preserved, but no tick dispatches it until the incorrectly inferred date. A malformed provider clock has the same shape and can impose a day-long pause even though the real session window is five hours.

### Mitigation
`usage_limit_reset_epoch` treats a reset in the previous 15 minutes as already elapsed, including when the clock crossed midnight. It returns the current epoch, so `budget_pause_active` clears the elapsed pause on the next tick and redispatches the untouched stage. A reset still ahead keeps today's date. Older clocks retain the previous next-day interpretation, but the resulting target is capped at six hours from `now`, above the five-hour provider window. An unparseable clock keeps the existing one-hour fallback, also below the cap.

`scripts/usage-error-smoke.sh` fixes the clock offline and covers two minutes past, two minutes ahead, midnight crossing, the exact incident timestamp, and a nonsense clock. The general rule: when a provider supplies a wall-clock time without a date, near-boundary arithmetic must distinguish "just elapsed" from "next occurrence", and every inferred wait needs a bound tied to the real window it represents.

## Headless gotcha 18: the agent wrote the file, but the tick looked through a different state path

### One-sentence summary
An agent's log says it wrote its handoff envelope or verifier artefact, but the tick cannot find it: inspect the run worktree's `state` symlink before blaming the agent or spending a retry.

### Incident origin
On 2026-08-25 the verifier for stage 51 returned a genuine PASS on all six criteria and wrote a valid artefact under its working directory. The tick read the matching path under the subscriber root, found nothing, recorded the verifier as aborted, and dispatched it again. Two of the three verifier attempts were spent on a verdict that already existed.

The apparent contradiction came from two views of one tree. Prompts give agents relative paths such as `state/handoffs/<stage-id>.json` and `state/verifiers/<stage-id>.json`, resolved from the run worktree. Readers anchor the same paths to the subscriber root. `ensure_run_worktree` normally replaces the worktree's tracked `state/` directory with a symlink to the subscriber's shared state, making both views agree. An operator script had replaced that symlink with a real directory, so the verifier's successful write landed in private worktree state while the tick kept reading shared state.

This is the completion-path version of the card-sync race in gotcha 2. The writer and reader both behaved correctly against different physical files, and the missing-file branch erased that distinction by reporting an agent failure.

### Failure mode if ignored
A missing symlink looks exactly like `worker_envelope_missing_after_exit` or an aborted verifier. The work may be complete, the agent may explicitly say where it wrote the completion file, and every retry will still write into the same wrong directory. The operator is sent towards the model, prompt, or auth route while the fault is in the dispatch boundary.

### Mitigation
Relative completion paths remain the contract because they are clone-safe and already shared by both agent families. The symlink that gives those paths their meaning is now asserted after a fresh worktree is cut, immediately before verifier spawn, and before either missing-envelope or missing-artefact diagnosis. The assertion requires `state` to be a symlink and compares its resolved directory with the subscriber's resolved `state/`, so a real directory, broken link, or wrong target all fail closed.

A pre-spawn failure is recorded as `dispatch_configuration_fault` before an agent starts. A read-time failure gets the same diagnosis instead of `worker_envelope_missing_after_exit` or `aborted`; a verifier's reserved attempt is returned, so the counter is unchanged across the faulty dispatch. `scripts/run-worktree-state-symlink-smoke.sh` cuts a real temporary worktree, replaces the link with a directory, writes a valid verifier artefact into the misdirected path, and exercises both completion-file fault paths without auth, network, or token spend.

The general rule: when one side writes a relative path and the other reads an anchored path, the filesystem link that makes them equivalent is part of the protocol. Assert it where the path is created, where the next role is dispatched, and before absence is interpreted as agent behaviour.

## Headless gotcha 13: `codex exec --oss` refuses any local model without thinking support

The free tier is codex-family only: `auth.codex.mode: local` dispatches through
`codex exec --oss --local-provider=ollama -m <model>` against Ollama weights.
On 2026-08-27, with `codex-cli 0.149.1`, every local model that is not from the
gpt-oss family died mid-run with:

```
ERROR: stream disconnected before completion: "llama3.3:70b" does not support thinking
```

Measured across the pulled set that day:

| Model | Result |
|---|---|
| `gpt-oss:120b` | runs |
| `gpt-oss:20b` | runs |
| `llama3.3:70b` | refused, no thinking |
| `llama4:scout` | refused, no thinking |
| `qwen3-coder:30b` | refused, no thinking |
| `devstral:latest` | refused, no thinking |

Four of those refusals are a regression, not a standing limitation. The
verifier bake-off ran `qwen3-coder:30b`, `qwen3:32b`, `devstral` and
`llama4:scout` to completion on 2026-08-24, three days earlier, on the same
machine and the same weights. The Codex CLI changed underneath a documented
result, which is the general shape worth remembering: a measured table about a
third-party CLI has a shelf life, and nothing in the repo was watching for it
to expire.

The damage was not the refusal itself but where it landed. `codex_local_preflight`
checked that ollama was serving and that the model was **pulled**, then let the
dispatch go. Pulled is not usable: the stage was already marked `in_progress`
with a registered pid before anything discovered the model could not run at
all, so an infrastructure fact knowable in advance was paid for with a worker
attempt, the same failure mode the sibling-`CODEX_HOME` gate exists to prevent
for api mode.

The capability is readable locally and for free. `ollama show <model>` prints a
`Capabilities` block, and a usable model lists `thinking` in it:

```
$ ollama show gpt-oss:20b        $ ollama show llama3.3:70b
  Capabilities                     Capabilities
    completion                       completion
    tools                            tools
    thinking
```

`codex_local_preflight` now reads that block and refuses before the spawn. It
fails **open** when the block cannot be read at all: a future ollama that
renames or drops the section must not ground every local dispatch. The cost of
a wrong guess in that direction is one failed attempt, exactly what happened
before the check existed; the cost of a false negative is a route that cannot
run at all.

Two smaller things found alongside it. A noisy `failed to refresh available
models: missing field 'models'` ERROR from `codex_models_manager` appears on
every `--oss` run: codex expects `{"models": […]}` where ollama returns
`{"object":"list","data":[…]}`. It is not fatal, runs complete through it, and
it is easy to mistake for the real failure when reading a log. And the local
route being codex-family only means the whole zero-cost tier now rests on one
model family; there is no second local family to fall back to.

The general rule: a preflight must check the property the dispatch actually
depends on, not the nearest cheap proxy for it. "Is it downloaded" is a proxy
for "can it run", and the gap between them is exactly where a wasted attempt
lives.
