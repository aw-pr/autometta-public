# API SDK and Agent SDK verifiers

## The two SDKs, and why the distinction is load-bearing

"SDK" names two different Anthropic products, and for one day that ambiguity
was a fleet-wide outage. This page is about the first of them.

| Surface | Package | What it is | `ANTHROPIC_API_KEY` | `CLAUDE_CODE_OAUTH_TOKEN` |
|---|---|---|---|---|
| `cli` | the `claude` binary | Claude Code itself | yes | yes |
| `api-sdk` | `anthropic` | the raw Messages API | yes | **no** |
| `agent-sdk` | `claude-agent-sdk` | Claude Code as a library | yes | yes |

`scripts/verify-sdk.py` is the **api-sdk** surface: it imports `anthropic` and
calls the Messages API. It is not `claude-agent-sdk`, whatever the file name
suggests. A Claude Code subscription token is not a credential for that
surface -- measured 2026-09-01, same model and minute, one request each, a
`max_tokens=4` call returned `429 rate_limit_error` on the OAuth token and
`200` on the API key, while `claude -p` on that same OAuth token answered.
The 429 carried `x-should-retry` with no `retry-after` and no
`anthropic-ratelimit-*` headers, so it was never a spent quota.

Both surfaces are valid. Crossing one with the other's credential is not, and
`claude_route_refusal` in `scripts/models.sh` is the single place that rule
lives. `resolve_verifier_transport` applies it to every provenance -- env
override, manifest, and default alike -- so an explicit `transport: sdk` is a
statement of preference, not a licence to mix. A refused pairing resolves to
`cli (route-guard: <reason>)`, which `--print-transport` shows, so a dispatch
never changes route in silence. `scripts/verifier-route-matrix-smoke.sh`
covers the matrix.

`agent-sdk` now has a verifier entrypoint: `scripts/verify-sdk-agent.py`
imports `claude_agent_sdk`, the Claude Code harness as a library, and
authenticates the way the `claude` binary does -- on either credential, per
the table above. This is what "the SDK verifier runs on the subscription" was
always meant to mean; card 89 shipped an entrypoint under that description
that actually took `ANTHROPIC_API_KEY`.

**Choosing a surface:** `agent-sdk` is the one to reach for on a subscription
route -- it is the only SDK surface an OAuth token can authenticate. On an API
key route either SDK surface works; `api-sdk` (`scripts/verify-sdk.py`) is the
more mature of the two (prompt caching, the Fable-as-advisor option), so stay
on it there unless a manifest has a specific reason to prefer `agent-sdk`'s
native structured-output contract (below) instead of prompt-parsed JSON.

**No default changed.** Declaring `agent-sdk` no longer refuses the dispatch,
but nothing resolves to it on its own: the transport-resolution default (see
below) still only ever offers `sdk` (api-sdk). A repo reaches `agent-sdk` only
by naming it explicitly, in `verifier.claude.transport` or
`AUTOMETTA_CLAUDE_TRANSPORT`.

## The entrypoint

`scripts/verify-sdk.py` is the route a claude verifier takes by default when its credential is an API key. It reads a stage card, expands a worker artefact glob, renders `templates/verifier-prompt.md`, asks the SDK for structured JSON, validates it against `schemas/verifier.json`, and writes the verifier artefact to the path supplied by `--out`.

Direct use of `scripts/verify-sdk.py` does not read 1Password, choose an auth route, register heartbeat state, or provide fallback behaviour to `claude -p`. The caller must install `scripts/requirements-sdk.txt` once and inject `ANTHROPIC_API_KEY` through `op-fetch`. It also accepts `CLAUDE_CODE_OAUTH_TOKEN` and will attempt the call with it, which is how the mismatch above went unnoticed; production dispatch no longer routes that pairing here. Production dispatch goes through `scripts/spawn-verifier.sh`, which owns auth-route selection, fallback, and registration.

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
- `2`: environment error, including neither `ANTHROPIC_API_KEY` nor `CLAUDE_CODE_OAUTH_TOKEN` being set, missing `anthropic` or `jsonschema`, missing card, or missing verifier prompt template.
- `3`: SDK returned JSON that failed `schemas/verifier.json`; an invalid report is written to `<out>.invalid.json`.

