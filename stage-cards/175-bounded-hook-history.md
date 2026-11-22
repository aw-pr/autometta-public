# Stage card 175: Bound historical notices in active chats

## Metadata

- **Authored:** 2026-11-18
- **Orchestrator:** GPT-6.1 Sol <gpt-6-1-sol@local>
- **Worker:** GPT-6.2 Astra <gpt-6-2-astra@local>
- **Verifier:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Base branch:** dev
- **Run branch:** autometta/175-bounded-hook-history
- **Proposal:** P-20261116-86fa
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Recovery attempts:** 3
- **Recovery attempt:** 1
- **Dispatch:** serial
- **Path claims:** scripts/hooks/escalation-context.py, scripts/hooks/session-start-escalations.sh, scripts/lib/lifecycle_events.py, docs/tick-loop.md
- **Pairing rationale:** Premium Codex worker and independent Claude verifier as approved for this harness batch. The worker must reconcile existing callers and archived formats. Verification requires judgement about the evidence from the normal entry points. Run one card at a time because the changes affect shared harness behaviour.
- **Open decisions:** none
- **Cold read:** Claude Sonnet, pooled read-only review on 2026-11-18. Findings and resolutions below.

## Surfacing concern

A new design chat received 489 records from other subscribers. Routine hooks continued releasing ten per call. This is active-chat context injection. Idle wake reservations have a separate delivery path.

## Objective

Give a project chat its own current evidence and a fleet chat a single compact account of completed history.

## Inputs

- `scripts/hooks/escalation-context.py`
- `scripts/hooks/session-start-escalations.sh`
- `scripts/lib/lifecycle_events.py`
- `docs/tick-loop.md`
- `scripts/bounded-hook-history-smoke.sh`

## Deliverables

1. `scripts/hooks/escalation-context.py` Classify the project and condense catch-up records while preserving session deduplication.
2. `scripts/hooks/session-start-escalations.sh` Resolve the scope used for live lifecycle delivery; preserve escalation and fleet broker semantics.
3. `scripts/lib/lifecycle_events.py` Supply scope and lifecycle grouping data where needed by the hook.
4. `docs/tick-loop.md` Describe project, fleet and catch-up delivery.

## Constraints

Keep the existing frozen tests and digests intact. Use temporary fixtures for acceptance. The worker writes its envelope and the verifier writes an independent verdict with observed results for each criterion.

## Acceptance criteria

1. Scope routine lifecycle evidence in an unsubscribed Git checkout to that project. Retain existing subscribed-repo scoping and the fleet view from a non-project directory. Fleet-wide quota notices retain their cross-repo scope. Pending escalation visibility and native wake ownership keep their existing contracts.
2. At first delivery, startup, clear or compaction, condense older completed-run history to a brief summary. Use run identity and terminal stage evidence where available. Keep outstanding failures, awaiting integrations and pending escalations actionable, even if older than routine history. Mark all condensed rows seen in one pass. Preserve new events and the existing fresh-event pagination. Older records may lack run IDs, so never infer that an unresolved stage landed from another run finishing.
3. Both hook families pass the frozen smoke. Its fixture includes an unsubscribed Git checkout, a fleet directory, two subscribers, a finished run, an unresolved failure, a pending escalation, and new activity after catch-up. Repeated user prompts stay quiet until something changes. Independently check first invocation on an already-open chat whose delivery cache contains a partially drained backlog.

Both seats run `bash scripts/bounded-hook-history-smoke.sh`. The judging seat is the independent Claude verifier. Run these regression commands separately from the repository root:

- `bash scripts/escalation-context-smoke.sh`
- `bash scripts/wakeups-smoke.sh`

## Review decisions

Live scope comes from the deepest enabled subscriber containing the physical working directory. A Git project or linked worktree outside that scope receives no unrelated repo history. Preserve the existing non-project fleet view and pending-escalation rules. In the 48-row finished-history fixture the first fleet catch-up including one pending escalation and one unresolved failure fits in fewer than 4,500 characters. Use evidence of landing to fold closed work. Legacy records with no run ID must not hide an unresolved failure. Apply catch-up to an existing partially drained cache on upgrade. The regression suite covers fresh-event paging and the quota broadcast. The ps stub identifies the simulated reader as interactive in either verifier seat.

Both regression suites passed on the preparation base (21 context tests and 27 wake tests).

## Contract test

- **Test file:** `scripts/bounded-hook-history-smoke.sh`
- **Assertions digest:** `sha256:4833e490cb99ffc1e190b8c06dd24ae51f7f94dbdaa96d10e960bef77a5f312f`
- **Oracle proof:** Base `d93e651` is red. The base leaks historical rows into the design chat and orders an outstanding failure behind old detail. The fresh-session regression fixture remains applicable. The production hook returned historical detail in the Git design chat and omitted the outstanding action from the initial fleet batch. The replay includes an older partially drained cache and a legacy unresolved event. Controls for normal fresh-event delivery, pagination and quota broadcasts passed in the existing hook and wake suites. A second hook implementation would reproduce the worker task, so the positive end-to-end change is reserved for independent acceptance.

## Out of scope

Fleet dispatch, provider spend authorisation, publishing, policy changes and alterations to earlier contracts.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes
- **Spend basis:** The nine nonzero November worker rows and nine verifier rows in the repo cost log had medians of 975,595 and 972,937 cache-inclusive tokens. Allow 1.95M for one pair, including about 1.80M cached input by the sum of role medians. A diagnosed retry is another pair. The batch estimate is 7.79M first-pass plus 9.90M pooled outlier allowance (sum of role p95s). Four separate retries would add about 7.79M. Preparation checkpoint is 195k cache-inclusive per card, including the shared cold read. The wall-clock ceilings allow diagnostic replay and exceed the November role p95s of 17m06s and 11m12s. The pooled cold read used 113,248 cache-inclusive tokens (66,252 cache reads, 43,407 cache writes). At the final readiness check the shared Codex preparation turn had reached 11.20M cache-inclusive tokens, including 11.09M cached input. This exceeded the 780k batch checkpoint. Stop additional preparation experiments; any execution and its spend need the separate queue decision.

## Dispatch envelope

Write the worker evidence to `state/envelopes/175-bounded-hook-history.json`. The verifier records commands, exit codes, the observed fixture values and any missing evidence in `state/verifiers/175-bounded-hook-history.json`; missing evidence prevents overall PASS. Keep the verifier evidence independent of the worker's interpretation.

## Family-specific notes

Run offline fixtures locally. A missing or skipped required result prevents acceptance.
