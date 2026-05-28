# SDK verifier prototype

`scripts/verify-sdk.py` is an opt-in entrypoint for running a verifier through the Claude Agent SDK. It reads a stage card, expands a worker artefact glob, renders `templates/verifier-prompt.md`, asks the SDK for structured JSON, validates it against `schemas/verifier.json`, and writes the verifier artefact to the path supplied by `--out`.

Direct use of `scripts/verify-sdk.py` does not read 1Password, choose an auth route, register heartbeat state, or provide fallback behaviour to `claude -p`. The caller must install `scripts/requirements-sdk.txt` once and inject `ANTHROPIC_API_KEY` through `op-fetch`. Production dispatch goes through `scripts/spawn-verifier.sh`, which owns auth-route selection, fallback, and registration.

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
- `3`: SDK returned JSON that failed `schemas/verifier.json`; an invalid report is written to `<out>.invalid.json`.

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

## Rubric schema

Verifier artefacts are validated against `schemas/verifier.json`, a JSON Schema 2020-12 contract for the top-level verifier envelope and each criterion verdict. The SDK route loads that schema for structured output and validates the returned JSON before writing the final artefact.

Use the offline corpus validator before changing the schema or verifier output shape:

```sh
scripts/validate-verifier-artefacts.sh
scripts/validate-verifier-artefacts.sh /tmp/bad.json
```

The validator prints `PASS <path>` or `FAIL <path>: <jsonschema error>` for each artefact and exits non-zero if any file fails.

Known gaps after 15b:

- The prototype feeds the listed artefacts into the prompt rather than giving the SDK broad filesystem write access.
- There is no production dispatch integration, no budget accounting, no heartbeat registration, and no `state.yaml` transition.
- The SDK package version is pinned in `scripts/requirements-sdk.txt`; upgrades need an explicit smoke test.

## Integration into spawn-verifier.sh

`scripts/spawn-verifier.sh` selects between the SDK route and the existing `claude -p` route at dispatch time. The selection is controlled by a manifest flag and an env override; the default is `cli` (zero behavioural change for repos that do not opt in).

### Transport resolution

Resolution order (most specific wins):

1. `AUTOMETTA_CLAUDE_TRANSPORT` env var (`sdk` or `cli`)
2. `verifier.claude.transport` in the repo's `.autometta.local.yaml`
3. Default: `cli`

A single log line is emitted to stderr before dispatch:

```
verifier-transport: sdk (provenance: manifest)
verifier-transport: cli (provenance: default)
verifier-transport: cli (provenance: env)
```

### Opting in

In the repo's `.autometta.local.yaml`:

```yaml
auth:
  claude:
    mode: api          # required; SDK route needs ANTHROPIC_API_KEY
verifier:
  claude:
    transport: sdk
```

See `.autometta.local.yaml.example` for the full template and comments.

### Fail-closed conditions

| Condition | Outcome |
|---|---|
| `transport: sdk` + `auth.claude.mode: subscription` | Exits non-zero before spawning any process. Message names both flags. |
| `transport` value other than `cli` or `sdk` | Exits non-zero before spawning any process. |
| `transport: sdk` + `scripts/verify-sdk.py` missing | Logs a warning and falls back to `cli`. |
| `transport: sdk` + SDK package missing | `verify-sdk.py` exits `2`; logged to the stage log. |

### Artefact glob derivation

The spawner parses the `## Deliverables` section of the stage card, extracts backtick-quoted paths, and derives a glob from their parent directories. If all deliverables share one parent directory (e.g., `scripts/`), the glob is `scripts/**`. When deliverables span multiple directories, the spawner falls back to `**` (broad recursive). This is a v1 heuristic; operators can override by invoking `verify-sdk.py` directly with a targeted glob.

### Registration and heartbeat

The SDK route registers the spawned process via `scripts/register-agent.sh` with the same `family`, `role`, and `identity` fields as the CLI route. The heartbeat and ticker work unchanged. Exit code semantics are preserved: `verify-sdk.py` emits `0` (PASS), `1` (FAIL or malformed JSON), `2` (env/config error); `tick.sh` sees these as it does for the CLI route.

### Env injection contract

The SDK route goes through `op-fetch` with the same `ANTHROPIC_API_KEY=$OP_REF_ANTHROPIC_API_KEY` pair as other api-mode dispatches. The sanitised env strips any inherited key from the parent shell; only the 1Password-resolved value is injected. Subscription mode cannot reach the SDK route; it fails closed before `op-fetch` is invoked.

## Prompt caching

`verify-sdk.py` marks the static portion of its input as cacheable using Anthropic's prompt caching (`cache_control: {type: "ephemeral"}`). The 5-minute TTL means consecutive verifier calls within an active tick window recover the cache, reducing billable input tokens on repeated runs.

### What is cached

The **static block** contains content that is identical across all stages dispatched in the same session:

- The verifier rubric prose from `templates/verifier-prompt.md` (with constant placeholders filled; stage-specific placeholders left as descriptive labels).
- The artefact JSON schema from `schemas/verifier.json`.
- Dispatch contract reminders (evaluate dirty tree only, evidence requirements, output format).

Combined, the static block is well above the ~1024-token Sonnet minimum for cache eligibility.

### What is not cached

The **variable block** contains per-stage content that changes every run:

- Stage id, card path, and artefact path.
- The full stage card content with line numbers.
- The worker artefacts with line numbers.

### Reading the log line

After each API call, `verify-sdk.py` prints to stderr:

```
cache: write=<N> read=<M> input=<I> output=<O>
```

| Field | Anthropic usage key | Meaning |
|---|---|---|
| `write` | `cache_creation_input_tokens` | Tokens written to the prompt cache (first call in window) |
| `read` | `cache_read_input_tokens` | Tokens served from the prompt cache (subsequent calls in window) |
| `input` | `input_tokens` | Total input tokens charged |
| `output` | `output_tokens` | Output tokens generated |

On the **first call** in a session, `write > 0` and `read = 0`. On subsequent calls within the 5-minute TTL, `read > 0` and `write = 0`. After the TTL expires or the static block changes, `write > 0` again.

### When the cache misses

| Cause | Effect |
|---|---|
| Template changes (`templates/verifier-prompt.md`) | Static block changes; full `write` charged |
| Schema changes (`schemas/verifier.json`) | Static block changes; full `write` charged |
| Model change | Cache is model-scoped; full `write` charged |
| More than 5 minutes between calls | TTL expired; full `write` charged |
| First call in a session | Always a `write` |

### Running the smoke test

```sh
source op-refs.sh
op-fetch ANTHROPIC_API_KEY="$OP_REF_ANTHROPIC_API_KEY" -- \
  scripts/sdk-cache-smoke.sh
```

The smoke test runs `verify-sdk.py` twice against stage 14, parses the `cache:` log lines, and asserts that the second run has `read > 0`. Exits 0 on cache hit, 1 on miss, 2 on environment error.