The output envelope intentionally matches the existing verifier artefact shape. The identity shown is the no-tier fallback (`VERIFIER_IDENTITY` in the script); a dispatch that passes `--model` writes the per-tier form instead, for example `Claude Opus 5 (SDK) <claude-opus-5@local>`:

```json
{
  "stage_id": "14-auth-route-toggle",
  "verifier_identity": "Claude API SDK verifier <claude-api-sdk@local>",
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

## The Agent SDK entrypoint

`scripts/verify-sdk-agent.py` is the **agent-sdk** surface: it imports
`claude_agent_sdk` and drives one stateless turn through `claude_agent_sdk.query()`.
It reuses `scripts/verify-sdk.py`'s rubric, artefact glob collection, static
and variable prompt blocks, schema loading, and envelope validation by loading
that module directly (`importlib`) rather than re-implementing them; the only
function it never calls is `verify-sdk.py`'s `load_anthropic()`, so this file
never imports `anthropic`.

Unlike the api-sdk route, it does not parse JSON out of a prose response.
`ClaudeAgentOptions.output_format` is set to `{"type": "json_schema", "schema":
<schemas/verifier.json>}`, which the `claude` CLI turns into its own
`--json-schema` flag and returns as `ResultMessage.structured_output` --
schema-conformant structured output from the harness itself, not a markdown
code fence this script has to strip. The turn runs with `tools=[]` (`--tools
""`): no filesystem, network or Bash access, so the verifier reasons over the
artefacts embedded in the prompt exactly as the api-sdk route does, rather
than being handed the browsing access card 98's worker prototype grants a
worker (out of scope here).

Authentication is whatever `op-fetch` placed in the process env: the `claude`
CLI subprocess the SDK spawns inherits it the same way it inherits any other
environment variable, so `CLAUDE_CODE_OAUTH_TOKEN` reaches it exactly as it
would reach `claude -p`. There is no `resolve_auth()` step to duplicate here,
unlike `verify-sdk.py` -- the credential choice already happened in
`spawn-verifier.sh`/`op-fetch`, and both credentials are valid for this
surface.

Manual smoke test:

```sh
python3 scripts/verify-sdk-agent.py --help

source op-refs.sh
op-fetch CLAUDE_CODE_OAUTH_TOKEN="$OP_REF_CLAUDE_CODE_OAUTH_TOKEN" -- \
  python3 scripts/verify-sdk-agent.py \
    --stage-id 14-auth-route-toggle \
    --card stage-cards/14-auth-route-toggle.md \
    --artefact-glob 'scripts/auth*.sh' \
    --out state/verifiers/14-auth-route-toggle.json \
    --effort high
