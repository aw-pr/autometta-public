# Stage card 35-usage-error-should-not-burn-a-retry: three identical instant failures help nobody

## Metadata

- **Authored:** 2026-08-16
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Fable 5 <claude-fable-5@local>
- **Worker effort:** medium
- **Verifier effort:** medium
- **Verifier panel:** false
- **Pairing rationale:** cross-family. Same surface as card 34 and the same
  split, so the retry-budget change is checked by the family that did not
  write it.

## Objective

A verifier that dies in under a second with a CLI usage error consumes one of
three `verifier_attempt_cap` retries, and the next two attempts fail
identically. The retry budget exists to absorb a flaky verifier; a malformed
command line is not flaky, it is deterministic.

Distinguish a configuration fault from a failed verification.

## Reported by

Raised by card 30 as its fifth deliverable and deliberately left unimplemented
there. On 2026-08-14 in `emergence-lab`, a Claude verifier with a declared
effort produced a 38-byte log reading `error: unknown option '--effort high'`
and exited in well under a second. Three attempts, three identical logs, stage
marked `stalled`. The stage's real defence against a genuinely flaky verifier
was spent on a typo-class fault that no number of retries could fix.

Card 30 fixed that particular usage error. This card is about the class: the
next malformed flag, missing binary, or bad auth route will do the same thing.

## The shape of the fix

An instant exit with a usage error on stderr is distinguishable from a real
verification failure by evidence already on disk: sub-second wall-clock, a log
too small to contain any verifier output, no verifier artefact written, and a
non-zero exit consistent with argument parsing. Any one of those alone is
weak — a fast exit could be a crash worth retrying — so prefer a conjunction,
and prefer halting the stage with a distinct reason over silently not counting
the attempt. An operator needs to be told their configuration is wrong; an
uncounted retry that loops forever is a worse outcome than a burnt one.

Do not go further than this card asks. Redesigning the retry policy was
explicitly out of scope on card 30 and stays out of scope here: the change is
one classification and one halt reason, not a new failure taxonomy.

## Inputs (read these in your own context)

- scripts/tick.sh — around line 953, the `verifier_attempt_cap` accounting and
  the retry decision
- scripts/spawn-verifier.sh — the dispatch and what it can report back
- scripts/budget.sh — `budget_halt` and existing halt reasons, for consistency
- schemas/state.yaml.json — `verifier_attempts` and stage status values
- docs/phat-controller.md — the retry and halt model as documented
- `~/repos/emergence-lab/state/logs/` — real 38-byte failure logs to test against

## Deliverables

1. A classification of instant CLI usage errors as configuration faults rather
   than verification attempts, applied at the point the attempt would be
   counted.
2. A distinct halt reason so the operator learns the configuration is wrong,
   rather than the stage stalling as though verification had been tried.
3. The same treatment for the worker path if it shares the defect — check
   rather than assume.
4. A regression test using a real short usage-error log, asserting the attempt
   is not counted and the halt reason is the configuration one. Offline, no
   dispatch.
5. `docs/phat-controller.md` updated to describe the distinction.

## Constraints

- Do not add retries, backoff, or a circuit breaker. This is a classification,
  not a new policy.
- Do not let a misclassified fault retry forever: a configuration fault halts,
  it does not become an infinite loop.
- A genuine verifier failure must still consume an attempt exactly as now.
- Do not change `verifier_attempt_cap`'s default.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. The repo's own acceptance suite is green.
2. A stage whose verifier exits instantly with a usage error halts with the
   configuration reason and has consumed no attempt.
3. A stage whose verifier runs properly and returns FAIL still consumes an
   attempt and still retries up to the cap.
4. The regression test fails against the pre-fix commit. Check it out, run it,
   state the failure.
5. No path exists where a configuration fault retries without bound.
6. `docs/phat-controller.md` describes the behaviour.

## Contract test

- **Test file:** <<fill at dispatch>>
- **Assertions digest:** <<fill at dispatch>>

## Out of scope

- Redesigning the retry policy or the failure taxonomy.
- The effort-flag bug itself, fixed in card 30.
- Panel-verifier quorum behaviour.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes

## Verifier handoff

Worker reports: the signals used to classify a configuration fault and why that
conjunction is not satisfied by a real verification failure; where the
classification is applied; whether the worker path shared the defect; and the
regression test's failure output against the pre-fix commit.

## Family-specific notes

None. Everything here is testable from logs already on disk.
