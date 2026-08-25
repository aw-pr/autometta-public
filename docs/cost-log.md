# Cost log

The cost log is the per-repo spend record that turns each Autometta tick into
something measurable. Every worker or verifier the loop dispatches appends one
JSON object, one per line, to `state/cost-log.jsonl` in the subscriber repo. It
is the stable contract between the tick loop (the producer) and any FinOps
dashboard (the consumer): the loop writes; the dashboard reads.

It complements `state/budget.json`. The budget file is a single running total
that gates the loop (a hard stop on spend). The cost log is the itemised
ledger behind that total: who spent what, on which stage, through which billing
route, with how much of the input served from cache.

Provider-window utilisation is a separate fact. It says how much subscription
capacity remains and when that provider window resets; it does not say what a
role cost. The tick reads it once through `scripts/quota-window.py` and writes
the sanitised result to `state/quota-window.json`. It does not append quota
readings to this ledger, invent token usage from a percentage, or treat unknown
as zero. See `docs/observability.md` for the snapshot contract and staleness
rules.

## Where it lives

`<repo>/state/cost-log.jsonl`, alongside `budget.json` and `logs/`. Like the
rest of `state/` runtime content it is gitignored (`state/**`), so it is a
local on-disk record, not a committed artefact. A dashboard reads it directly
from disk. It is append-only: the loop never rewrites earlier lines.

## Schema

One JSON object per line. All fields are always present.

```json
{
  "ts": "2026-06-06T18:53:09Z",
  "repo": "fractals-from-the-90s",
  "stage_id": "U-USA-6",
  "role": "worker",
  "identity": "GPT-5.6 Sol <gpt-5-6-sol@local>",
  "tier": "T2",
  "auth_route": "subscription",
  "input_tokens": 3200,
  "cached_input_tokens": 14800,
  "output_tokens": 900,
  "total_tokens": 18900,
  "usage_status": "recorded",
  "wall_clock_s": 0,
  "cost_usd_est": 0.02754,
  "cache_hit_rate": 0.8222,
  "result": "pass"
}
```

