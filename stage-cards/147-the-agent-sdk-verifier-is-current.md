# Stage card 147: the agent-sdk verifier is current

## Metadata

- **Authored:** 2026-10-09
- **Orchestrator:** Claude Fable 5.1 <claude-fable-5-1@local>
- **Worker:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Verifier:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Base branch:** dev
- **Run branch:** autometta/147-the-agent-sdk-verifier-is-current
- **Worker effort:** high
- **Verifier effort:** medium
- **Verifier panel:** false
- **Gate:** stage-completed: 146-the-agents-panel-says-what-the-agent-is-doing
- **Path claims:** scripts/requirements-sdk.txt, scripts/verify-sdk-agent.py, scripts/spawn-verifier.sh, scripts/sdk-pin-smoke.sh, docs/sdk-verifier.md, docs/experiments/agent-sdk-verifier-probe.md
- **Pairing rationale:** the seats are this way round because of the
  sandbox. Only a claude seat runs unsandboxed, can `pip install` into the
  brew python, and can run a nested `claude` through `op-fetch` on the
  subscription token; a Codex seat would need the network and agent-home
  grants that stopped cards 23 and 98. Terra verifies: the pin, the guard
  and the recorded probe are all checkable offline, and the artefact the
  probe produced validates against the schema without re-running it.

## Surfacing concern

Card 99 shipped `scripts/verify-sdk-agent.py`, the only SDK surface a
subscription token can authenticate, built against
`claude-agent-sdk==0.2.87`. On 2026-10-09 the pin still reads 0.2.87, the
brew `python3` is 3.14 and carries 0.1.81, the 3.12 and 3.13 interpreters
carry nothing, and PyPI is at 0.2.165. Nothing in the dispatch path notices:
`verifier_sdk_precondition` only asks whether the module imports. A repo that
declares `transport: agent-sdk` would run a verifier on an SDK the route was
never tested against, and the first sign would be a burned attempt cap on a
weekend run. The pin exists so that cannot happen; it needs a guard that
reads it.

## Objective

The requirements pin names a current `claude-agent-sdk` release, that
release is installed for the `python3` the spawn scripts resolve, the
entrypoint refuses to dispatch on a mismatch and names both versions, and
one real verification on the subscription route is on record with its
usage, so the operator can decide whether this repo's claude verifier
leaves `cli` without spending a run to find out.

## Inputs (read these in your own context)

- `scripts/sdk-pin-smoke.sh`: the frozen contract; read it first.
- `scripts/requirements-sdk.txt`.
- `scripts/verify-sdk-agent.py`: the entrypoint you are extending.
- `scripts/spawn-verifier.sh`: `verifier_sdk_precondition` and the
  `agent-sdk` dispatch branch (search for `verify-sdk-agent.py`).
- `docs/sdk-verifier.md` sections "The Agent SDK entrypoint" and
  "Fail-closed conditions".
