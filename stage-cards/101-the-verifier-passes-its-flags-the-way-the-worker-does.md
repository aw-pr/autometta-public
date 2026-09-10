# Stage card 101: the verifier passes its flags the way the worker does

## Metadata

- **Authored:** 2026-09-01
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Sonnet 5 <claude-sonnet-5@local>
- **Base branch:** dev
- **Run branch:** autometta/101-the-verifier-passes-its-flags-the-way-the-worker-does
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Path claims:** scripts/spawn-verifier.sh, scripts/effort-flags-smoke.sh, scripts/state-writable-smoke.sh
- **Pairing rationale:** cross-family. A Codex worker fixes a Codex dispatch
  path, and a Claude verifier judges it from outside that family, so the seat
  that decides whether the flags are right is not the seat that benefits from
  saying they are.
- **Type:** Defect fix on the dispatch path. Two red smokes, one cause.

## Surfacing concern

Two smokes have been red on a clean `dev` since before 2026-09-01 and were
recorded in the handoff as "the same codex-verifier argv adjacency assertion",
with the note that it "smells like one change to `spawn-verifier.sh` rather
than three faults". Measured on 2026-09-01, that reading is right, and the
fault is narrower than the note assumed:

```
effort-flags-smoke     PASS  codex high builds [-c] [model_reasoning_effort=high]
                       PASS  claude verifier passes --effort and high separately
                       FAIL  codex verifier passes -c and model_reasoning_effort=high separately

state-writable-smoke   PASS  a plain repo builds two argv elements
                       PASS  codex worker passes --add-dir and the state dir separately
                       FAIL  codex verifier passes --add-dir and the state dir separately
```

So the argv **builders** are correct, the **worker** dispatch is correct, and
the **claude verifier** is correct. Only the **codex verifier** flattens two
argv elements into one. Both smokes fail on the same seat for what is very
likely one line.

This matters beyond the smoke count: a flattened `-c model_reasoning_effort=high`
is not the flag codex parses, so a declared `Verifier effort` may be silently
inert on the codex route -- the same class of defect card 34 fixed for two
other routes. A red smoke on `dev` also erodes the signal every other green
smoke carries.

## Objective

Find why the codex verifier dispatch flattens its argv where the codex worker
does not, fix it, and leave both smokes green. One cause is expected; if it is
genuinely two, say so and fix both.

## Inputs (read these in your own context)

- `scripts/spawn-verifier.sh`, the codex dispatch branch and every site that
  threads `AUTOMETTA_EFFORT_ARGV` / `AUTOMETTA_CODEX_STATE_ARGV`
- `scripts/spawn-worker.sh`, the equivalent codex branch that passes -- this
  is the reference implementation, and the diff between the two is the lead
- `scripts/effort-flags-smoke.sh` and `scripts/state-writable-smoke.sh`,
  particularly `capture_dispatch` and how it records argv
- `scripts/models.sh`, the argv builders, which are already proven correct

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. The fix in `scripts/spawn-verifier.sh`.
2. If the capture harness is at fault rather than the dispatch -- that is, if
   the real argv is correct and only the smoke sees it flattened -- fix the
   harness instead and say so plainly. A green smoke obtained by weakening the
   assertion is not acceptable; a green smoke obtained by correcting a harness
   that was measuring the wrong thing is, provided the evidence is recorded.
3. Evidence distinguishing those two cases: capture the actual argv the codex
   verifier would exec, by whatever means shows the real word boundaries.

## Constraints

- **Do not weaken either assertion.** Adjacency is the property under test;
  a smoke that stops checking it is worthless. If an assertion is wrong,
  argue it in the handoff before changing it.
- The claude verifier, both SDK routes and the worker paths already pass. Do
  not touch them.
- No behaviour change for a stage that declares no effort: the builders emit
  nothing, and that must stay true.
- Keep the three-sandbox-site threading intact; `sandbox-grants-smoke.sh`
  asserts it and passes today.

## Acceptance criteria

1. `bash scripts/effort-flags-smoke.sh` passes.
2. `bash scripts/state-writable-smoke.sh` passes.
3. Both fail against the pre-change `spawn-verifier.sh`. Record both runs.
4. `bash scripts/sandbox-grants-smoke.sh` still passes, unchanged.
5. The handoff states, in one sentence, whether this was one cause or two, and
   names the line.
6. A codex verifier dispatched with a declared `Verifier effort` actually
   receives the flag as two argv elements, demonstrated from a real captured
   argv rather than from the smoke's own assertion.

## Contract test

- **Test file:** scripts/effort-flags-smoke.sh, scripts/state-writable-smoke.sh
- **Assertions digest:** the codex verifier passes `-c` and
  `model_reasoning_effort=high` as separate argv elements, and `--add-dir` and
  the state dir as separate argv elements.

## Out of scope

- `fleet-ticker-smoke.sh` and `tui-history-smoke.sh`, the other two red
  smokes. Different causes, their own cards.
- Any change to the argv builders in `models.sh`, which are proven correct.
- Adding new flags or grants.

## Budget

- **Worker wall-clock:** 60 minutes
- **Verifier wall-clock:** 30 minutes

## Escalation

If the fix requires changing what flags the codex verifier receives -- as
opposed to how they are passed -- stop and record it. That is a behaviour
change on the dispatch path of a live loop, and it needs an operator decision
rather than a worker's judgement.

## Verifier handoff

Run both smokes yourself, before and after, and confirm the "before" genuinely
fails: check out the pre-change `spawn-verifier.sh` into a scratch path rather
than trusting the worker's recorded run. A contract test that passes on both
sides proves nothing, and this card exists because two such tests sat red long
enough to be treated as furniture.

Disbelieve one thing specifically: that the assertion was not quietly relaxed.
Diff the two smoke files against their pre-change versions and confirm the
adjacency checks are intact. "Both smokes now pass" is trivially achievable by
deleting the two lines that fail, and that would leave the loop dispatching a
flag codex does not parse while reporting green.