| Field | Type | Meaning |
|---|---|---|
| `ts` | string | UTC ISO8601 timestamp when the line was written (role reap time, not dispatch time). |
| `repo` | string | Subscriber repo basename. |
| `stage_id` | string | The stage this role served. |
| `role` | string | `worker`, `verifier`, or `phat-controller` (the queue minder's one triage dispatch per pass; see `docs/tick-loop.md` section (k)). |
| `identity` | string | The full agent identity string from the stage card / state. |
| `tier` | string | Capability tier derived from the identity (`T0`, `T1`, `T2`, `T4`, `T5`), matching the agent-orchestrator tier table. Drives the rate row. |
| `auth_route` | string | `subscription`, `api`, or `local` (codex only), resolved the same way as the dispatch (env override, then `.autometta.local.yaml`, then subscription default). |
| `input_tokens` | int or null | Fresh (non-cached) input tokens. Cache-creation (write) tokens are folded in here, see below. Null when no full breakdown was recovered. |
| `cached_input_tokens` | int or null | Input tokens served from the prompt cache (the cache-read count). Null when no full breakdown was recovered. |
| `output_tokens` | int or null | Generated output tokens. Null when no full breakdown was recovered. |
| `total_tokens` | int or null | Input including cached input, plus output. This remains populated for a `total_only` row. Null means usage could not be read. |
| `usage_status` | string | `recorded` for a full breakdown, `total_only` when only a real aggregate was recovered, or `unknown` when no usage signal was readable. |
| `wall_clock_s` | int | Estimated wall-clock seconds for the role. |
| `cost_usd_est` | float or null | Estimated USD cost from the per-tier rate table. Null when the breakdown is unavailable, because assigning a total to one rate would fabricate a cost. |
| `cache_hit_rate` | float or null | `cached_input_tokens / (input_tokens + cached_input_tokens)`, 0 when recorded input was genuinely zero, null when the breakdown is unavailable. |
| `result` | string | The loop's terminal verdict for this role: `pass`, `fail`, `partial`, `stalled`, or `aborted`. |

### Worker vs verifier

Worker and verifier are captured as separate lines, each with its own
`identity`, `tier`, `auth_route`, tokens, and `result`. A stage that runs a
worker then a verifier produces two lines. A verifier that is re-dispatched
(died without writing its artefact) produces an extra line with
`result: "aborted"` for the failed attempt, then a further line for the
attempt that succeeds.

phat-controller writes a third role, `phat-controller`, once per dispatched
pass. That line is appended synchronously when the pass returns, while the
same parsed tokens are also charged to `state/budget.json`; the itemised cost
log never replaces the hard-stop ledger. The verbs the controller calls write
no cost line of their own because they dispatch no model.

### `wall_clock_s` is an estimate

Dispatch is fire-and-forget: the spawn scripts background the CLI and return,
so the loop never sees an exact end time. Wall-clock is measured as
`now - started_at` at the tick that reaps the role:

- Worker: `now - stage.started_at`.
- Verifier: `now - stage.verifier_started_at` (stamped when the verifier is
  dispatched).

Both are upper bounds. They include up to one tick interval of latency between
the role actually exiting and the loop noticing. Treat the figure as
"wall-clock to completion as observed by the loop", good enough for relative
comparison across stages, not a precise runtime.

## Per-route token fidelity

The parser prefers the harness transcript for either family, then falls back
to structured stdout. Transcript selection is scoped to the dispatch working
directory and start time, so a reused worktree does not re-bill an earlier
run.

| Route | Usage signal | What we get |
|---|---|---|
| Codex CLI (`codex exec`) | Last cumulative `total_token_usage` in the matching Codex session JSONL | Full breakdown. Codex `input_tokens` includes cached input, so the producer records fresh input as `input_tokens - cached_input_tokens`, cached input separately, and output as emitted. The three fields reconcile to Codex `total_tokens`. |
| Claude CLI (`claude -p`) | Per-message usage in the matching Claude Code transcript | Full breakdown, deduplicated by request and summed from dispatch start. Cache creation is folded into fresh input and cache reads remain separate. |
| SDK verifier (`verify-sdk.py`) | `cache: write=W read=R input=I output=O` | Full breakdown. `input_tokens = I + W`, `cached_input_tokens = R`, `output_tokens = O`. |
| Claude CLI with JSON output | a `usage` object with `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens` | Full breakdown when present in stdout. This is a fallback when the matching Claude transcript is unavailable. |
| Terminal fallback | Codex `tokens used` or Claude `Total tokens: <N>` | `usage_status: "total_only"`, the real aggregate in `total_tokens`, and null breakdown, cost and cache-rate fields. |
| No readable signal | Missing transcript usage and no terminal total | `usage_status: "unknown"` with null token, cost and cache-rate fields. The tick logs a `WARNING: usage unknown` line and does not charge an invented value to the budget. |

Zero remains a measured fact. A complete transcript that reports zero records
numeric zeroes and `usage_status: "recorded"`. Missing data never becomes zero.
Historical rows retain the older schema and are not rewritten.

### Cache-creation folding

Anthropic bills cache-creation (write) tokens at roughly 1.25x the base input
rate, and cache-read tokens at roughly 0.1x. The schema carries two input
buckets, not three, so cache-creation tokens are folded into `input_tokens`
and costed at the base input rate. This slightly under-estimates the write
premium. It keeps the schema to a clean two-bucket model (paid-fresh vs
paid-cheap) and keeps the logged numbers reconcilable against `cost_usd_est`.
Reconcile against the provider bill for ground truth.

## Rate table

`cost_usd_est` comes from `scripts/rates.sh`, the single source for both the
identity-to-tier map and the per-tier rates. Edit that one file when list
prices move. Rates are USD per one million tokens.

| Tier | Models (Anthropic / OpenAI) | Input | Cached read | Output |
|---|---|---|---|---|
| T0 | Fable 5 | 10.00 | 1.00 | 50.00 |
| T1 | Opus, GPT-5.6 Sol | 15.00 | 1.50 | 75.00 |
| T2 | Sonnet, GPT-5.6 Terra | 3.00 | 0.30 | 15.00 |
| T4 | Haiku, GPT-5.6 Luna | 1.00 | 0.10 | 5.00 |
| T5 | Codex GPT-OSS 120B (local Ollama) | 0.00 | 0.00 | 0.00 |

T0 is the opt-in Claude Fable 5 tier, a step above Opus and the only tier above
T1. It is dispatched per card only: no existing identity resolves to it, so a
stage runs Fable solely when its card names a `*Fable*` worker or verifier. The
label was previously a placeholder for the orchestrator's own main session,
which is not a dispatched role and is not costed here.

T5 is the codex `local` auth route: real tokens still get counted (the token
cap still bounds attention and wall-clock), only the USD estimate is zero. An
unrecognised local identity would otherwise fall through to the T2 default and
cost a free dispatch at the $3/M workhorse rate, so T5 is an explicit row
rather than an accident of the fallback.

For `usage_status: "recorded"`, `cost_usd_est = (input_tokens * input_rate +
cached_input_tokens * cached_rate + output_tokens * output_rate) / 1e6`.
It is null for `total_only` and `unknown` rows.

Tier is derived from the identity string (`tier_for_identity`). An identity
with no recognised tier marker falls back to T2 (workhorse), so an unknown
agent is costed rather than treated as free.

## Reading the log

It is plain JSONL, so `jq` works directly:

```sh
# Per-stage estimated spend
jq -r '"\(.stage_id) \(.role): $\(.cost_usd_est)"' state/cost-log.jsonl

# Total known estimated spend for the repo
jq -s 'map(.cost_usd_est // 0) | add' state/cost-log.jsonl

# Dispatches whose usage needs investigation
jq -c 'select((.usage_status // "legacy") != "recorded")' state/cost-log.jsonl

# Cache-hit rate per verifier (SDK route)
jq -r 'select(.role=="verifier") | "\(.stage_id) hit=\(.cache_hit_rate)"' state/cost-log.jsonl
```

## Verifying the producer

`scripts/cost-log-smoke.sh` exercises the producer offline (no API spend, no
dispatch) against synthetic logs for every route, and asserts the Phase-2
result on a repeated-prefix loop: a cold run with `cache_hit_rate` 0 followed
by a warm run with a non-zero hit rate and a strictly lower `cost_usd_est` for
the same token shape. The live end-to-end cache check that actually calls the
Anthropic API is `scripts/sdk-cache-smoke.sh`.

## Prompt caching (Phase 2)

See [the prompt caching section of the SDK verifier doc](sdk-verifier.md) for
the live caching implementation. Two points specific to the cost log:

- The cost log is how the caching saving is measured rather than assumed. Run
  the loop once to get a Phase-1 baseline (cold cache, `cache_hit_rate` 0),
  then again within the cache TTL window and compare `cached_input_tokens`
  against `input_tokens` on the second pass.
- Cache TTL is about five minutes on the Anthropic API. A loop that idles
  longer than the window between turns re-pays the full prefix, so the cost log
  on a slow loop will show `cache_hit_rate` near 0 even with caching enabled.
  Match polling cadence to the window to keep the prefix warm.

### Subscription vs API caching

The portfolio mixes billing routes, so the cost log records `auth_route` per
line. Both routes cache, they just expose it differently:

- API route (SDK verifier, codex api mode): caching is explicit. The SDK marks
  the stable prefix with `cache_control` and the API returns
  `cache_read_input_tokens` / `cache_creation_input_tokens` in the usage block.
  This is the route the cost log can measure precisely.
- Subscription / OAuth route (`claude -p`, codex chatgpt mode): caching is
  applied automatically by the harness. The terminal output is incomplete,
  but the local Claude and Codex transcripts expose cached-token counts, so
  ordinary dispatch rows now retain the full breakdown.
