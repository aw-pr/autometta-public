# SDK verifier prototype

`scripts/verify-sdk.py` is an opt-in entrypoint for running a verifier through the Claude Agent SDK. It reads a stage card, expands a worker artefact glob, renders `templates/verifier-prompt.md`, asks the SDK for structured JSON, validates it against `schemas/verifier.json`, and writes the verifier artefact to the path supplied by `--out`.

Direct use of `scripts/verify-sdk.py` does not read 1Password, choose an auth route, register heartbeat state, or provide fallback behaviour to `claude -p`. The caller must install `scripts/requirements-sdk.txt` once and inject one credential through `op-fetch`: `ANTHROPIC_API_KEY` on the api route, or `CLAUDE_CODE_OAUTH_TOKEN` on the subscription route. Production dispatch goes through `scripts/spawn-verifier.sh`, which owns auth-route selection, fallback, and registration.

Manual smoke test:

```sh
python3 scripts/verify-sdk.py --help

op-fetch ANTHROPIC_API_KEY="$OP_REF_ANTHROPIC_API_KEY" -- \
  python3 scripts/verify-sdk.py \
    --stage-id 14-auth-route-toggle \
    --card stage-cards/14-auth-route-toggle.md \
    --artefact-glob 'scripts/auth*.sh' \
    --out state/verifiers/14-auth-route-toggle.json \
    --effort high
```

`--effort` is optional. The pinned `anthropic==0.100.0` client exposes the same `low`, `medium`, `high`, `xhigh`, and `max` vocabulary through `output_config.effort`. `spawn-verifier.sh` passes a declared card `Verifier effort` to this option. With no declaration, it omits `output_config` and preserves the SDK default.

Exit codes:

- `0`: SDK returned `overall: "PASS"` and the JSON artefact was written.
- `1`: SDK returned `overall: "FAIL"` or the returned JSON was malformed.
- `2`: environment error, including neither `ANTHROPIC_API_KEY` nor `CLAUDE_CODE_OAUTH_TOKEN` being set, missing `claude-agent-sdk`, missing card, or missing verifier prompt template.
- `3`: SDK returned JSON that failed `schemas/verifier.json`; an invalid report is written to `<out>.invalid.json`.

The output envelope intentionally matches the existing verifier artefact shape:

```json
{
  "stage_id": "14-auth-route-toggle",
  "verifier_identity": "Claude Agent SDK verifier <claude-agent-sdk@local>",
  "verifier_invocation": "scripts/verify-sdk.py --stage-id 14-auth-route-toggle --card stage-cards/14-auth-route-toggle.md --artefact-glob <redacted> --out state/verifiers/14-auth-route-toggle.json",
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
    mode: subscription # or api; both routes reach the SDK
verifier:
  claude:
    transport: sdk
```

See `.autometta.local.yaml.example` for the full template and comments.

### Fable-as-advisor (optional)

A verifier on the SDK route can consult a stronger advisor model only at the
decision point instead of running a frontier model across the whole prompt. The
cheap request model (`--model`, e.g. `claude-sonnet-4-6`) reads the
cache-controlled static block and the artefacts and drafts the verdicts; the
advisor (`--advisor`, e.g. `claude-fable-5`) finalises the JSON envelope. The
advisor consults over the same cached prefix, so its input is cached. Design:
[`docs/design/advisor-verifier.md`](design/advisor-verifier.md).

Resolution order (most specific wins): `AUTOMETTA_CLAUDE_ADVISOR` env var, then
`verifier.claude.advisor` in `.autometta.local.yaml`, then off. The advisor sits
under the `sdk` branch only and carries its own `auth.claude.mode: api` gate:
the advisor tool is an API feature, so an advisor requested on the subscription
route fails closed rather than being dropped.

```yaml
verifier:
  claude:
    transport: sdk
    advisor: claude-fable-5
```

