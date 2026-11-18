# Stage card 177: Verify the named oracle from the subscriber worktree

## Metadata

- **Authored:** 2026-11-18
- **Orchestrator:** GPT-6.1 Sol <gpt-6-1-sol@local>
- **Worker:** GPT-6.1 Sol <gpt-6-1-sol@local>
- **Verifier:** Claude Sonnet 5.5 <claude-sonnet-5-5@local>
- **Base branch:** dev
- **Run branch:** autometta/177-named-verifier-contract
- **Proposal:** P-20261111-96f9
- **Worker effort:** medium
- **Verifier effort:** medium
- **Verifier panel:** false
- **Recovery attempts:** 3
- **Recovery attempt:** 2
- **Dispatch:** serial
- **Path claims:** scripts/check-contract-test-gate.sh, templates/verifier-prompt.md, scripts/spawn-verifier.sh, scripts/spawn-verifier-panel.sh, scripts/verify-sdk.py, docs/dispatch-contract.md
- **Pairing rationale:** Narrow compatibility repair on six independently verified deliverables. Codex and Claude remain separate seats at medium effort. The original criteria and frozen oracle govern acceptance.
- **Open decisions:** none
- **Cold read:** Claude Sonnet, pooled read-only review on 2026-11-18. Findings and resolutions below.
- **Related proposal:** P-20261118-499d

## Surfacing concern

Ten subscriber reports encountered a missing local checker. Two independently found that the worktree gate did not inspect an unchanged oracle. An unrelated dirty file can therefore produce a green gate while the named test disagrees with its card.

## Objective

Give verifiers an executable installed-checker command and independently check the named digest in the subscriber worktree.

## Inputs

- `scripts/check-contract-test-gate.sh`
- `templates/verifier-prompt.md`
- `scripts/spawn-verifier.sh`
- `scripts/spawn-verifier-panel.sh`
- `scripts/verify-sdk.py`
- `docs/dispatch-contract.md`
- `scripts/named-verifier-contract-smoke.sh`

## Deliverables

1. `scripts/check-contract-test-gate.sh` Verify the card’s named oracle and changed candidates in a single invocation.
2. `templates/verifier-prompt.md` Describe the executed check and the effect of missing or failing evidence.
3. `scripts/spawn-verifier.sh` Supply the canonical command to a single CLI verifier.
4. `scripts/spawn-verifier-panel.sh` Supply the same command to the panel CLI independently of vendored template age.
5. `scripts/verify-sdk.py` Supply reproducible contract evidence through the per-stage SDK context used by all SDK transports.
6. `docs/dispatch-contract.md` Document the standalone verbs and subscriber verification command.

## Constraints

Keep the existing frozen tests and digests intact. Use temporary fixtures for acceptance. The worker writes its envelope and the verifier writes an independent verdict with observed results for each criterion.

## Acceptance criteria

1. Add --verify-card CARD to the canonical checker. Resolve the test named in the Contract test section against the subscriber root, verify the marker belongs to that card, and compare the printed digest with the declared digest. Retain the existing worktree change gate. A clean tree with a valid named oracle passes this combined command. Missing files, malformed declarations, mismatches or unrelated changed candidates that violate the freeze gate fail. Preserve the standalone checker verbs and the valid no-oracle card convention.
2. Provide the installed checker and actual card to CLI and panel verifiers. Preserve subscriber-specific prompt content, including older vendored templates. An old relative instruction must be superseded unambiguously. The shared SDK route must supply the executed check result for transports without a shell. A required check failure precludes a PASS. Keep cacheable prompt material free of per-stage paths.
3. Run the frozen combined-command fixture against a throwaway subscriber with spaces in its path. Capture rendered CLI, panel and shared SDK evidence offline for the good and mismatched card. Show how the result reaches the verifier and how a mismatch prevents acceptance. The verifier independently repeats the captures.

Both seats run `bash scripts/named-verifier-contract-smoke.sh`. The judging seat is the independent Claude verifier. Run these regression commands separately from the repository root:

- `bash scripts/verify-sdk-schema-path-smoke.sh`

## Review decisions

Installed means the checker shipped alongside the effective verifier scripts. Execute in the subscriber worktree and quote paths for the shell. For a named oracle, exit zero only when its owning marker, declared digest, actual digest and ordinary changed-candidate checks all agree. Treat the standalone worktree checker’s empty-change result separately from a real check error. Preserve explicit no-oracle cards. Show the effective command in CLI and panel prompts, keeping subscriber prose and explicitly overriding a stale repo-local method. Include a concise contract PASS or FAIL receipt, with the checked path and evidence, in the shared SDK per-stage context. A failed check must produce a failing verification or stop acceptance before a PASS is consumed. The oracle captures actual prompts at a fake transport and calls the same SDK variable builder used in production. Record the checker exit, digest pair and routed result in the verifier artefact. Test the checker and SDK failure on an unchanged committed mismatch.

