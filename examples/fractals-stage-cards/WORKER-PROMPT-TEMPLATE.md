# Worker prompt template

Canonical brief for a Codex CLI worker dispatched against one stage card. Derived from the K4 and U8 briefs (see git log on this file for worked examples). Keep it terse; one stage, one brief, one return.

For the surrounding pattern see `../HEADLESS-ORCHESTRATION.md`.

## Template

```
You are implementing stage <STAGE-ID> in this worktree (branch <BRANCH>).
Read docs/stages/<CARD>.md FIRST - it is the authoritative brief and
Acceptance is exact.

Context you need:
- <key files / line numbers / constants the worker must not have to grep for>
- <prior gates that must remain green; name each conformance test by symbol>

What to build:
- <bullet list of concrete deliverables, mirroring the card>

Hard constraints:
- DO NOT commit. The orchestrator commits.
- DO NOT push. DO NOT merge or sync from other branches.
- DO NOT use --no-verify on any commit you happen to make. The
  pre-commit publish-guard blocks absolute home-dir paths and
  personal patterns - keep paths relative.
- DO NOT run xcodebuild if your sandbox blocks DerivedData
  (workspace-write does). Report that and let the orchestrator run
  the gate.
- DO NOT weaken any prior Acceptance command or test.
- DO NOT bump contractVersion or any version constant the card does
  not name.

Acceptance command (run yourself only if your sandbox permits it;
otherwise stop after implementation and let the orchestrator run it):

    <exact command(s) from the stage card>

All prior gates listed in the card must still be green. The only
weakening you may apply is the one the card explicitly authorises.

When implementation is done, print:
  - <return value 1, e.g. new test name>
  - <return value 2, e.g. shape of the change>
  - <return value 3, e.g. files touched>
and stop. Do not summarise; do not narrate; do not retry the gate.

If your sandbox blocks something the card expects (e.g. .git/index.lock
or DerivedData), report the exact error verbatim and escalate. Do not
silently work around a sandbox failure.
```

## Notes on filling the template

- Pin the card path. The worker should not have to guess the filename.
- Name every prior conformance test the worker must not regress, as named symbols (`u7StateConformance_macOS`, `navGoldenParityFromFixtures`, etc.). The card already lists them; copy them in so the worker cannot miss them. (Lesson 5 in `HEADLESS-ORCHESTRATION.md`.)
- The expected return list is the only thing the orchestrator parses from the worker's output. Keep it to three or four items.
- Sandbox-class failures are escalations, not retries. The worker must say so explicitly.
