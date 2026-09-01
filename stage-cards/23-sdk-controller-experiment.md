# Stage card 23-sdk-controller-experiment: Bounded experiment — long-lived SDK session as an alternative phat-controller

## Metadata

- **Authored:** 2026-05-27 (re-briefed 2026-08-31 for queueing: seats
  moved to current identities, run metadata added; scope unchanged)
- **Orchestrator:** Claude Fable 5 <claude-fable-5@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Opus 5 <claude-opus-5@local>
- **Base branch:** dev
- **Run branch:** autometta/23-sdk-controller-experiment
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Gate:** stage-completed: 97-a-pause-is-not-a-stall
- **Path claims:** scripts/controller-sdk-experiment.py, tests/sdk-controller-experiment/, docs/experiments/sdk-controller-postmortem.md, memory/decision-sdk-controller-experiment.md, docs/philosophy.md
- **Pairing rationale:** Cross-family. Codex builds a deliberately minimal prototype; Claude verifies that the prototype's failure modes are accurately reported in the postmortem (this stage's deliverable is partly a negative result, and the verifier's job is to confirm honesty).
- **Type:** Experiment-with-postmortem. The expected outcome is "we don't want this" — but the experiment validates that, rather than asserting it.

## Surfacing concern

The cron+tick architecture was a deliberate choice (load-bearing belief: "cron + tick > daemon"). Periodically the question comes up: would a long-lived Claude Agent SDK session per repo, holding state in-process, be simpler? The SDK supports it; many adjacent agent frameworks default to it. Rather than re-litigate the design every time, do the experiment once, on a bounded scope, and capture the postmortem as decision memory. Future "should we make the controller persistent?" questions get answered with a link.

## Objective

Build a deliberately-minimal `scripts/controller-sdk-experiment.py` that runs as a long-lived SDK session against this repo, polls `state.yaml` in-process, and dispatches one worker + verifier per stage transition. Run it against two synthetic test stages. Write a postmortem comparing it to the existing cron-tick controller across: resumability, observability, cost, failure recovery, and "what happens when the process dies mid-stage". The postmortem is the actual deliverable; the script is the apparatus.

## Inputs

- `scripts/tick.sh` — the existing cron-tick controller (the baseline being compared against).
- `docs/phat-controller.md` — current design.
- `docs/philosophy.md` — the "cron + tick > daemon" belief being pressure-tested.
- `state/state.yaml` schema — `schemas/state.yaml.json`.

## Deliverables