**Ordering precondition (#66714):** the advisor must not be weaker than the
request model. A request on `claude-fable-5` with an advisor on
`claude-opus-4-8` returns HTTP 400. `verify-sdk.py` enforces the capability
ordering (`fable > opus > sonnet > haiku`) locally and exits `2` before any API
call on an inverted pair. Offline check: `scripts/advisor-order-smoke.sh`.

**Data retention:** the advisor receives the stage card and artefacts, which
carry the org-wide 30-day retention commitment. Do not point it at a repo whose
artefacts contain personal data.

### Fail-closed conditions

| Condition | Outcome |
|---|---|
| `transport: sdk` + `auth.claude.mode: subscription` + resolvable `OP_REF_CLAUDE_CODE_OAUTH_TOKEN` | Dispatches, with `CLAUDE_CODE_OAUTH_TOKEN` as the only credential in the child env. |
| `transport: sdk` + `auth.claude.mode: subscription` + `OP_REF_CLAUDE_CODE_OAUTH_TOKEN` unset or still a `YOUR_VAULT` placeholder | Exits non-zero before spawning any process. Message names the ref and `claude setup-token`. |
| `transport: sdk` + `auth.claude.mode: api` + `OP_REF_ANTHROPIC_API_KEY` unresolved | Exits non-zero before spawning any process. Message names the ref. |
| `transport: sdk` + `auth.claude.mode: local` | Refused by `auth-route.sh`: the local route is codex-family only. |
| `transport` value other than `cli` or `sdk` | Exits non-zero before spawning any process. |
| `transport: sdk` + `scripts/verify-sdk.py` missing | Logs a warning and falls back to `cli`. |
| `transport: sdk` + SDK package missing | `verify-sdk.py` exits `2`; logged to the stage log. |
| `transport: sdk` + declared `Verifier effort` | Passes the level through `output_config.effort`; it is not discarded. |
| `advisor` weaker than `--model` (inverted #66714 pair) | `verify-sdk.py` exits `2` before any API call, naming both models. |
| `advisor` set + `auth.claude.mode` other than `api` | Exits non-zero before spawning any process. The advisor is an API-only feature. |

### Artefact glob derivation

The spawner parses the `## Deliverables` section of the stage card, extracts backtick-quoted paths, and derives a glob from their parent directories. If all deliverables share one parent directory (e.g., `scripts/`), the glob is `scripts/**`. When deliverables span multiple directories, the spawner falls back to `**` (broad recursive). This is a v1 heuristic; operators can override by invoking `verify-sdk.py` directly with a targeted glob.

### Registration and heartbeat

The SDK route registers the spawned process via `scripts/register-agent.sh` with the same `family`, `role`, and `identity` fields as the CLI route. The heartbeat and ticker work unchanged. Exit code semantics are preserved: `verify-sdk.py` emits `0` (PASS), `1` (FAIL or malformed JSON), `2` (env/config error); `tick.sh` sees these as it does for the CLI route.

### Env injection contract

The SDK route goes through `op-fetch` with whichever single pair `scripts/auth-route.sh claude --role verifier` emits: `ANTHROPIC_API_KEY=$OP_REF_ANTHROPIC_API_KEY` in api mode, `CLAUDE_CODE_OAUTH_TOKEN=$OP_REF_CLAUDE_CODE_OAUTH_TOKEN` in subscription mode. Each route names only its own ref, so the credential the other route would use is structurally absent from the child env rather than merely unused. The sanitised env also strips any inherited key from the parent shell; only the 1Password-resolved value is injected.

One line on stderr records which route was taken, naming the mode and the credential's variable name (never the reference or the secret):

```
verifier-transport: sdk auth-route=subscription credential=CLAUDE_CODE_OAUTH_TOKEN
verifier-transport: sdk auth-route=api credential=ANTHROPIC_API_KEY
```

### Subscription auth

The Agent SDK runs the Claude Code harness, which authenticates with an OAuth token rather than an API key. The operator mints that token once, by hand:

```sh
claude setup-token
```

Store the result in 1Password and point `OP_REF_CLAUDE_CODE_OAUTH_TOKEN` at it in `~/.config/autometta/op-refs.local.sh`. `op-refs.sh` has reserved that variable since the CLI route needed it; the SDK route reuses the same item. Nothing in the repo mints, reads, or logs the token: `auth-route.sh` emits the `op://` reference, `op-fetch` resolves it at exec time, and it exists only in the child env.

`verify-sdk.py` sends the token as a bearer credential with the `anthropic-beta: oauth-2025-04-20` header the Claude Code entitlement requires. When the ref is unset or still a `YOUR_VAULT` placeholder, `spawn-verifier.sh` exits before spawning anything; it never falls back to `ANTHROPIC_API_KEY` or to the `cli` transport, because a silent fallback is how billing goes wrong invisibly.

The api-only requirement this replaced was a leftover from before Anthropic supported subscription auth in the Agent SDK, not a limit of the SDK. No doc in this repo should steer the SDK route back to API keys on those grounds. The one thing that genuinely stays api-only is the Fable-as-advisor option, whose advisor tool is an API feature; requesting an advisor on the subscription route fails closed.

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

## Codex SDK verifier route

`scripts/verify-sdk-openai.py` is the equivalent verifier entrypoint for the
Codex family. It uses the official `openai-codex` Python package, which drives
the local Codex app-server and reuses the selected `CODEX_HOME` authentication.
It does not use the key-only `openai` or `openai-agents` libraries.

The entrypoint reuses the same prompt rubric, artefact schema, envelope shape,
and offline validator as `verify-sdk.py`. It creates a read-only Codex thread,
asks for exactly one JSON envelope, validates it against `schemas/verifier.json`,
and writes the requested artefact. After the turn it writes these lines to
stderr from the returned `ThreadTokenUsage`:

```
usage: input=<N> cached=<N> output=<N> total=<N>
tokens used
<N>
```

The second marker is deliberately compatible with the existing Codex token-log
parser. Usage is a turn value, not a signal to add session totals from repeated
runs.

Manual smoke test, after choosing and checking the intended auth route:

```sh
python3 scripts/verify-sdk-openai.py --help

CODEX_HOME="$HOME/.codex" op-fetch --pass CODEX_HOME -- \
  python3 scripts/verify-sdk-openai.py \
    --stage-id 14-auth-route-toggle \
    --card stage-cards/14-auth-route-toggle.md \
    --artefact-glob 'scripts/auth*.sh' \
    --out state/verifiers/14-auth-route-toggle.json
```

### Per-role, per-family transport matrix

Verifier transport resolution is independent for each family:

| Role | Family | Manifest key | SDK entrypoint | Auth modes |
|---|---|---|---|---|
| verifier | claude | `verifier.claude.transport` | `scripts/verify-sdk.py` | api, subscription |
| verifier | codex | `verifier.codex.transport` | `scripts/verify-sdk-openai.py` | api, subscription |
| orchestrator | claude | `orchestrator.claude.transport` | design only | design-pending card 23 |
| orchestrator | codex | `orchestrator.codex.transport` | design only | design-pending card 23 |

The verifier defaults to `cli`. `AUTOMETTA_CLAUDE_TRANSPORT` and
`AUTOMETTA_CODEX_TRANSPORT` override their matching manifest key for an A/B
run without editing the manifest.

For a Codex SDK verifier, `spawn-verifier.sh` selects and checks `CODEX_HOME`
before the process starts:

| Resolved `auth.codex.mode` | Selected home | Required `auth.json` mode |
|---|---|---|
| subscription | `${AUTOMETTA_CODEX_SUBSCRIPTION_HOME:-~/.codex}` | `chatgpt` |
| api | `${AUTOMETTA_CODEX_HOME:-~/.codex-api-only}` | `apikey` |

Any mismatch fails closed and names both the requested billing mode and the
found `auth_mode`. This prevents an API key route accidentally spending the
plan, or a subscription route accidentally using the API-only sibling.