```

The same invocation with `ANTHROPIC_API_KEY="$OP_REF_ANTHROPIC_API_KEY"` in
place of the OAuth pair runs the api mode; both are valid credentials for this
surface. `--effort` takes the same `low`, `medium`, `high`, `xhigh`, `max`
vocabulary as the other SDK routes, passed straight through to
`ClaudeAgentOptions.effort` (the CLI's own `--effort` flag).

Exit codes, identical to `verify-sdk.py`:

- `0`: the turn returned `overall: "PASS"` and the JSON artefact was written.
- `1`: the turn returned `overall: "FAIL"`, the JSON was malformed, or the
  turn itself came back as an SDK-level error (`ResultMessage.is_error`).
- `2`: environment error -- missing `claude-agent-sdk` or `jsonschema`,
  missing card, missing verifier prompt template or schema, or a
  `ClaudeSDKError` from the underlying transport (CLI not found, connection
  failure, malformed stream).
- `3`: the turn returned JSON that failed `schemas/verifier.json`; an invalid
  report is written to `<out>.invalid.json`.

The verifier identity this route writes into every artefact is fixed --
`Claude Agent SDK verifier <claude-agent-sdk@local>` -- rather than varying by
`--model` the way `verify-sdk.py`'s tiered identities do. Reusing that
per-tier scheme here would tag an agent-sdk artefact with the same generic
`(SDK)` suffix an api-sdk artefact carries, recreating on the git-attribution
side the exact ambiguity this card exists to remove from the credential side.

## Rubric schema

Verifier artefacts are validated against `schemas/verifier.json`, a JSON Schema 2020-12 contract for the top-level verifier envelope and each criterion verdict. The SDK route loads that schema for structured output and validates the returned JSON before writing the final artefact.

Use the offline corpus validator before changing the schema or verifier output shape:

```sh
scripts/validate-verifier-artefacts.sh
scripts/validate-verifier-artefacts.sh /tmp/bad.json
```

The validator prints `PASS <path>` or `FAIL <path>: <jsonschema error>` for each artefact and exits non-zero if any file fails.

The SDK package version is pinned in `scripts/requirements-sdk.txt`; upgrades need an explicit smoke test.

## Integration into spawn-verifier.sh

`scripts/spawn-verifier.sh` selects between the SDK route and the existing CLI route at dispatch time. The SDK is the transport of first resort where its credential fits: an unset `verifier.<family>.transport` means "whichever route works here" rather than "the old one". A repo lands on the CLI when an SDK precondition is absent, or when the route guard refuses the pairing (for claude, `auth.claude.mode: subscription` resolves to `cli (route-guard: ...)` unless `agent-sdk` is named, because the api-sdk cannot take an OAuth token), and the log says which.

### Transport resolution

Resolution order (most specific wins), per family:

1. `AUTOMETTA_CLAUDE_TRANSPORT` / `AUTOMETTA_CODEX_TRANSPORT` env var (`sdk` or `cli`), provenance `env`
2. `verifier.<family>.transport` in the repo's `.autometta.local.yaml`, provenance `manifest`
3. Unset, with the family's SDK preconditions all present: `sdk`, provenance `default-sdk`, then through `claude_route_guard`, so a claude repo on subscription still lands on `cli (route-guard: ...)`
4. Unset, with a precondition missing: `cli`, provenance `fallback-cli`, naming the reason

The preconditions are checked only for an unset key. An explicit `sdk` never falls back on them: an operator who asked for the SDK by name wants to hear that it cannot run, not to be rerouted quietly.

| Family | Preconditions for `default-sdk` |
|---|---|
| claude | `scripts/verify-sdk.py` present; `anthropic` and `jsonschema` importable by `python3`; `auth.claude.mode` is `api` and `OP_REF_ANTHROPIC_API_KEY` resolves. On `subscription` the preconditions may hold, but the route guard then downgrades the api-sdk to `cli`; only an explicit `transport: agent-sdk` takes the subscription token |
| codex | `scripts/verify-sdk-openai.py` present; `openai-codex` and `jsonschema` importable by `python3`; `jq` present; `auth.codex.mode` is `api` or `subscription`; the matching `CODEX_HOME/auth.json` carries the matching `auth_mode` |

`auth.codex.mode: local` has no SDK entrypoint, so a local route resolves to `cli (fallback-cli)` and keeps running. Nothing in this list turns a missing precondition into an error.

A single log line is emitted to stderr before dispatch, whichever family and transport is chosen:

```
verifier-transport: sdk (default-sdk)
verifier-transport: sdk (manifest)
verifier-transport: cli (env)
verifier-transport: cli (fallback-cli: python packages anthropic and jsonschema not importable)
verifier-transport: cli (fallback-cli: auth.codex.mode=local has no SDK route)
```

### The resolution probe

`spawn-verifier.sh --print-transport <claude|codex> [repo-root]` prints the transport that family would take in that repo right now, in the same format, without dispatching anything or spending a token:

```sh
scripts/spawn-verifier.sh --print-transport claude
scripts/spawn-verifier.sh --print-transport codex /path/to/subscribed/repo
```

### Pinning the CLI

Nothing needs setting to reach the SDK. To hold a family on the CLI, name it in the repo's `.autometta.local.yaml`:

```yaml
auth:
  claude:
    mode: subscription # api reaches the api-sdk; subscription reaches the CLI or agent-sdk
