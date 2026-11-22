# Stage card 183: Commit the summary on finish or halt

## Metadata

- **Authored:** 2026-11-22
- **Orchestrator:** GPT-6.2 Astra <gpt-6-2-astra@local>
- **Worker:** Claude Sonnet 5.5 <claude-sonnet-5-5@local>
- **Verifier:** GPT-6.2 Sol <gpt-6-2-sol@local>
- **Base branch:** dev
- **Run branch:** autometta/183-commit-run-summary
- **Worker effort:** medium
- **Verifier effort:** medium
- **Verifier panel:** false
- **Recovery attempts:** 3
- **Recovery attempt:** 3
- **Dispatch:** serial
- **Gate:** stage-completed: 182-portable-run-summary
- **Pairing rationale:** Sonnet implements the Git integration and tick boundary. Sol independently inspects commit trees, index contents and recovery.
- **Open decisions:** none
- **Cold read:** Claude Sonnet, pooled read-only preparation review on 22 November 2026.

## Surfacing concern

A run can finish while the operator has unrelated changes staged. A repo halt may be observed repeatedly, and a halted run can later finish. A summary belongs on the subscriber’s declared private working branch without moving any publication branch or collecting the operator’s files.

## Objective

On finish or halt, commit the renderer’s summary at runs/<run-id>.json on the opted-in subscriber’s private working branch.

## Inputs

- `scripts/tick.sh`
- `scripts/lib/lifecycle_events.py`
- `scripts/budget.sh`
- `scripts/publish-sync.sh`
- `docs/tick-loop.md`
- `docs/setup.md`

## Deliverables

1. Integrate the summary commit with the tick and document opt-in, branch eligibility, outcome attribution, stale or ambiguous state and local recovery.
2. The verifier runs the real tick wrapper in temporary Git repos, with agents stubbed. Show finish, halt and resume then finish, repeat tick, awaiting integration, private-path/protected branch refusals, and a competing change to the destination. Record git log/diff/index evidence and show one readable summary from a fresh local clone. Include a failure/retry case and the unchanged reference and index on refusal. Keep this evidence in the verdict.

## Acceptance criteria

1. Wire the feature into the normal per-repo tick. A subscriber opts in by declaring run_history.private_branch in its local manifest; this is the operator’s declaration of a private destination. Require that branch to match the configured base branch and respect protected/publish refs, trunk policy and mirror private-path rules. In publish-mirror repos require runs or its enclosing directory to be covered by publishguard.privatefile. Leave unconfigured subscribers and unrelated repos alone. Provide setup instructions; enabling the feature anywhere is a later operator action.
2. On the existing finished-run boundary or an actual repo budget halt attributable to a single run, write runs/<run-id>.json using stage 182. An awaiting integration, ordinary pause, idle tick, single stage failure without a repo halt, or ambiguous/stale/absent run id must not generate a terminal commit. On halt use the run active at the halt, including pending stages with an unambiguous run. A later finish updates the same file; Git history retains the halted version. Use durable state, not notification delivery, for attribution. Avoid backfilling unrelated old runs on enablement.
3. Create exactly one local path-limited commit per distinct boundary summary, with standard harness attribution. Retrying the tick, restart after an interruption or duplicate observation must converge. Reconcile already-written content before retry; if writing cannot complete safely, preserve state, make the reason observable, and retry when possible without blocking workers. Cover repo-lock/branch-tip races and pre-existing operator edits to the output path. Preserve the real index, staged and unstaged work, checkout and other refs. Reuse established Git isolation and branch-policy helpers where applicable. Derive the output path only from a validated run id. Never create a remote push, switch branches or change subscriber settings in this feature.

Both seats run `bash scripts/commit-run-summary-contract-smoke.sh` in the run worktree. The independent verifier records actual observations for all criteria, including the edge cases in Deliverables. Missing evidence prevents an overall PASS. Use temporary repos; no live dispatch or subscriber write is part of acceptance.

