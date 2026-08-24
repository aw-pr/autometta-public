# Verifier bake-off: local weights against the cloud free tiers

Card 45 gave the codex family a free local route (`auth.codex.mode: local`,
Ollama-served weights) and documented a cloud free route in passing,
without settling which free option is actually good enough to trust as a
verifier, or for which kinds of stage. This card answers that question by
retro-grading every free candidate against benchmark stages that already
carry a frontier verdict — a real verifier artefact produced during normal
fleet operation, in `state/verifiers/` — and scoring agreement.

## The harness

- `scripts/verifier-bake-off-caller.py` — single-shot caller. Every
  candidate here, local and cloud, speaks an OpenAI-compatible
  `/chat/completions` endpoint (Ollama's own compatibility layer for local
  weights; OpenRouter and Groq natively), so one caller covers all of them:
  a base URL, an optional API-key env var, and a model id per candidate.
  Prompt packaging is reused from `scripts/verify-sdk.py` rather than
  re-derived (`build_static_block` / `build_variable_block`, loaded
  dynamically since a hyphenated filename is not an importable module
  name), so a bake-off verdict is shaped identically to a real one and
  validates against the same `schemas/verifier.json`.
- `scripts/verifier-bake-off.sh` — the driver. `run` dispatches one
  (candidate, stage) pair; `batch` loops the matrix, serialising each cloud
  provider's own requests behind a plain-sleep pace and a hard daily stop
  tracked in `state/bake-off-budget.json` (a budget file, not retries, per
  the repo's stated policy).
- `scripts/verifier-bake-off-score.py` — reads every checked-in
  `examples/bake-off/<candidate>/<stage-id>.json` plus the matching
  frontier artefact named in `examples/bake-off/manifest.json`, and
  aggregates FAIL recall, PASS agreement, artefact discipline, and mean
  wall clock per candidate.
- `scripts/verifier-bake-off-route-smoke.sh` — offline, no network or
  credentials: asserts route isolation (below) and fail-closed behaviour
  with a stubbed `op-fetch`.

Every score in this document is re-derivable:

```sh
scripts/verifier-bake-off.sh batch
scripts/verifier-bake-off-score.py --manifest examples/bake-off/manifest.json --bake-off-dir examples/bake-off
```

## Single-shot, for local too, not only cloud

Card 45's local route dispatches `codex exec --oss` as an agentic
tool-calling loop, and the card's own note allows that shape for local
candidates by default, falling back to this single-shot caller only "if
one of them fails or flails through the CLI route." This bake-off runs
**every** candidate, local included, through the single-shot caller from
the start, for two reasons:

1. Free-tier request caps already force the cloud candidates into
   single-shot mode (below). Running local single-shot too keeps the
   comparison of *judgement* rather than of *retrieval shape* — the same
   packaged evidence goes to every candidate, agentic local models get no
   advantage from being able to go re-read a file the cloud candidates
   cannot.
2. `codex exec --oss` against four different local models for ten
   benchmark stages each is a materially larger, slower harness to build
   and run than one caller reused seven ways, for a question ("does the
   verdict agree with the frontier's") that single-shot already answers.

This is exactly the allowance the card names: "a candidate that only works
single-shot is a finding, not a failure of the harness." Treat every local
score below as a single-shot score. A future card that wires a winning
local candidate into `spawn-verifier.sh`'s CLI route should re-measure
whether the agentic shape changes the picture — this bake-off does not
claim it wouldn't.

## The candidate table (run 2026-08-24)

| Candidate | Where | Model id | Notes |
|---|---|---|---|
| `local-gpt-oss-120b` | local Ollama | `gpt-oss:120b` | proven by card 45's probe |
| `local-qwen3-coder-30b` | local Ollama | `qwen3-coder:30b` | fast local option |
| `local-qwen3-32b` | local Ollama | `qwen3:32b` | general sibling of the coder tune |
| `local-devstral` | local Ollama | `devstral:latest` | Mistral's agentic-coding tune |
| `groq-gpt-oss-120b` | Groq free tier | `openai/gpt-oss-120b` | same weights as `local-gpt-oss-120b`; the controlled pair |
| `openrouter-nemotron-3-super-120b` | OpenRouter free tier | `nvidia/nemotron-3-super-120b-a12b:free` | see substitution note |
| `openrouter-nemotron-3-ultra-550b` | OpenRouter free tier | `nvidia/nemotron-3-ultra-550b-a55b:free` | see substitution note |

Paid Grok is excluded per the card: no usable free API route exists for it.

**Substitution note.** Card 46's candidate table named
`qwen/qwen3-coder:free` and `deepseek/deepseek-r1:free` as the two
OpenRouter candidates. Neither was present in OpenRouter's `/models`
listing when this bake-off ran (2026-08-24), one day after the card was
authored — replaced by an unrelated roster (`nvidia/nemotron-3-*:free`,
`z-ai/glm-5.2:free`, and others). This is the exact risk the card names in
its own words: "the list rotates without notice." `nvidia/nemotron-3-super-120b-a12b:free`
(120B-class MoE, replacing the qwen3-coder slot — the closer size match to
the local/Groq gpt-oss-120b pair) and `nvidia/nemotron-3-ultra-550b-a55b:free`
(550B-class MoE, replacing the deepseek-r1 slot — the "biggest free MoE
available" slot) were confirmed live by a direct chat-completions call
before the batch ran. `z-ai/glm-5.2:free` was tried first as a second
120B-class candidate and returned a consistent `429` ("temporarily
rate-limited upstream") on every attempt — an upstream provider-side
limit, not an account cap, and not something a client-side retry fixes.
Operators re-running this harness later should expect to re-check
OpenRouter's live free roster before trusting this table's model ids.

## Route isolation

Per the auth-route-security skill, each provider's caller names ONLY its
own key:

- `op-refs.sh` carries committed placeholder rows `OP_REF_GROQ_API_KEY`
  and `OP_REF_OPENROUTER_API_KEY` (already present at HEAD from an earlier
  card-45-adjacent commit; this card's contribution is exercising them).
- `scripts/verifier-bake-off.sh` resolves exactly one `NAME=ref` pair per
  cloud candidate and hands it to `op-fetch NAME=ref -- python3
  scripts/verifier-bake-off-caller.py ...`. The paid refs
  (`OP_REF_OPENAI_API_KEY`, `OP_REF_ANTHROPIC_API_KEY`) are never named on
  a free route, so `op-fetch`'s `env -i` + allowlist strips them from the
  child even when they are exported in the parent shell — gotcha 8's
  failure mode closed at the route layer, not by convention.
- `scripts/verifier-bake-off-caller.py` itself only ever reads the one env
  var named by `--api-key-env`; no provider branch reads
  `OPENAI_API_KEY`/`ANTHROPIC_API_KEY` under any code path.
- Fail-closed: an unset or still-placeholder (`op://YOUR_VAULT/...`) ref
  aborts before any `op-fetch` call, let alone a network request.

Verified live during this run: with `OPENAI_API_KEY` and
`ANTHROPIC_API_KEY` exported in the parent shell, `op-fetch
GROQ_API_KEY=$OP_REF_GROQ_API_KEY -- env` showed only `GROQ_API_KEY` in the
child environment; the two paid keys were absent. `scripts/verifier-bake-off-route-smoke.sh`
turns that same property into a repeatable, credential-free offline check
(stubbed `op-fetch` capturing argv) so it does not depend on a human
re-running the live version. **Caution for anyone reading this transcript
or a session log from this run**: an early manual redaction attempt during
testing printed most of a real Groq key to a terminal before the isolation
property itself was confirmed. The isolation mechanism was never at
fault — nothing in `scripts/verifier-bake-off-caller.py` or
`scripts/verifier-bake-off.sh` logs a credential value anywhere — but the
key that leaked into that one debugging session should be rotated in
1Password out of caution.

## Data-sharing constraint

Every cloud call ships the stage card and packaged deliverable files to a
third-party API (Groq or OpenRouter). Nothing from `.autometta.local.yaml`,
`op-refs.local.sh`, or the controller's home directory is ever included —
the caller only ever reads the card and the deliverable globs named in
`examples/bake-off/manifest.json`. That is still real code and prose
leaving the machine. **Private-tier repos stay local-only**: only the four
`local-*` candidates are appropriate for a repo whose diffs must not reach
a third party. This bake-off's own benchmark stages are drawn from
`autometta` and `emergence-lab`, both of which already accept cloud
dispatch under their existing manifests.

## Gotchas found running this (feed these back into the packaging, not just this doc)

1. **Groq fronts with Cloudflare, and Python's default `urllib` User-Agent
   gets a bot-detection 403** whose body ("error code: 1010") reads exactly
   like an auth failure — nothing to do with the key. `curl` and any
   non-default User-Agent pass. `scripts/verifier-bake-off-caller.py` sets
   `User-Agent: autometta-verifier-bake-off/1.0` on every request (all
   three providers, not just Groq) so this does not silently recur the
   next time a caller is built against a Cloudflare-fronted provider.
2. **Reasoning models spend `max_tokens` on hidden thinking before any
   content.** `openai/gpt-oss-120b` (Groq) and `nvidia/nemotron-3-*`
   (OpenRouter) both showed this live: a first pass at `verify-sdk.py`'s
   `MAX_TOKENS = 4096` truncated a Nemotron response mid-JSON-object with
   `completion_tokens` landing exactly on the cap. Fix: `MAX_TOKENS = 8192`
   plus damping the reasoning effort on both providers that expose a knob
   (`reasoning_effort: low` for Groq's gpt-oss, `reasoning: {effort: low}`
   for OpenRouter's unified field).
3. **Groq's stated "1,000 req/day" headline is not the binding
   constraint — tokens per minute is, and it binds almost immediately.**
   The on-demand tier caps `openai/gpt-oss-120b` at 8,000 tokens/minute,
   and that ceiling is judged against **(prompt tokens + requested
   `max_tokens`)**, confirmed by two live `413`s where raising
   `max_tokens` to fix gotcha 2 made the rejection worse, not better. The
   full verifier rubric (`templates/verifier-prompt.md` + the schema +
   the dispatch-contract reminders) alone runs roughly 1,500–2,000 tokens
   before a single line of stage card or evidence is added; even this
   bake-off's *smallest* benchmark stage (`06-real-dispatch-test`, a
   107-line script) landed at ~5,500 prompt tokens. The caller now
   estimates prompt size (~3.3 chars/token, biased to overestimate) and
   reserves whatever headroom is left under a 7,200-token target as
   `max_tokens`; when even the 768-token completion floor would not fit,
   it skips the request entirely rather than send one certain to be
   rejected. Both of this bake-off's largest benchmark stages
   (`02-fractal-defaults-and-cycling` at ~14k estimated prompt tokens,
   `05-math-formula-rendering` at ~27k) hit exactly that skip path. See
   the results table: Groq's realistic daily capacity for this verifier
   shape is far below 1,000 requests, and is a function of stage size, not
   a fixed count.
4. **OpenRouter's free-model roster rotates fast enough to invalidate a
   card written one day earlier** — the substitution note above. Anything
   that hardcodes a `:free` model id (a card, a script default) needs a
   liveness check immediately before use, not just at authoring time.
5. **The driver never passed a timeout to the caller, so local candidates
   inherited the cloud-tuned 180s default** and timed out on this
   benchmark's larger stages (~130-180s just short of finishing on
   `local-devstral`/`local-qwen3-coder-30b`). Fixed with a local-only
   `--timeout-seconds` (`AUTOMETTA_BAKEOFF_LOCAL_TIMEOUT_SECONDS`, default
   420s; cloud candidates are unchanged since their caps, not wall clock,
   are the binding constraint). That fix's first version unconditionally
   expanded `"${timeout_args[@]}"`, which is empty for every cloud
   candidate — bash 3.2 (macOS's shipped `/bin/bash`) throws "unbound
   variable" expanding an empty array under `set -u`, crashing every cloud
   dispatch before it reached `op-fetch`.
   `scripts/verifier-bake-off-route-smoke.sh` caught this immediately
   (three checks failed: no capture file, meaning `op-fetch` was never
   called). Fixed with the same `${arr[@]:+"${arr[@]}"}` guard the script's
   own `api_pairs` array already used one branch over — the bug was not
   copying an existing safe idiom.

## Results

<!-- Generated by scripts/verifier-bake-off-score.py — regenerate rather than hand-edit. -->

Ground truth: 10 benchmark stages, 10/10 carrying a frontier verdict, 6 of
which contain at least one frontier FAIL criterion
(`02-fractal-defaults-and-cycling`, `05-math-formula-rendering`,
`15c-sdk-verifier-integration`, `16-sdk-verifier-prompt-cache`,
`22-mcp-served-cards-design`, plus `03-dla-revive`/`06-real-dispatch-test`/
`29-swarmalators-kernel`/`30-markus-lyapunov-kernel`/
`45-a-free-verifier-tier-on-local-weights` as the PASS side) — well past the
card's 3-FAIL floor.

```sh
scripts/verifier-bake-off-score.py --manifest examples/bake-off/manifest.json --bake-off-dir examples/bake-off --format markdown
```

| Candidate | Attempts | Artefact discipline | FAIL recall | PASS agreement | Mean wall clock (s) | Requests/verification |
|---|---:|---:|---:|---:|---:|---:|
| `groq-gpt-oss-120b` | 1 | 0% | n/a | n/a | 2.9 | 1.0 |
| `local-devstral` | 10 | 80% | 0% (0/11) | 96% (49/51) | 167.9 | 1.0 |
| `local-gpt-oss-120b` | 10 | 100% | 77% (10/13) | 78% (51/65) | 93.0 | 1.0 |
| `local-qwen3-32b` | 10 | 90% | 8% (1/12) | 93% (55/59) | 278.7 | 1.0 |
| `local-qwen3-coder-30b` | 10 | 100% | 15% (2/13) | 98% (64/65) | 45.8 | 1.0 |
| `openrouter-nemotron-3-super-120b` | 10 | 60% | 0% (0/3) | 95% (38/40) | 94.3 | 1.0 |
| `openrouter-nemotron-3-ultra-550b` | 10 | 90% | 77% (10/13) | 72% (42/58) | 50.4 | 1.0 |

All four local candidates ran the full 10/10 matrix this attempt (attempt
1 hit the Claude session limit before local ran at all; attempt 2 died
ending its turn to wait for a background batch — see the re-brief above).
`groq-gpt-oss-120b` stays at its attempt-2 count of 1/10 per the re-brief's
explicit instruction not to retry the other nine: its 8,000-token/minute
ceiling cannot fit this verifier's ~12-15k-token prompt at all, so nine
more attempts would reproduce the same skip, not new information (gotcha 3
above already documents the mechanism).

**Reading "Attempts" against the denominators above.** `local-gpt-oss-120b`
and `local-qwen3-coder-30b` reached 10/10 *attempts* with 100% artefact
discipline — every attempt produced a schema-valid verdict. `local-devstral`
attempted 10/10 but only 8/10 parsed (one raw `"PASS|FAIL"` string where the
schema wants one or the other, one response with the criteria array spliced
directly into the object root instead of nested under `criteria` — both
genuine instruction-following misses, not harness truncation, now that the
timeout fix below is in). `local-qwen3-32b` attempted 10/10 but 1/10
(`05-math-formula-rendering`, this benchmark's largest stage at ~27k
estimated prompt tokens) timed out even after the fix below and even
warm-loaded — Qwen3's default "thinking" mode has no local equivalent of the
`reasoning_effort`/`reasoning: {effort: low}` damping the caller already
applies to Groq and OpenRouter, so its hidden reasoning trace on a large
prompt can still exceed a generous single-shot budget. That is a finding
about the candidate, not the harness.

**Harness fix made mid-run.** `scripts/verifier-bake-off.sh` never passed
`--timeout-seconds` to the caller, so every local call ran at the caller's
own 180s default — tuned for cloud latency, not local generation time.
`local-devstral` and `local-qwen3-coder-30b`'s prior attempt (2/10 and
1/10 respectively, per the re-brief) timed out on exactly the larger
stages (`05`, `15c`, `16`) at 130-180s, just short of finishing. Local
candidates are free and wall-clock-only constrained (no request or token
caps), so the fix is a longer local-only timeout
(`AUTOMETTA_BAKEOFF_LOCAL_TIMEOUT_SECONDS`, default 420s, cloud candidates
unchanged) rather than tuning the model or the prompt. That fix is also
what surfaced a real bash-3.2 bug (see below): an unconditional
`"${timeout_args[@]}"` expansion of an empty array crashed every cloud
candidate with "unbound variable" under `set -u`, caught and fixed by
`scripts/verifier-bake-off-route-smoke.sh` failing closed rather than by
inspection — the smoke script did its job.

## Groq: the controlled pair's cloud side is not usable at all

`groq-gpt-oss-120b` and `local-gpt-oss-120b` are the same weights, so any
difference isolates serving from parameters. It isolates nothing here,
because Groq's free tier cannot complete the comparison: its 8,000
tokens/minute ceiling is judged against prompt tokens *plus* requested
`max_tokens` (gotcha 3), and this verifier's prompt is large enough on
most stages that even the caller's floor completion budget (768 tokens)
does not fit. 1 real attempt out of 10 is not "Groq lost the comparison" —
it is "Groq's free tier cannot run this shape of verifier at all," a
capacity fact rather than a quality one. `local-gpt-oss-120b` stands
alone as the measurement for these weights.

## Recommendation

**Trust generally:** none of the seven, without qualification — every
candidate's FAIL recall sits at 77% or worse against a 10-stage sample.
That is worse than "misses one failure in a hundred"; it is "misses roughly
one failure in four even at the best-measured candidate," which is not a
tolerable false-negative rate for a gate that decides whether broken work
merges.

**Trust for mechanical acceptance, with the frontier as backstop on
anything that looks borderline:** `local-gpt-oss-120b` and
`openrouter-nemotron-3-ultra-550b` are tied at 77% (10/13) FAIL recall,
both with reasonable PASS agreement (78% and 72%) and 100%/90% artefact
discipline. Of the two, `local-gpt-oss-120b` is the better default: same
FAIL recall, better artefact discipline, no per-day request cap, $0 with
no unlock decision to make, and it is already card 45's default — this
result backs that choice with measurement rather than overturning it.
`openrouter-nemotron-3-ultra-550b` is the fallback when a stage's
evidence is too large for local wall-clock patience (its 50s mean is far
faster than local-gpt-oss-120b's 93s), or when the local machine is
occupied by a worker and the verifier needs to run on a different
process/host — but every cloud dispatch ships the diff to a third party
(see "Data-sharing constraint" above), so this is conditional on the repo
already being cloud-eligible.

**Do not trust as a primary verifier, at any FAIL rate:** `local-devstral`
(0% FAIL recall — it did not catch a single one of 11 frontier-failed
criteria across 10 stages, despite 96% PASS agreement, i.e. it is a
rubber stamp), `local-qwen3-32b` (8%, one lucky catch), `local-qwen3-coder-30b`
(15%, and its speed — 46s mean, the fastest of the seven — makes the
rubber-stamp failure mode more dangerous, not less, since a fast, cheap,
confidently-wrong verifier is exactly what an unattended overnight loop
would trust by default), and `openrouter-nemotron-3-super-120b` (0%, and
60% artefact discipline on top of that — the weakest candidate measured
on both axes). A verifier that agrees with PASS 95-98% of the time but
almost never catches a real FAIL is optimising for the wrong half of the
rubric: cheap requeues are the acceptable cost (per the card's own
framing), not silent merges of broken work, and these four systematically
buy the wrong one.

**Do not measure further on this free tier:** `groq-gpt-oss-120b`. Not a
quality verdict — a capacity one. Its token ceiling means it cannot run
this verifier's prompt shape at all on most stages; a smaller, terser
verifier prompt might change that, but that is a different card (rubric
compression), not a reason to keep retrying this one.

### `AUTOMETTA_MODEL_CODEX_LOCAL` (card 45)

**Keep `gpt-oss:120b` as the default.** It is the only local candidate that
clears a defensible FAIL-recall bar (77%, tied for best of all seven
measured), and it is already the incumbent. `qwen3-coder:30b` and
`devstral` are faster but both effectively rubber-stamp (15% and 0% FAIL
recall) — a bad trade for a verifier role, whatever their merit as coding
tunes for worker dispatch. `qwen3:32b`'s general (non-coder) tune does not
help either (8%): the coding-tune-against-general-tune question the
manifest note asked for resolves as "neither Qwen3 variant is close to
gpt-oss-120b as a verifier," not as a size or tuning-family effect. Mean
wall clock (93.0s) is a real cost against `qwen3-coder:30b`'s 45.8s, but
it is a cost worth paying: a verifier that is twice as slow and actually
catches failures beats one that is fast and does not.

### The one-time $10 OpenRouter unlock

**Not worth taking for this purpose.** The unlock buys headroom (50 to
1,000 requests/day) on `openrouter-nemotron-3-ultra-550b`, the one cloud
candidate that measures as trustworthy (77% FAIL recall, tied with
local-gpt-oss-120b). But the free local candidate already matches its
FAIL recall at $0, with no daily cap and no third-party data exposure —
the two conditions under which the cloud candidate would actually get
reached for (local machine busy, or evidence too large for local
wall-clock patience) are occasional, not a volume problem the request cap
would bind on. Revisit if a future card finds the opposite — a workload
where cloud verification runs routinely rather than as a local fallback —
but nothing measured here creates that workload.

## Offline smoke scripts

`scripts/verifier-bake-off-route-smoke.sh` passes with no live credentials
or network (stubbed `op-fetch`) — it caught the bash-3.2 empty-array
regression above the moment the local-timeout fix landed, before this doc
was written, which is the point of it being offline and fast. Every other
offline smoke script in `scripts/` (`advisor-order-smoke.sh`,
`alerts-table-smoke.sh`, `budget-cap-smoke.sh`, `cost-log-smoke.sh`,
`effort-flags-smoke.sh`, `idle-tick-smoke.sh`, `local-route-smoke.sh`,
`state-branch-smoke.sh`, `state-writable-smoke.sh`,
`superseded-status-smoke.sh`, `ticker-fit-smoke.sh`,
`ticker-spend-smoke.sh`, `usage-error-smoke.sh`) was re-run this attempt
and passes; none touch this card's changes but all were checked rather
than assumed. `sdk-cache-smoke.sh` requires live Anthropic credentials and
was not run, per the card's own instruction.
