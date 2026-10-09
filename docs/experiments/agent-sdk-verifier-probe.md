# Agent SDK verifier probe

## Hypothesis

`scripts/verify-sdk-agent.py`, the only SDK surface a subscription token can
authenticate, might be ready to replace `claude -p` as this repo's claude
verifier transport: one real verification on the subscription route should
show whether it authenticates, what it costs, and whether its verdict is one
the loop could land on.

## What was run

Run on 2026-10-09 from the stage 147 run worktree, on
`claude-agent-sdk==0.2.165` installed for `/opt/homebrew/bin/python3`
(Python 3.14.7). That release bundles Claude Code 2.1.294 as the CLI the SDK
spawns. The install:

```sh
python3 -m pip install "claude-agent-sdk==0.2.165"
# refused by PEP 668 (externally managed environment), exit 1
python3 -m pip install --break-system-packages "claude-agent-sdk==0.2.165"
# exit 0; replaced 0.1.81, no other package moved
```

The probe verified card 144, which had already landed, on the subscription
route only. No `ANTHROPIC_API_KEY` was in the route:

```sh
source op-refs.sh
op-fetch CLAUDE_CODE_OAUTH_TOKEN="$OP_REF_CLAUDE_CODE_OAUTH_TOKEN" -- \
  python3 scripts/verify-sdk-agent.py \
    --stage-id 144-the-operator-can-inspect-the-dependency-graph \
    --card stage-cards/144-the-operator-can-inspect-the-dependency-graph.md \
    --artefact-glob 'scripts/dependency-graph*.sh' \
    --out state/verifiers/147-probe-144.json \
    --effort medium
```

The model was the entrypoint's default, `claude-sonnet-5-5`.

## What was observed

The first attempt exited `2` after 4 seconds and never sent a request:

```text
Error: --json-schema is not a valid JSON Schema: no schema with key or ref "https://json-schema.org/draft/2020-12/schema"
verify-sdk-agent: agent sdk transport failure: Command failed with exit code 1 (exit code: 1)
```

The CLI bundled with 0.2.165 validates `--json-schema` against a metaschema
set that does not include draft 2020-12, so it refuses `schemas/verifier.json`
because that file declares `"$schema"`. On this release the entrypoint as
shipped could not dispatch at all. This is the drift the pin guard exists to
surface. The fix, in this card, drops the `$schema` key from the copy handed
to the CLI. The entrypoint still validates the returned envelope against the
full schema. The schema uses no keyword that only 2020-12 defines. The
rejection is local, so the attempt spent no tokens and does not count as the
probe.

The second attempt, the probe proper, with the same invocation:

- **Exit code:** `1`, the documented code for an `overall: "FAIL"` verdict.
- **Wall-clock:** 14 seconds.
- **Usage the entrypoint logged:** `Total tokens: 26050`, which counts
  input, including cache creation and cache reads, plus output for the one
  turn. That one line is all the entrypoint reports.
- **Auth:** no 429 and no login error. The subscription token reached the
  SDK's `claude` subprocess through `op-fetch` and was accepted on the first
  request.
- **Noise:** one stderr line,
  `verify-sdk: could not update live usage registry: ... state/active-agents/<pid>.json`.
  A manual run registers no agent, so this is expected and harmless.
- **Artefact:** written to `state/verifiers/147-probe-144.json`, and it passes
  `scripts/validate-verifier-artefacts.sh`:

