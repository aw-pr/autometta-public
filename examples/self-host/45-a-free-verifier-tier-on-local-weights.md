# Stage card 45-a-free-verifier-tier-on-local-weights: the codex family learns a local route so a blown API budget does not stop verification

## Metadata

- **Authored:** 2026-08-23
- **Orchestrator:** Claude Opus 5 <claude-opus-5@local>
- **Worker:** Codex GPT-5.6 Terra <codex-gpt-5-6-terra@local>
- **Verifier:** Claude Opus 5 <claude-opus-5@local>
- **Worker effort:** high
- **Verifier effort:** medium
- **Verifier panel:** false
- **Worker wall-clock:** 90 minutes
- **Verifier wall-clock:** 45 minutes
- **Pairing rationale:** auth-route and spawn plumbing with a fail-closed
  requirement, which is exactly the surface where a plausible-looking wrong
  branch silently redirects billing (gotcha 8). Claude verifies because the
  deliverable is codex-side and cross-family review is the default; the
  verifier must actually run the local dispatch, not read it.

## Objective

The operator has exhausted the week's Codex API budget. Every stage whose
card names a Codex verifier is now undispatchable without topping up, and
the alternative of verifying Claude workers with Claude verifiers surrenders
cross-family verification, which is a load-bearing belief, not a preference.

Add a third billing route to the codex family: `local`, running on Ollama
weights through the same `codex` CLI. Zero marginal cost, no rate limits, no
provider to exhaust.

## Why this route and not the others (investigated 2026-08-23)

Three candidates were investigated on the operating machine (M2 Max, 96GB):

1. **`codex --oss` against local Ollama — chosen.** Proven end to end
   during the investigation: `codex exec --oss --local-provider=ollama -m
   gpt-oss:120b --sandbox read-only` completed a probe in 66 seconds
   including model load, produced a sensible reply, and printed the exact
   two-line `tokens used` / `14,651` trailer the budget parser already
   consumes. The machine already holds `gpt-oss:120b` (65GB, fits in 96GB
   unified memory) plus `qwen3-coder:30b` and `llama3.3:70b` under Ollama
   0.32. Because it is the same `codex` binary, the sandbox boundary, the
   log format, the stdin gotcha and the whole codex spawn path carry over
   unchanged. The role boundary survives: the verifier still runs outside
   the worker sandbox.
2. **OpenRouter `:free` models (DeepSeek R1, Qwen3 Coder 480B, rotating
   set of ~two dozen) — viable fallback, not first.** Free tier is 20
   requests/minute and 50 requests/day until $10 of credits have ever been
   bought, then 1,000/day. An agentic verifier burns several requests per
   criterion, so one thorough verification can eat a day's free quota, and
   the model list rotates without notice. Codex CLI can reach it as a
   custom `model_providers` entry with `OPENROUTER_API_KEY` through the
   existing op-fetch machinery, so this route costs little to leave
   documented but should not be the default.
3. **Gemini CLI free tier (1,000 requests/day on a Google account) — real
   but out of scope.** It is a genuine third CLI family: new spawn branch,
   new log format for the token parser, new family value in the registry
   and heartbeat. `Gemini Pro` already has a rates row waiting, so the door
   is open, but that is its own card if the local route proves inadequate.

Local weights are a step down in capability from a frontier verifier. That
is priced in: the verifier contract is criterion-by-criterion judgement
against evidence the verifier gathers itself, and a FAIL from a weaker
verifier still blocks the merge, while a PASS is exactly as trustworthy as
the acceptance commands it ran. Prefer the local tier on stages whose
acceptance is mechanical (smoke scripts, `bash -n`, fixture comparisons)
and keep frontier verifiers for judgement-heavy criteria.

## Probe transcript (the feasibility evidence)

```
$ codex exec --oss --local-provider=ollama -m gpt-oss:120b --sandbox read-only \
    --skip-git-repo-check "Reply with exactly: VERIFIER-PROBE-OK, ..." </dev/null
...
VERIFIER-PROBE-OK
I am Codex GPT-5.6 Terra.
tokens used
14,651
   real 1m06s (including 65GB model load)
```

Two findings inside that probe are load-bearing:

