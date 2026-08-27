# Stage card 23-sdk-controller-experiment: Bounded experiment — long-lived SDK session as an alternative phat-controller

## Metadata

- **Authored:** 2026-05-27
- **Orchestrator:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Worker:** Codex GPT-5.3 <codex-gpt-5-3@local>
- **Verifier:** Claude Opus 4.7 <claude-opus-4-7@local>
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