```json
{
  "stage_id": "144-the-operator-can-inspect-the-dependency-graph",
  "verifier_identity": "Claude Agent SDK verifier <claude-agent-sdk@local>",
  "verifier_invocation": "scripts/verify-sdk-agent.py --stage-id 144-the-operator-can-inspect-the-dependency-graph --card stage-cards/144-the-operator-can-inspect-the-dependency-graph.md --out state/verifiers/147-probe-144.json (no shell or file tools available in this session; only the supplied prompt text was inspected)",
  "ran_at": "2026-10-09T00:00:00Z",
  "criteria": [
    {
      "id": 1,
      "name": "Opposite-family verifier runs `dependency-graph-smoke.sh all`; all modes pass",
      "verdict": "FAIL",
      "evidence": "Not run. This session had no command-execution tool, so no smoke output exists. The supplied artefacts also do not include bin/autometta. The lifecycle test at scripts/dependency-graph-smoke.sh:406-422 invokes `bin/autometta graph`, so I could not confirm it can pass. Missing evidence counts as FAIL."
    },
    {
      "id": 2,
      "name": "Lifecycle mode on detached dispatch-base checkout via AUTOMETTA_GRAPH_TEST_ROOT, with before/after record",
      "verdict": "FAIL",
      "evidence": "Not run. No shell, no base checkout, and no recorded base-versus-candidate results were available."
    },
    {
      "id": 3,
      "name": "Independent join replay on two scratch branches, restart, unchanged spawn count, global stops win",
      "verdict": "FAIL",
      "evidence": "Not run. The only related evidence is the frozen oracle's Lifecycle.test_restart_does_not_dispatch_twice_and_guards_still_hold (scripts/dependency-graph-smoke.sh:365-384). That is not an independent replay, and I did not execute it."
    },
    {
      "id": 4,
      "name": "landing-dispatch-smoke and landing-rebase-smoke on base and candidate; no new failures",
      "verdict": "FAIL",
      "evidence": "Not run. Neither script's contents nor output were provided or executable."
    },
    {
      "id": 5,
      "name": "Out-of-repo CLI invocation with AUTOMETTA_ROOT; JSON parity with direct inspection; byte/ref immutability; error cases",
      "verdict": "FAIL",
      "evidence": "Not run, and bin/autometta was not available to inspect. scripts/dependency-graph.sh is visible: it exits 1 with an empty stdout for a missing repo, state or base (lines 35-55) and exits 2 for an invalid graph (line 286). The CLI wrapper, its error handling and the parity check could not be verified."
    },
    {
      "id": 6,
      "name": "bash -n on bin/autometta and changed shell files; digest recompute; check-contract-test-gate.sh --worktree",
      "verdict": "FAIL",
      "evidence": "Not run. I could not recompute the digest sha256:f540c355…9098 or run the gate. The markers are present at scripts/dependency-graph-smoke.sh:8 and :433, but that is not a digest check."
    }
  ],
  "additional_findings": "This FAIL reflects missing evidence, not a confirmed defect. I had no shell or file-read tooling, so I executed no commands and read no files beyond the prompt. Contract gate result: not run, so the digest is unverified. Deliverables I could not see: the `graph` subcommand in bin/autometta, docs/dependency-graph.md, README.md, docs/runbook.md and the dispatch envelope. scripts/dependency-graph.sh looks structurally consistent with its documented exit codes (0 valid, 2 invalid, 1 inspection impossible). The stage should be re-verified with a tool-enabled verifier. Separately, the stage id in this artefact path (147-probe-144) differs from the card basename; I used the card's stage id as the schema requires.",
  "overall": "FAIL"
}
```

Card 144 landed after an independent PASS, so this FAIL does not reflect a
defect in that stage. The verifier had no evidence to judge with. The
entrypoint runs the turn with `tools=[]` by design, so it reasons over the
prompt text alone. Every criterion on card 144 asks for a command to be run,
and the verifier correctly refused to mark unrun commands as passing. The
model also wrote `ran_at` as midnight, a placeholder, because it has no clock
tool.

## Decision

This repo's `verifier.claude.transport` should stay `cli`. Do not move it to
`agent-sdk`.

The route itself works. On `claude-agent-sdk==0.2.165` it authenticates on the
subscription token with no 429, costs about 26k tokens and 14 seconds for one
verification, and returns schema-valid structured output under the right
identity. The surface is the problem. A verifier with no shell and no file
reads cannot discharge acceptance criteria that consist of running smokes,
recomputing contract digests and checking diffs, and almost every card in
this repo has criteria like that. Moving the transport would turn every
claude verification into a FAIL on missing evidence, and each one would burn
an attempt against `verifier_attempt_cap`. That is the weekend failure the pin
was meant to prevent, arriving by a different route.

`agent-sdk` becomes worth reconsidering when the entrypoint gains a bounded
tool surface, read-only file access plus the card's own acceptance commands,
and a second probe against a landed card returns PASS. Until then, its use is
the one this record shows: a cheap, offline-validated check that the
subscription route and the pinned SDK still work together. The manifest is
gitignored and remains the operator's to change.