- Codex 0.147.0 refuses `--oss` without either `--local-provider` or an
  `oss_provider` key in `config.toml`. Pass the flag explicitly at every
  dispatch; depending on the operator's `config.toml` reintroduces exactly
  the ambient-config coupling gotcha 8 exists to warn about.
- The model cheerfully claimed to be "Codex GPT-5.6 Terra". Identity for
  attribution comes from the card and the ledger, never from asking the
  model, and the cost log must record the local identity or the run bills
  a free dispatch at the Terra rate (see deliverable 5).

## Inputs (read these in your own context)

- `scripts/auth-route.sh` - the route resolver this card extends. Today it
  knows `subscription` and `api`.
- `scripts/spawn-verifier.sh` and `scripts/spawn-worker.sh` - the codex
  dispatch branches, `verifier_family`, and the sibling-CODEX_HOME gate
  that must NOT fire on the local route.
- `scripts/models.sh` - `AUTOMETTA_MODEL_CODEX` and the one-place-to-bump
  rule this card must respect for the local model id.
- `scripts/rates.sh` - `tier_for_identity` falls back to T2, so an
  unrecognised local identity would be costed at $3/M input. The local
  tier must be an explicit $0 row, not a fallback.
- `scripts/budget.sh` - `budget_account_tokens_from_log`; local tokens
  still count against the token cap (the cap bounds attention and wall
  clock, not only money) but at zero cost.
- `~/.claude/rules/mcp-hub-dev-rules.md` - the canonical identity table
  and the rule that `agent-whoami` is its executable form. A new identity
  needs a row there AND a case in `scripts/agent-whoami`, not a literal
  pasted anywhere.
- `docs/setup.md` section 7 and `README.md` "Billing routes".
- `docs/lessons.md` gotchas 1 (stdin) and 8 (auth precedence).

## Deliverables

1. `scripts/auth-route.sh` - `auth.codex.mode: local` accepted (env
   override `AUTOMETTA_CODEX_MODE=local` beats it, as api does today).
   Emits no pairs, like subscription; the dispatch still goes through
   op-fetch so stray provider keys in the parent env are stripped and
   cannot silently rebill a "local" run to the API.
2. `scripts/spawn-verifier.sh` and `scripts/spawn-worker.sh` - when the
   codex route resolves `local`, dispatch as
   `codex exec --oss --local-provider=ollama -m <local-model> ...` with
   the sandbox, prompt, log and disown handling identical to the existing
   codex branch. The sibling-CODEX_HOME requirement must not fire: it
   guards api billing, and demanding it here would fail a route whose
   point is to need no key. Fail closed before spawn if `ollama` is not
   serving or the model is not pulled: a dispatch that dies after model
   negotiation burns a verifier attempt on infrastructure.
3. `scripts/models.sh` - `AUTOMETTA_MODEL_CODEX_LOCAL` (default
   `gpt-oss:120b`), the one place the local model id lives. Effort flags:
   local codex takes the same `-c model_reasoning_effort=` form; confirm
   rather than assume, and drop them silently if the OSS path rejects them
   (a lost effort override must not cost the run, per models.sh's own
   rule).
4. A canonical identity for attribution, e.g.
   `Codex GPT-OSS 120B <codex-gpt-oss-120b@local>`: a row in the mcp-hub
   rules table, a case in `scripts/agent-whoami`, and recognition in
   `verifier_family` (it must resolve to family codex). Do not paste the
   literal into any script; the two sources above are the only homes.
5. `scripts/rates.sh` - a `T5` (or similarly named) tier at `0.0 0.0 0.0`
   that the new identity maps to explicitly. The cost log keeps recording
   real token counts; only the USD estimate is zero.
6. `.autometta.local.yaml` template and `docs/setup.md` - the mode
   documented, with the one-time host setup (`ollama pull gpt-oss:120b`,
   confirm `ollama list`) and the guidance from the objective on which
   stages suit a local verifier.