## Review decisions

Stage 182 supplies the renderer before 183 starts. Stage 183 owns run selection from subscriber state. The verifier additionally injects a competing branch-tip change, ambiguous halt and ordinary pause, and records before/after refs and outcomes.

## Contract test

- **Test file:** `scripts/commit-run-summary-contract-smoke.sh`
- **Assertions digest:** `sha256:02d4361bab30ac06f435f8327f5d12bda20559bfb9b7e69dcd858aff9c38e0ef`
- **Oracle proof:** On 4fbfe08 the fixture reaches the opted-in halt but no commit appears. A disposable tick adapter passed the Git assertions for dirty index, opt-in, protected ref, private-path coverage, output conflict, retry and clone.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes
- **Spend basis:** 2.65M cache-inclusive tokens for one pair. Five comparable pairs from stages 179–181 ranged from 0.75M to 2.65M; allow extra implementation work for repo-safe persistence. Batch estimate 4.25M first pass plus 4.25M pooled retry planning headroom. Review preparation at 10% of first-pass estimates. The preparation check across both cards recorded 2,168,213 primary-chat tokens, including 2,137,344 cached input, and 52,153 read-only reviewer tokens, including 24,578 cache reads. This exceeded the 425k preparation checkpoint. Recheck headroom when queueing is authorised.

## Out of scope

Fleet rollout, auto-push, release or deployment, changes to handoff, and wholesale commits of the runtime state directory.

## Dispatch envelope

Worker evidence goes in `state/envelopes/183-commit-run-summary.json`. The independent verifier writes `state/verifiers/183-commit-run-summary.json`.

## Recovery log

1. Attempt 1 started 2026-11-22 15:46:20 UTC from 3b5fe88. Worker PASS, independent verifier FAIL on all three criteria. WIP 12d6624cb751a7f8217fd00cb40942edeb23fb39 preserves the five deliverables. Archive `state/uat/183-commit-run-summary/attempt-1/` holds the exact verdict, envelope, logs, costs, original card and oracle, and the before/after fixture runs. Attempt cost was 3,779,947 cache-inclusive tokens and 1,354 role seconds. Attempt 2 uses the same cross-family pair and both roles at medium effort. One further attempt is available only after a new diagnosis and within the existing gates.

2. Attempt 2 started 2026-11-22 16:11:40 UTC from 54edf59. Worker PASS, independent verifier FAIL on all three criteria. Five deliverables preserved at 73562f0b809a9a823156ab6a945f547b6a0284b4. See `state/uat/183-commit-run-summary/attempt-2/verifier.json` for observed failures and successful controls. Cost 2,299,208 cache-inclusive tokens and 679 role seconds. Attempt 3 is the final worker start.

The final branch refusal in the original fixture reused a handled halt timestamp. The orchestrator gave this case a fresh run and halt. On the same preserved implementation, the original fixture passed without a publish refusal; the corrected fixture observed the publish refusal and the earlier successful private commits. The corrected fixture remains red on the base where summary commits are absent. Original assertions digest sha256:61024339657ab71a83da8b78748cee7da76cabdd492359424eeec003cae078b4, replacement sha256:02d4361bab30ac06f435f8327f5d12bda20559bfb9b7e69dcd858aff9c38e0ef. Criteria and independent evidence requirements remain as originally approved.

## Re-brief for attempt 2

Adopt the five deliverables first using `git restore --source=12d6624cb751a7f8217fd00cb40942edeb23fb39 --worktree -- docs/setup.md docs/tick-loop.md scripts/commit-run-summary.sh scripts/lib/lifecycle_events.py scripts/tick.sh`. Keep the current card and frozen test. Read the archived verifier criteria for observed results. Repair the three failed mechanisms together and preserve the successful cases.