1. `scripts/controller-sdk-experiment.py` — the long-lived SDK controller prototype. Deliberately minimal: no LaunchAgent integration, no heartbeat, no budget enforcement beyond a hard wall-clock cap. Marked clearly in its docstring as `EXPERIMENT, do not productionise`.
2. `tests/sdk-controller-experiment/stage-A.md` — synthetic test stage, trivial worker task (`echo hello > /tmp/sdk-exp-A.txt`).
3. `tests/sdk-controller-experiment/stage-B.md` — synthetic test stage that deliberately fails in the worker step (so we test the failure path).
4. `docs/experiments/sdk-controller-postmortem.md` — the postmortem. Required sections: Hypothesis; What was built; What was observed (run logs for both test stages); Comparison matrix (cron-tick vs SDK-session across the five axes above); Decision and reasoning; What changes about future design conversations as a result.
5. `memory/decision-sdk-controller-experiment.md` — decision memo. Why we ran the experiment, what the postmortem concluded, why the result generalises (or doesn't).
6. `docs/philosophy.md` — minimal edit (≤ 5 lines): add a one-line reference to the experiment under "cron + tick > daemon" with the postmortem path.

## Constraints

- Experiment script must not be installable via the brew tap. It lives under `scripts/` but is not wired into `bin/autometta` or any LaunchAgent.
- Experiment must not write to `state/state.yaml` for the real autometta state; tests use a separate `tests/sdk-controller-experiment/state.yaml`.
- Experiment must run end-to-end in under 30 minutes total wall-clock. Hard cap in the script.
- Postmortem must reach an explicit decision (not "needs more investigation"). Negative results are valuable; ambivalence is not.
- Postmortem comparison matrix must use the five exact axes listed in the Objective.
- No new dependencies beyond the Agent SDK already added in 15a.
- British English, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

1. `scripts/controller-sdk-experiment.py --help` prints usage and exits 0.
2. Running the experiment against `tests/sdk-controller-experiment/stage-A.md` produces `/tmp/sdk-exp-A.txt` and transitions the test `state.yaml` to `completed`.
3. Running against `tests/sdk-controller-experiment/stage-B.md` produces a failure that is captured in the test `state.yaml` as `failed` (or whichever terminal state the experiment chose to map "worker failure" to — documented in the postmortem).
4. Killing the experiment process mid-run (operator sends SIGTERM) is observed and reported in the postmortem comparison matrix.
5. `docs/experiments/sdk-controller-postmortem.md` has all required sections including an explicit Decision.
6. The Decision concludes one of: "keep cron+tick", "migrate to SDK-session", "hybrid". Whichever it is, the postmortem says so in plain words.
7. `memory/decision-sdk-controller-experiment.md` follows the decision-memo format and links to `[[decision-handoff-envelope]]`.
8. `docs/philosophy.md` edit is at most five lines and additive.
9. The experiment script is not referenced from `bin/autometta`, any LaunchAgent plist, or `scripts/install-homebrew-local.sh`.
10. No regressions in real `state/state.yaml`, `state/budget.json`, or `state/verifiers/`.

## Out of scope

- Productionising the SDK controller, regardless of postmortem outcome. If the conclusion is "migrate", that triggers a separate card.
- Hybrid SDK + cron architecture. Mentioned in the postmortem Decision if applicable; not built here.
- Multi-repo SDK controller (one session, many repos).
- Cost comparison at scale. Per-tick cost estimate is in the postmortem; multi-day projections are not.

## Budget

- **Worker wall-clock:** 90 minutes.
- **Verifier wall-clock:** 30 minutes.

## Verifier handoff

Worker writes the deliverables, runs both test stages, and pastes the test-`state.yaml` diffs and the experiment log lines in completion message. Worker writes `state/handoffs/23-sdk-controller-experiment.json`. Verifier reads the card, the script, the postmortem, and the test `state.yaml` diffs; confirms the postmortem reaches an explicit Decision; and writes `state/verifiers/23-sdk-controller-experiment.json`.

## Family-specific notes

- **Codex (worker):** stdin redirect for any subprocess. Sandbox `workspace-write` is sufficient; tests write to `/tmp` and to `tests/sdk-controller-experiment/`.
- **Claude (verifier):** the verifier does NOT need to run the SDK experiment itself; it reads the postmortem and the test artefacts. This is a deliberate cost guard.

## Re-brief note (2026-08-31 22:45 BST, minder)

Auth-route finding from tonight's run, load-bearing for this card: the
long-lived session MUST be built on the `claude-agent-sdk` package, which
drives the Claude Code engine and honours the subscription OAuth token.
Do NOT use `scripts/verify-sdk.py` as prior art: despite its name it
instantiates the raw `anthropic` client against the Messages API, and that
path is refused instantly with a 429 on subscription OAuth (two refusals
tonight, request ids req_011CebUkhN159VXfD28zBFci and
req_011CebX8zh975kvsSmKpt2ST, while `claude -p` on the same account worked
throughout). If any API call in this experiment is refused with a 429 on
the first request, stop and record the refusal in the postmortem rather
than retrying; a first-request 429 here means the auth route, not load.

## Re-brief note (2026-09-01, orchestrator) — attempt 2

Attempt 1 returned a `partial` envelope and the verifier scored 7 of 10.
Criteria 1, 3, 5, 6, 8, 9 and 10 passed and the work behind them is sound;
do not rebuild them. Three criteria failed, and all three are in reach.

**Criterion 2 — stage A never completed.** This is the one that matters,
because it is the apparatus failing rather than the experiment returning a
negative result. `tests/sdk-controller-experiment/stage-A.md` is correct as
written: its worker command is `echo hello > /tmp/sdk-exp-A.txt`, a command
that cannot fail on its own merits. The run log
(`state/logs/23-sdk-controller-experiment-worker.log:11682-11686`) shows
`stage-A: worker dispatched` then `stage-A: failed: worker` for it and for
stage B alike, so the session reported failure for a command that should
have succeeded. Diagnose why before changing anything: capture the worker
subprocess's exit status, stdout and stderr and put them in the log, rather
than collapsing every outcome to `failed: worker`. If the cause is that the
session's own sandbox refuses the `/tmp` write, say so plainly and move the
fixture's target inside `tests/sdk-controller-experiment/`, updating the
acceptance criterion's path in the postmortem to match. An experiment whose
apparatus cannot run its own success case has not tested the hypothesis, so
the Decision cannot rest on it until stage A completes for a real reason.

**Criterion 4 — the SIGTERM was asserted, not observed.** The postmortem
describes what would happen on SIGTERM as a design property. Actually send
it: start the session against a stage, `kill -TERM` the process mid-run,
and record what the test `state.yaml` and the log hold afterwards. Quote
the observed state in the comparison matrix. If the observed behaviour
differs from the design claim, the observation wins and the matrix says so.

**Criterion 7 — the decision memo has no frontmatter.** `memory/README.md`
mandates YAML frontmatter with `name`, `description` and `metadata.type`,
plus a **Why:** / **How to apply:** pair for a project-type memory. The
`[[decision-handoff-envelope]]` wikilink is already present and correct;
keep it and add the missing envelope.

The 2026-08-31 auth-route finding below still stands in full: build on
`claude-agent-sdk`, never the raw `anthropic` client, and treat a
first-request 429 as an auth-route verdict to be recorded rather than
retried.

Prior attempt's work is preserved at `wip/23-sdk-controller-experiment-attempt-1`
(commit `94570284`). Start from it rather than from an empty tree.