7. `scripts/local-route-smoke.sh` - new, offline. Asserts route
   resolution (manifest, env override, default unchanged), that the local
   branch builds the right argv without demanding the CODEX_HOME sibling,
   that a missing ollama binary or unpulled model fails closed before
   spawn, and that the new identity resolves family codex and tier-zero
   cost. Must not require ollama to be running: assert against the built
   argv and a stubbed `ollama`, in the style of `effort-flags-smoke.sh`.

## Constraints

- The `local` mode is codex-family only. `auth.claude.mode: local` is
  refused with a clear message; a Claude-family local route would be a
  different CLI and a different card.
- Defaults unchanged: no manifest key, no behaviour change. Subscription
  and api dispatch byte-identical to today.
- Everything still goes through op-fetch. A local run with a stray
  `OPENAI_API_KEY` in the parent env must stay a local run.
- No daemon management. If ollama is not serving, fail closed and say so;
  do not `ollama serve` from a spawn script.
- Cross-family verification stays the default. This card changes what a
  codex verifier costs, not who verifies whom.
- One place per fact: model id in models.sh, identity in the table plus
  agent-whoami, rate in rates.sh. Card 41 and the alert-set lesson in
  card 43 both paid for copies.
- British English, no em dashes.

## Acceptance criteria

1. A repo with `auth.codex.mode: local` dispatches a codex verifier
   through `--oss --local-provider=ollama` with no key fetched, and the
   log ends with the `tokens used` trailer the budget parser consumes.
   Demonstrate with a real one-stage dispatch on the operating machine.
2. `AUTOMETTA_CODEX_MODE=local` overrides an `api` manifest, and the
   sibling-CODEX_HOME check does not fire on the local route.
3. With ollama stopped (or the model absent), the spawn fails closed
   before launching an agent, with a message naming the missing piece;
   nothing is written to `verifier_pid` and no attempt is burned.
4. A local dispatch appears in `state/cost-log.jsonl` with real token
   counts, `cost_usd_est` of 0, and the new identity; `git log` shows the
   commit attributed to that identity via the normal trailer machinery.
5. A subscription-mode and an api-mode fixture dispatch build exactly the
   argv they build today.
6. `scripts/local-route-smoke.sh` passes offline, and every existing
   offline smoke script still passes. `sdk-cache-smoke.sh` requires live
   API credentials and is not run: say so.
7. `bash -n` on every shell file touched.

## Out of scope

- A Gemini or OpenRouter route. Document the OpenRouter option in
  `docs/setup.md` as the investigated fallback (custom `model_providers`
  entry, `OPENROUTER_API_KEY` via op-refs, 20/min and 50-1,000/day free
  caps, rotating model list); implement nothing. Card 46 owns the cloud
  free tiers, with the route-isolation guarantee that a free route names
  only its own op-ref so the paid keys are structurally absent.
- Local workers. The plumbing this card builds will mostly allow it, but
  worker quality on local weights is an experiment for a later card;
  verifiers are the budget relief the operator asked for.
- Model quality evaluation or benchmarking of gpt-oss:120b against
  frontier verifiers beyond the guidance already given.
- Any change to Claude-family routes.
- tick.sh scheduling changes. A local verifier is slower; if 66s of load
  per dispatch proves painful, model keep-alive is an operator setting in
  ollama, not autometta's business.

## Budget

- **Worker wall-clock:** 90 minutes
- **Verifier wall-clock:** 45 minutes

## Notes for the worker

- Read the probe transcript again before writing the spawn branch: the
  `--local-provider` requirement and the `--skip-git-repo-check` need are
  both things the first attempt tripped on. Run worktrees are git repos,
  so the skip flag should be unnecessary in real dispatch; confirm rather
  than carry it.
- gotcha 1 applies unchanged: `codex exec` reads stdin after the prompt
  arg. The probe printed "Reading additional input from stdin..." even
  with `</dev/null`; it proceeded correctly, but keep the redirect.
- The 66s probe included cold model load. Warm dispatches are faster;
  do not size timeouts off the cold number alone, and do not let the
  heartbeat's stall detection treat model-load silence as a dead agent
  (the codex family writes its log incrementally, so log mtime is the
  liveness signal that already handles this).
- If `gpt-oss:120b` proves too slow per verification, `qwen3-coder:30b`
  is already pulled and is the natural second setting of the same knob.