verifier:
  claude:
    transport: cli
```

`AUTOMETTA_CLAUDE_TRANSPORT=cli` does the same for one dispatch without editing the manifest. See `.autometta.local.yaml.example` for the full template and comments.

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
| `transport: sdk` + `auth.claude.mode: subscription` + resolvable `OP_REF_CLAUDE_CODE_OAUTH_TOKEN` | Resolves to `cli (route-guard: ...)`. The api-sdk cannot authenticate with a subscription token, so the route guard downgrades to the CLI, which can. Set `auth.claude.mode: api` to keep the api-sdk. |
| `transport: sdk` + `auth.claude.mode: subscription` + `OP_REF_CLAUDE_CODE_OAUTH_TOKEN` unset or still a `YOUR_VAULT` placeholder | Exits non-zero before spawning any process. Message names the ref and `claude setup-token`. |
| `transport: sdk` + `auth.claude.mode: api` + `OP_REF_ANTHROPIC_API_KEY` unresolved | Exits non-zero before spawning any process. Message names the ref. |
| `transport: sdk` + `auth.claude.mode: local` | Refused by `auth-route.sh`: the local route is codex-family only. |
| `transport` value other than `cli`, `sdk`, or `agent-sdk` | Exits non-zero before spawning any process. |
| `transport: sdk` + `scripts/verify-sdk.py` missing | Falls back to `cli`, logged as `fallback-cli`. |
| Unset transport + any missing precondition from the table above | Resolves to `cli`, logged as `fallback-cli` with the reason. Never an error. |
| `transport: sdk` + SDK package missing | `verify-sdk.py` exits `2`; logged to the stage log. |
| `transport: sdk` + declared `Verifier effort` | Passes the level through `output_config.effort`; it is not discarded. |
| `advisor` weaker than `--model` (inverted #66714 pair) | `verify-sdk.py` exits `2` before any API call, naming both models. |
| `advisor` set + `auth.claude.mode` other than `api` | Exits non-zero before spawning any process. The advisor is an API-only feature. |
| `transport: agent-sdk` + `auth.claude.mode: subscription` + `OP_REF_CLAUDE_CODE_OAUTH_TOKEN` unset or still a `YOUR_VAULT` placeholder | Exits non-zero before spawning any process. Message names the ref and `claude setup-token`. |
| `transport: agent-sdk` + `auth.claude.mode: api` + `OP_REF_ANTHROPIC_API_KEY` unresolved | Exits non-zero before spawning any process. Message names the ref. |
| `transport: agent-sdk` + `auth.claude.mode: local` | Refused by `auth-route.sh`: the local route is codex-family only. |
| `transport: agent-sdk` + `scripts/verify-sdk-agent.py` missing | Falls back to `cli`, logged as `fallback-cli`. |
| `transport: agent-sdk` + `claude-agent-sdk` package missing | `verify-sdk-agent.py` exits `2`; logged to the stage log. |
| `transport: agent-sdk` + declared `Verifier effort` | Passes the level through `ClaudeAgentOptions.effort` (the CLI's `--effort` flag); it is not discarded. |
| `transport: agent-sdk` + `advisor` set | Not supported by this entrypoint; `resolve_claude_advisor` is not consulted on this branch. Set `transport: sdk` with `auth.claude.mode: api` for Fable-as-advisor. |

### Artefact glob derivation

The spawner parses the `## Deliverables` section of the stage card, extracts backtick-quoted paths, and derives a glob from their parent directories. If all deliverables share one parent directory (e.g., `scripts/`), the glob is `scripts/**`. When deliverables span multiple directories, the spawner falls back to `**` (broad recursive). This is a v1 heuristic; operators can override by invoking `verify-sdk.py` directly with a targeted glob.

