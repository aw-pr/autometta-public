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

One JSON object per line. This example shows the core fields; newer rows also
carry the model, cache-creation and subscription-observation fields described
below. Historical rows are retained without backfilling.

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
| `role` | string | `worker` or `verifier`. Historical rows may contain `phat-controller`, the retired scheduled role. |
| `identity` | string | The full agent identity string from the stage card / state. |
| `tier` | string | Capability tier derived from the identity (`T0`, `T1`, `T2`, `T4`, `T5`), matching the agent-orchestrator tier table. Supplies the fallback rate when the model has no explicit rate. |
| `auth_route` | string | `subscription`, `api`, or `local` (codex only), resolved the same way as the dispatch (env override, then `.autometta.local.yaml`, then subscription default). |
| `input_tokens` | int or null | Fresh (non-cached) input tokens. Cache-creation (write) tokens are folded in here, see below. Null when no full breakdown was recovered. |
| `cached_input_tokens` | int or null | Input tokens served from the prompt cache (the cache-read count). Null when no full breakdown was recovered. |
| `output_tokens` | int or null | Generated output tokens. Null when no full breakdown was recovered. |
| `total_tokens` | int or null | Input including cached input, plus output. This remains populated for a `total_only` row. Null means usage could not be read. |
| `usage_status` | string | `recorded` for a full breakdown, `total_only` when only a real aggregate was recovered, or `unknown` when no usage signal was readable. |
| `wall_clock_s` | int | Estimated wall-clock seconds for the role. |
| `cost_usd_est` | float or null | Estimated USD equivalent from model rates, falling back to tier rates. Null when the breakdown is unavailable, because assigning a total to one rate would fabricate a cost. |
| `cache_hit_rate` | float or null | `cached_input_tokens / (input_tokens + cached_input_tokens)`, 0 when recorded input was genuinely zero, null when the breakdown is unavailable. |
| `result` | string | The loop's terminal verdict for this role: `pass`, `fail`, `partial`, `stalled`, or `aborted`. |

### Worker vs verifier

Worker and verifier are captured as separate lines, each with its own
`identity`, `tier`, `auth_route`, tokens, and `result`. A stage that runs a
worker then a verifier produces two lines. A verifier that is re-dispatched
(died without writing its artefact) produces an extra line with
`result: "aborted"` for the failed attempt, then a further line for the
attempt that succeeds.

The retired scheduled controller wrote a third role, `phat-controller`, once
per dispatched pass. Those historical rows remain part of the ledger. The
current deterministic verbs dispatch no controller model and produce no
controller-role cost line. The itemised cost log never replaces the budget
ledger.

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
| Claude CLI with stream JSON output | The final `result` line's `usage` object with `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens` | Full breakdown when present in stdout. `claude-token-log.sh` also reads that result line to write `Total tokens: N`; this is a fallback when the matching Claude transcript is unavailable. |
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

`cost_usd_est` comes from [scripts/rates.sh](../scripts/rates.sh). The
producer first calls `rate_for_model` with the dispatched model; only an
unrecognised model falls back to `rate_for_tier`. Rates are USD per one million
tokens, with separate input, cached-read and output values. Tier orders
capability and is not a price ranking.

The numeric table is kept in code rather than duplicated here. It is an
operator-maintained estimate, not a live provider-price feed. When reviewing
or changing it, verify the model's pricing and update the matching rate row;
do not substitute a neighbouring model's price because it shares a tier.

For `usage_status: "recorded"`, `cost_usd_est = (input_tokens * input_rate +
cached_input_tokens * cached_rate + output_tokens * output_rate) / 1e6`.
It is null for `total_only` and `unknown` rows. Cache-creation tokens remain
folded into input for this estimate; the separate field supports analysis of
that limitation.

The Codex `local` route has a zero USD rate, while its real token usage still
counts towards the budget. An unknown identity falls back to T2 rather than
being treated as free. Subscription rows show an API-equivalent estimate,
not an incremental subscription charge. Provider bills and account usage are
separate evidence.

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

### Live outlier baseline

The heartbeat judges live uncached tokens (`input_tokens + output_tokens`)
against the role's median uncached tokens, excluding cache reads. It filters
for `usage_status: recorded` rows with non-negative integer input and output
counts, then takes the last ten eligible rows per role. Missing, null,
boolean or fractional split values are excluded regardless of usage status.
Worker and verifier rows never share a baseline.