The SDK schema-path regression passed, including its existing subscriber-template precedence check.

## Contract test

- **Test file:** `scripts/named-verifier-contract-smoke.sh`
- **Assertions digest:** `sha256:015acd6846d646fd5c60d135e98602a607a6ea126fbf60bc0c4d80790a2a06f7`
- **Oracle proof:** Base `d93e651` is red. The installed checker rejects --verify-card as an unknown argument for a valid clean subscriber. The oracle also covers clean committed mismatches, missing files and unrelated changed candidates. Base rejects the combined command. Independently exercised the real single CLI and panel with stub transports and the shared SDK builder: both CLI captures contained the 98-byte stale subscriber prompt, and the SDK could build context offline. Existing print generated a digest from the positive fixture. A complete positive cross-route reference would implement the worker change. The independent verifier must run the frozen positive and negative scenarios.

## Out of scope

Fleet dispatch, provider spend authorisation, publishing, policy changes and alterations to earlier contracts.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes
- **Spend basis:** The nine nonzero November worker rows and nine verifier rows in the repo cost log had medians of 975,595 and 972,937 cache-inclusive tokens. Allow 1.95M for one pair, including about 1.80M cached input by the sum of role medians. A diagnosed retry is another pair. The batch estimate is 7.79M first-pass plus 9.90M pooled outlier allowance (sum of role p95s). Four separate retries would add about 7.79M. Preparation checkpoint is 195k cache-inclusive per card, including the shared cold read. The wall-clock ceilings allow diagnostic replay and exceed the November role p95s of 17m06s and 11m12s. The pooled cold read used 113,248 cache-inclusive tokens (66,252 cache reads, 43,407 cache writes). At the final readiness check the shared Codex preparation turn had reached 11.20M cache-inclusive tokens, including 11.09M cached input. This exceeded the 780k batch checkpoint. Stop additional preparation experiments; any execution and its spend need the separate queue decision.

## Dispatch envelope

Write the worker evidence to `state/envelopes/177-named-verifier-contract.json`. The verifier records commands, exit codes, the observed fixture values and any missing evidence in `state/verifiers/177-named-verifier-contract.json`; missing evidence prevents overall PASS. Keep the verifier evidence independent of the worker's interpretation.

## Family-specific notes

Run offline fixtures locally. A missing or skipped required result prevents acceptance.

## Recovery log

Attempt 1 started 2026-11-18 20:48:49 UTC from `d63459b`. Worker PASS, independent verifier FAIL on compatibility with earlier frozen dispatch smokes. Three functional criteria passed. The tick preserved the exact failed work at `9d136b0ccc2868675a17e40c93b4257fdadb24c2`. Archived evidence is under `state/uat/177-named-verifier-contract/attempt-1/`. The attempt used 3,394,760 cache-inclusive tokens. Attempt 2 is authorised as a narrow repair, with two lifetime worker attempts left including this one.

## Repair brief for attempt 2

Restore only the six numbered deliverables from the preserved commit, using `git show <wip>:<path>` to recover each file. Leave the card, runtime state and frozen tests intact. Against the preserved implementation, reproduce the failure of a section-less or explicit no-oracle fixture outside Git or with an unborn HEAD. Preserve the established dispatch behaviour where the card has no executable oracle and no revision exists for a change gate. Keep real worktree checking where applicable, and fail closed for missing, malformed or mismatched *named* oracles. Check whether the shared checker alone can resolve it. Keep the repair diff relative to the preserved commit as small as the evidence allows.

Both seats run the existing named oracle and SDK schema-path smoke. The independent verifier also runs all six regression scripts under `scripts/`: `effort-flags-smoke.sh`, `mcp-isolation-smoke.sh`, `small-dispatch-fixes-smoke.sh`, `state-writable-smoke.sh`, `claude-chrome-smoke.sh` and `local-route-smoke.sh`. Use each script's offline fixtures; record actual exit codes. Where a worker sandbox cannot exercise host process inspection or a socket, state the gap in the envelope and have the independent verifier run that command. Compare named, legacy and unrelated-dirty-candidate cases. A wider diff requires full independent re-verification. The first verifier's FAIL and frozen digest remain in evidence.