The heuristic matters more now that the SDK is the default: it decides how much of the tree is read into the prompt, and it widens to whole directories rather than the deliverables themselves. A card whose deliverables span several directories derives `**`, which on a large repo is far more input than any verifier needs. Measure before dispatching a wide card on the SDK route, and pin `transport: cli` or pass a targeted glob where the derived one is too broad.

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

An OAuth token handed to `verify-sdk.py` 429s: the api-sdk is the raw Messages API and does not accept a Claude Code subscription credential (measured at the top of this document). When the ref is unset or still a `YOUR_VAULT` placeholder, `spawn-verifier.sh` exits before spawning anything; it never falls back to `ANTHROPIC_API_KEY`, because a silent fallback is how billing goes wrong invisibly. The one thing that stays api-only by design is the Fable-as-advisor option, whose advisor tool is an API feature; requesting an advisor on the subscription route fails closed.

**`scripts/verify-sdk-agent.py` is the production route for this credential.**
The api-sdk is not how the subscription route is dispatched: `spawn-verifier.sh`'s route guard
refuses that pairing (see the table at the top of this document) and downgrades
to the `cli`. `transport: agent-sdk` is the surface `claude_route_refusal`
actually permits on `CLAUDE_CODE_OAUTH_TOKEN`, and its entrypoint takes the
same token by inheriting the process env the `claude` CLI subprocess it spawns
would read anyway -- see [The Agent SDK entrypoint](#the-agent-sdk-entrypoint).

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

| Role | Family | Manifest key | Transport value | SDK entrypoint | Auth modes |
|---|---|---|---|---|---|
| verifier | claude | `verifier.claude.transport` | `sdk` (legacy spelling: `api-sdk`) | `scripts/verify-sdk.py` | api only -- subscription route-guards to `cli` |
| verifier | claude | `verifier.claude.transport` | `agent-sdk` | `scripts/verify-sdk-agent.py` | api, subscription |
| verifier | codex | `verifier.codex.transport` | `sdk` | `scripts/verify-sdk-openai.py` | api, subscription |
| orchestrator | claude | `orchestrator.claude.transport` | not offered | none | card 23 ran the experiment and kept cron+tick; see `memory/decision-sdk-controller-experiment.md` and `docs/experiments/sdk-controller-postmortem.md` |
| orchestrator | codex | `orchestrator.codex.transport` | not offered | none | same verdict as claude |

`claude_entrypoint_for_surface` in `scripts/models.sh` is the single source of
truth mapping a resolved claude surface to the script that implements it;
`spawn-verifier.sh` dispatches through it rather than hard-coding either path.

An unset verifier key resolves to `sdk` on both families wherever the
preconditions hold, and to `cli` where one is missing -- this default is
unchanged by `agent-sdk` existing. `agent-sdk` is reached only by naming it
explicitly. `AUTOMETTA_CLAUDE_TRANSPORT` and `AUTOMETTA_CODEX_TRANSPORT`
override their matching manifest key for an A/B run without editing the
manifest.

For a Codex SDK verifier, `spawn-verifier.sh` selects and checks `CODEX_HOME`
before the process starts:

| Resolved `auth.codex.mode` | Selected home | Required `auth.json` mode |
|---|---|---|
| subscription | `${AUTOMETTA_CODEX_SUBSCRIPTION_HOME:-~/.codex}` | `chatgpt` |
| api | `${AUTOMETTA_CODEX_HOME:-~/.codex-api-only}` | `apikey` |

Any mismatch fails closed and names both the requested billing mode and the
found `auth_mode`. This prevents an API key route accidentally spending the
plan, or a subscription route accidentally using the API-only sibling.