1. Enforce eligibility on the actual private destination throughout the Git transaction. Refuse symbolic or otherwise ambiguous destinations. Match configured private paths literally, consistent with publish-sync. Whitespace around a different path cannot confer coverage for runs. Independently verify the protected refs stay fixed and a valid private destination still commits.
2. Separate the pre-transition baseline from the post-transition evidence on the first opted-in tick. Pre-existing completed work stays historical. A finish or attributable budget halt during that first tick gets recorded. Persist the run identity or the unresolved attribution of each halt at its occurrence. An unchanged ambiguous episode cannot become attributable because the queue later changes. Preserve retries for known boundaries when a file conflict clears. Verify first-tick halt with the actual budget path, first-tick finish, historical enablement and ambiguous halt followed by changed membership.
3. Preserve both operator file content and Git metadata throughout commit, retry and recovery. A mode-only edit is an edit. On contention, preserve newer staged entries and independent worktree changes. Avoid unconditional restoration of earlier bytes or index entries. Record enough transaction provenance and boundary content before a partial write to reconcile after interruption even if newer run evidence arrives. Demonstrate halt then finish survive interruption and converge once, with operator data intact. Exercise competing branch and destination changes, executable mode, fresh-clone visibility and repeat ticks. All fixtures are disposable and offline.

Both seats run the corrected frozen command and focused regressions. The verifier supplies independent before/after branch refs, staged blobs, worktree content/mode, summary commit counts and restart outcomes for every previously failed case. Confirm a real eligible boundary reaches each refusal control and record its reason. Preserve all existing branch, opt-in, no-push and operator-scope constraints. Record commands and evidence in the verdict.

## Re-brief for attempt 3

Start from attempt 2. This supersedes the earlier restoration instruction. In the new worktree run `git restore --source=73562f0b809a9a823156ab6a945f547b6a0284b4 --worktree -- docs/setup.md docs/tick-loop.md scripts/commit-run-summary.sh scripts/lib/lifecycle_events.py scripts/tick.sh`. Retain the current card and frozen oracle. Use the attempt-2 verdict as the evidence inventory. The baseline, pinned halt attribution, content journal and interrupted-ref recovery all made verified progress. Keep those behaviours.

1. Make the eligibility decision effective at the ref update. Coordinate policy reads with changes to the repository policy and use a prepared Git reference transaction. Revalidate the destination's actual ref type, old tip and applicable protection while the transaction holds the destination lock, before committing it. Abort and retry or refuse if eligibility cannot be established. Preserve symbolic ref identity as well as object IDs. A repeated unlocked check still leaves the race. Retain positive private-branch operation and literal mirror-path coverage.
2. Preserve the complete opt-in baseline while runs remain represented by authoritative stage state. Never evict an unfinished journal entry, an unresolved current halt or a still-relevant closed ID to meet a fixed list length. Test 199, 200, 201 and a larger population with repeated idle ticks and restart. Historical runs yield no commits, followed by exactly one summary for a genuinely new boundary.
3. Protect checkout reconciliation. Hold the actual Git index lock across reading the current index, conditional path-only reconciliation and installation; preserve every unrelated entry and any new destination edit. Handle contention through the journal and release only locks owned by this invocation. Validate the output directory and target before the ref move and before reconciliation. Use operations anchored to a verified directory which do not follow symlink ancestors. Refuse an unsafe or ambiguous path and leave external data intact. Preserve worktree bytes, executable mode and independent staged bytes; never overwrite an edit to complete bookkeeping. Exercise the ref-pending recovery path, including an interrupted halt followed by finish. Update the recovery documentation to describe the final ordering and refusal semantics.

Use the approved offline verifier seat. Record observed refs and their types, index entries and hashes, worktree content and mode, summary counts and old/new run IDs for the failed boundaries and positive controls. Exercise normal process_repo, the frozen smoke, restart and fresh-clone checks. Keep earlier successful cases as regressions. Missing evidence fails the relevant criterion. The scope is private working-branch summaries; do not enable the feature on a subscriber. A third verifier failure parks the card.
