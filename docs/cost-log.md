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
  "identity": "Codex GPT-5.3 <codex-gpt-5-3@local>",
  "tier": "T2",
  "auth_route": "subscription",
  "input_tokens": 0,
  "cached_input_tokens": 0,
  "output_tokens": 0,
  "wall_clock_s": 0,
  "cost_usd_est": 0.0,
  "cache_hit_rate": 0.0,
  "result": "pass"
}
```

| Field | Type | Meaning |
|---|---|---|
| `ts` | string | UTC ISO8601 timestamp when the line was written (role reap time, not dispatch time). |
| `repo` | string | Subscriber repo basename. |
| `stage_id` | string | The stage this role served. |
| `role` | string | `worker` or `verifier`. |
| `identity` | string | The full agent identity string from the stage card / state. |
| `tier` | string | Capability tier derived from the identity (`T1`, `T2`, `T4`), matching the agent-orchestrator tier table. Drives the rate row. |
| `auth_route` | string | `subscription` or `api`, resolved the same way as the dispatch (env override, then `.autometta.local.yaml`, then subscription default). |
| `input_tokens` | int | Fresh (non-cached) input tokens. Cache-creation (write) tokens are folded in here, see below. |
| `cached_input_tokens` | int | Input tokens served from the prompt cache (the cache-read count). |
| `output_tokens` | int | Generated output tokens. |
| `wall_clock_s` | int | Estimated wall-clock seconds for the role. |
| `cost_usd_est` | float | Estimated USD cost from the per-tier rate table. An estimate, not an invoice. |
| `cache_hit_rate` | float | `cached_input_tokens / (input_tokens + cached_input_tokens)`, 0 when there was no input. |
| `result` | string | The loop's terminal verdict for this role: `pass`, `fail`, `partial`, `stalled`, or `aborted`. |

### Worker vs verifier

Worker and verifier are captured as separate lines, each with its own
`identity`, `tier`, `auth_route`, tokens, and `result`. A stage that runs a
worker then a verifier produces two lines. A verifier that is re-dispatched
(died without writing its artefact) produces an extra line with
`result: "aborted"` for the failed attempt, then a further line for the
attempt that succeeds.

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

How much of the token breakdown is real depends on what each route prints to
its log. The parser (`costlog_parse_breakdown` in `scripts/cost-log.sh`) reads
whatever is there and is honest about the gaps:

| Route | Log signal | What we get |
|---|---|---|
| SDK verifier (`verify-sdk.py`) | `cache: write=W read=R input=I output=O` | Full breakdown. `input_tokens = I + W`, `cached_input_tokens = R`, `output_tokens = O`. The only route with a true split today. |
| Claude CLI with JSON output | a `usage` object with `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens` | Full breakdown, parsed if present. The default `claude -p` text output does not emit it, so most CLI runs fall through to total-only. |
| Codex CLI (`codex exec`) | `tokens used` then a number | Total only. The whole total lands in `input_tokens`; `cached_input_tokens` and `output_tokens` are 0 and `cache_hit_rate` is 0. |
| Claude CLI text / other | `Total tokens: <N>` | Total only, same coarseness as codex. |

The coarseness is deliberate: a total-only route still records real spend, it
just cannot attribute it across the input/cached/output buckets. When such a
route is dominant, `cache_hit_rate` will read 0 because the breakdown is not
visible to us, not necessarily because nothing was cached. The SDK route is
where the cache saving is measured precisely.

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
| T1 | Opus, GPT-5.5 | 15.00 | 1.50 | 75.00 |
| T2 | Sonnet, Codex GPT-5.x | 3.00 | 0.30 | 15.00 |
| T4 | Haiku, GPT-5 mini | 1.00 | 0.10 | 5.00 |

T0 is the opt-in Claude Fable 5 tier, a step above Opus and the only tier above
T1. It is dispatched per card only: no existing identity resolves to it, so a
stage runs Fable solely when its card names a `*Fable*` worker or verifier. The
label was previously a placeholder for the orchestrator's own main session,
which is not a dispatched role and is not costed here.

`cost_usd_est = (input_tokens * input_rate + cached_input_tokens * cached_rate
+ output_tokens * output_rate) / 1e6`.

Tier is derived from the identity string (`tier_for_identity`). An identity
with no recognised tier marker falls back to T2 (workhorse), so an unknown
agent is costed rather than treated as free.

## Reading the log

It is plain JSONL, so `jq` works directly:

```sh
# Per-stage estimated spend
jq -r '"\(.stage_id) \(.role): $\(.cost_usd_est)"' state/cost-log.jsonl

# Total estimated spend for the repo
jq -s 'map(.cost_usd_est) | add' state/cost-log.jsonl

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
  applied automatically by the harness, but the default CLI output does not
  surface the cached-token counts, so the cost log sees a total only and
  `cache_hit_rate` reads 0. The saving is still happening, it is just not
  observable from the log. To measure it, use the API route (or the SDK
  verifier) where the usage block is returned.
