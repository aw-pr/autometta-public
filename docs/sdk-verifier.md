# SDK verifier prototype

`scripts/verify-sdk.py` is an opt-in prototype for running a verifier through the Claude Agent SDK. It reads a stage card, expands a worker artefact glob, renders `templates/verifier-prompt.md`, asks the SDK for structured JSON, and writes the verifier artefact to the path supplied by `--out`.

It does not replace `scripts/spawn-verifier.sh`, change the phat-controller state machine, read 1Password, choose an auth route, or provide fallback behaviour to `claude -p`. The caller must install `scripts/requirements-sdk.txt` once and inject `ANTHROPIC_API_KEY` through `op-fetch`.

Manual smoke test:

```sh
python3 scripts/verify-sdk.py --help

op-fetch ANTHROPIC_API_KEY="$OP_REF_ANTHROPIC_API_KEY" -- \
  python3 scripts/verify-sdk.py \
    --stage-id 14-auth-route-toggle \
    --card examples/self-host/14-auth-route-toggle.md \
    --artefact-glob 'scripts/auth*.sh' \
    --out state/verifiers/14-auth-route-toggle.json
```

Exit codes:

- `0`: SDK returned `overall: "PASS"` and the JSON artefact was written.
- `1`: SDK returned `overall: "FAIL"` or the returned JSON was malformed.
- `2`: environment error, including missing `ANTHROPIC_API_KEY`, missing `claude-agent-sdk`, missing card, or missing verifier prompt template.

The output envelope intentionally matches the existing verifier artefact shape:

```json
{
  "stage_id": "14-auth-route-toggle",
  "verifier_identity": "Claude Agent SDK verifier <claude-agent-sdk@local>",
  "verifier_invocation": "scripts/verify-sdk.py --stage-id 14-auth-route-toggle --card examples/self-host/14-auth-route-toggle.md --artefact-glob <redacted> --out state/verifiers/14-auth-route-toggle.json",
  "ran_at": "2026-05-27T12:00:00Z",
  "criteria": [
    {
      "id": 1,
      "name": "scripts/auth-route.sh codex in a repo with no .autometta.local.yaml prints unset OPENAI_API_KEY",
      "verdict": "PASS",
      "evidence": "scripts/auth-route.sh:1 shows the resolver exists; command output confirmed unset OPENAI_API_KEY."
    }
  ],
  "additional_findings": "",
  "overall": "PASS"
}
```

Known gaps before 15b:

- The rubric contract is only the existing top-level JSON envelope, not a stronger schema for criterion names or evidence format.
- The prototype feeds the listed artefacts into the prompt rather than giving the SDK broad filesystem write access.
- There is no production dispatch integration, no budget accounting, no heartbeat registration, and no `state.yaml` transition.
- The SDK package version is pinned in `scripts/requirements-sdk.txt`; upgrades need an explicit smoke test.