- `docs/experiments/worker-sdk-postmortem.md` for the record format a
  probe document follows here.

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/requirements-sdk.txt`: the `claude-agent-sdk` line pinned to
   the newest release on PyPI at the time of the run (0.2.165 on
   2026-10-09; check `python3 -m pip index versions claude-agent-sdk`).
   The other three lines are untouched; report their drift against what is
   installed in the envelope instead.
2. That release installed for `/opt/homebrew/bin/python3` with
   `python3 -m pip install "claude-agent-sdk==<pin>"`, using
   `--break-system-packages` if the brew python requires it. Install only
   that package; the `-r` form would also move the other three pins.
3. `scripts/verify-sdk-agent.py`: a `--check-sdk` option that reads the
   pin from `scripts/requirements-sdk.txt` (or the file named by
   `AUTOMETTA_SDK_REQUIREMENTS`), compares it with
   `importlib.metadata.version("claude-agent-sdk")`, exits 0 on a match
   and exits 2 on a mismatch with one stderr line naming both versions.
   The same check runs at the top of a real dispatch before any prompt is
   assembled, with the same exit code, so a mismatch costs no tokens.
4. `scripts/spawn-verifier.sh`: `verifier_sdk_precondition` for the
   `agent-sdk` surface also runs `--check-sdk` and reports the mismatch as
   the reason; because an explicit `transport: agent-sdk` never falls back
   silently, that resolution exits non-zero before spawning and the
   `--print-transport` probe shows the reason.
5. `docs/experiments/agent-sdk-verifier-probe.md`: one real run of the
   entrypoint on the subscription route against a landed card, recorded in
   the postmortem shape (what was run, what was observed, decision). It
   names the pinned release it ran on as `claude-agent-sdk==<pin>`, quotes
   the exact invocation with the artefact glob and effort, the exit code,
   the usage figures the entrypoint logged, and the validated artefact
   JSON inline. It ends with a plain recommendation on whether this repo's
   `verifier.claude.transport` should move from `cli` to `agent-sdk`, and
   why; the manifest itself is gitignored and is the operator's to change.
6. `docs/sdk-verifier.md`: a short "Keeping the SDK current" subsection
   stating the pin-and-guard rule, the install command, the exit code, and
   that a mismatch on an explicit `agent-sdk` transport refuses rather than
   reroutes; plus the fail-closed table gains that row.

## Constraints

- The frozen block in `scripts/sdk-pin-smoke.sh` is read-only to you.
- The probe runs against a card that has already landed, for example
  `stage-cards/144-the-operator-can-inspect-the-dependency-graph.md` with
  `--artefact-glob 'scripts/dependency-graph*.sh'`, writes its artefact
  under `state/verifiers/147-probe-144.json`, and is dispatched through
  `op-fetch CLAUDE_CODE_OAUTH_TOKEN="$OP_REF_CLAUDE_CODE_OAUTH_TOKEN"` after
  sourcing `op-refs.sh`, exactly as `docs/sdk-verifier.md` shows. Never
  pass `ANTHROPIC_API_KEY`; the point is the subscription route.
- One probe. A first-request 429 is the auth route, not load: stop, record
  it, and recommend `cli` stays.
- `verify-sdk.py` and `verify-sdk-openai.py` are not claimed and are
  untouched.
- No manifest, LaunchAgent, Homebrew or state change.
- British English in prose, no em dashes, no AI-tell vocabulary.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. `bash scripts/sdk-pin-smoke.sh` passes on the run branch, run by the
   verifier, and `scripts/check-contract-test-gate.sh print
   scripts/sdk-pin-smoke.sh` prints the digest recorded below.
2. `python3 -c 'import importlib.metadata as m; print(m.version("claude-agent-sdk"))'`
   prints the pinned version, and `python3 -m pip index versions
   claude-agent-sdk` shows that version as the newest, or the envelope
   explains the gap.
3. `AUTOMETTA_CLAUDE_TRANSPORT=agent-sdk scripts/spawn-verifier.sh
   --print-transport claude` on the run branch resolves to `agent-sdk`
   with the current pin, and with `AUTOMETTA_SDK_REQUIREMENTS` pointing at
   a file pinning `0.0.1` it reports the mismatch as the reason and does
   not resolve to `agent-sdk`.
4. The artefact JSON quoted in the probe record, extracted to a temporary
   file, passes `scripts/validate-verifier-artefacts.sh <file>`, and its
   `verifier_identity` is `Claude Agent SDK verifier <claude-agent-sdk@local>`.
5. The probe record states the exit code, the usage figures and a plain
   recommendation; a record without a recommendation fails.
6. `python3 -m py_compile scripts/verify-sdk-agent.py`, `bash -n
   scripts/spawn-verifier.sh`, and `scripts/verifier-route-matrix-smoke.sh`,
   `scripts/verify-sdk-schema-path-smoke.sh` and
   `scripts/advisor-order-smoke.sh` still pass; record any failure that
   already exists on the base commit separately.
7. `git diff --stat` on the run branch touches only the claimed paths.

## Contract test

- **Test file:** scripts/sdk-pin-smoke.sh
- **Assertions digest:** `sha256:374796c7687f2eaf121bc6050d33ee39516b9d661156437070a0555a4aa8cab8`

The orchestrator authored the frozen block on 2026-10-09. It fails today at
its first assertion because the pin is 0.2.87; the guard, mismatch and
probe-record assertions after it are reachable and were exercised with the
assertions softened. The block deliberately reads this machine's installed
version: that the machine matches the pin is the deliverable.

## Out of scope

- Changing any transport default or this repo's manifest.
- The api-sdk entrypoint, the Codex SDK entrypoint and their pins.
- The Fable-as-advisor option, which is api-only.
- Mirroring the pin into `mcp-hub`'s dependency registry.

## Budget

- **Worker wall-clock:** 30 minutes
- **Verifier wall-clock:** 20 minutes
- **Spend basis:** see the 145-147 batch in `stage-cards/PLAN.md`. Planning
  allowance 15M tokens for the batch, subject to live admission; no cap
  change or drain is authorised by this card. The probe itself is one
  verification-sized dispatch inside the worker's budget.

## Dispatch envelope

Write `state/envelopes/147-the-agent-sdk-verifier-is-current.json` using
`schemas/envelope.json`. List changed deliverables, the exact install and
probe commands with their exit codes, the other three pins' drift, and any
criterion you could not satisfy with why. Do not self-verify or land your
own branch. The verifier writes
`state/verifiers/147-the-agent-sdk-verifier-is-current.json` under the
existing verifier contract. After independent PASS the orchestrator lands
this stage; it is the last card of the batch.

## Family-specific notes

The worker is `claude -p` running unsandboxed with the subscription token in
its environment. The nested probe goes through `op-fetch`, which execs the
child under `env -i`, so no variable from the worker's own session reaches
the SDK's `claude` subprocess; a nested print-mode dispatch was measured to
work on 2026-10-09. If `pip` refuses the system site-packages, use
`--break-system-packages` and say so. The verifier is a Codex seat under
`workspace-write`: it does not run the probe or `pip`, it checks the pin,
the guard, the route probe and the recorded artefact, all offline.
