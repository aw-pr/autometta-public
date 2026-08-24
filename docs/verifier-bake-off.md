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

## Results

<!-- Generated by scripts/verifier-bake-off-score.py — regenerate rather than hand-edit. -->

TODO: filled in once the batch run completes.

## Recommendation

TODO: filled in once the batch run completes.

### `AUTOMETTA_MODEL_CODEX_LOCAL` (card 45)

TODO.

### The one-time $10 OpenRouter unlock

TODO.

## Offline smoke scripts

`scripts/verifier-bake-off-route-smoke.sh` passes with no live credentials
or network (stubbed `op-fetch`). The repo's other offline smoke scripts
(`effort-flags-smoke.sh`, `local-route-smoke.sh`, `budget-cap-smoke.sh`,
and the rest) were unaffected by this card's changes and were re-run to
confirm — see the stage's handoff notes. `sdk-cache-smoke.sh` requires live
Anthropic credentials and was not run, per the card's own instruction.