At least five eligible split rows and a positive uncached median are required.
Otherwise judgement falls back to total tokens at the same warning and kill
multiples. The separate total baseline takes the last ten `recorded` or
`total_only` rows with non-negative integer `total_tokens`, requiring at least
five rows and a positive median. Unknown usage and null totals are excluded
rather than converted to zero.

`AUTOMETTA_OUTLIER_BASELINE_WINDOW` (default 10) and
`AUTOMETTA_OUTLIER_MIN_SAMPLES` (default 5) configure both baselines.
`AUTOMETTA_OUTLIER_MULTIPLE` (default 10) sets the warning multiple and
`AUTOMETTA_OUTLIER_KILL_MULTIPLE` (default 15, `0` disables this kill) sets
the kill multiple for uncached tokens or the total fallback.
`AUTOMETTA_OUTLIER_TOTAL_KILL_MULTIPLE` (default 40, `0` disables) adds an
independent total-tokens kill backstop for cache-heavy loops. Either kill
threshold can terminate a dispatch. Both kill variables must be `0` for
observe-only behaviour.

This command shows the default per-role uncached baseline against a repo's
real ledger:

```sh
jq -s '
  map(select(
    .usage_status == "recorded" and
    ([.input_tokens, .output_tokens] | all(.[];
      type == "number" and . >= 0 and . == floor))
  ) | . + {uncached_tokens: (.input_tokens + .output_tokens)})
  | group_by(.role)
  | map(.[-10:] | sort_by(.uncached_tokens) |
      {role: .[0].role, comparable_rows: length,
       median_uncached_tokens: (if length < 5 then null
         elif length % 2 == 1 then .[length / 2 | floor].uncached_tokens
         else ((.[length / 2 - 1].uncached_tokens + .[length / 2].uncached_tokens) / 2)
         end)})
' state/cost-log.jsonl
```

The heartbeat report carries `live_uncached_tokens` and
`baseline_median_uncached_tokens` alongside the total figures.
`token_outlier.measure` records `uncached` or `total`; uncached wins when
both kill thresholds fire. Kills terminate children before the wrapper and
leave the worktree standing, with `outcome: killed-token-outlier`. This changes
only the outlier judgement. Budget accounting, cost-log rows and repo token
caps still count every token, including cache reads.

## Verifying the producer

`scripts/cost-log-smoke.sh` exercises the producer offline (no API spend, no
dispatch) against synthetic logs for every route, and asserts the Phase-2
result on a repeated-prefix loop: a cold run with `cache_hit_rate` 0 followed
by a warm run with a non-zero hit rate and a strictly lower `cost_usd_est` for
the same token shape. The live end-to-end cache check that actually calls the
Anthropic API is `scripts/sdk-cache-smoke.sh`.

`scripts/outlier-warning-smoke.sh` replays the 2026-08-25 sequence with
ordinary worker rows followed by a live 45,758,708-token transcript. It also
checks cold-start silence, unknown and null-total exclusion, natural process
completion, the repo ticker warning and the tick-log route.

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

### Subscription observations and cache writes

New rows also carry `model`, `cache_creation_input_tokens` and
`subscription_usage`. Cache creation remains included in `input_tokens` for
compatibility with existing totals and budget gates. Subtract the separate
cache-creation field to recover fresh input; a missing field on an old record
means unknown, not zero. The transcript readers retain their three-number
contract unless the cost-log producer opts into the additional cache-write
field with `AUTOMETTA_TOKEN_CACHE_WRITES=1`.

Registration reads the existing credential-free quota reader and saves a
snapshot under `state/usage-starts/<agent-id>.json`. This survives removal of
the active-agent registry. Cost-log emission matches the log path, role,
family and dispatch start time, then captures a closing reading. Observability
failures remain non-fatal and do not affect admission, budgets or pacing.

`subscription_usage` contains `start`, `end`, `status`, `windows` and
`attribution: shared_account` when evidence is present. Each usable window has
`percentage_points`, its key, label and reset time. The two readings must be
chronologically distinct and in the same unexpired window with a non-decreasing
meter. Missing or unchanged readings and reset windows produce unavailable
observations. The observation is account movement between the recorded sample
times, including concurrent activity and collection lag; it is not a per-card
charge. Account movements must not be summed across overlapping dispatches.
