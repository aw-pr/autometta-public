# Stage card 178: Report card and batch budget headroom during preparation

## Metadata

- **Authored:** 2026-11-18
- **Orchestrator:** GPT-6.1 Sol <gpt-6-1-sol@local>
- **Worker:** GPT-6.2 Astra <gpt-6-2-astra@local>
- **Verifier:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Base branch:** dev
- **Run branch:** autometta/178-readiness-headroom
- **Proposal:** P-20261115-0859
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Recovery attempts:** 3
- **Recovery attempt:** 1
- **Dispatch:** serial
- **Path claims:** scripts/readiness-headroom.sh, scripts/budget.sh, skills/autometta-card-review/SKILL.md, skills/autometta-run-design/SKILL.md
- **Pairing rationale:** Premium Codex worker and independent Claude verifier as approved for this harness batch. The worker must reconcile existing callers and archived formats. Verification requires judgement about the evidence from the normal entry points. Run one card at a time because the changes affect shared harness behaviour.
- **Open decisions:** none
- **Cold read:** Claude Sonnet, pooled read-only review on 2026-11-18. Findings and resolutions below.

## Surfacing concern

A card estimated at 700k tokens ran against a 650k resting cap. Its worker and verifier used 776k. The readiness screen did not show the shortfall.

## Objective

Give card review and run design a read-only comparison of the card estimate, batch estimate and retry allowance against the effective remaining token budget.

## Inputs

- `scripts/budget.sh`
- `skills/autometta-card-review/SKILL.md`
- `skills/autometta-run-design/SKILL.md`
- `scripts/readiness-headroom-contract-smoke.sh`

## Deliverables

1. `scripts/readiness-headroom.sh` Emit the read-only JSON comparison as a preparation entry point.
2. `scripts/budget.sh` Share effective-cap precedence with the advisory reader where needed, preserving runtime expiry handling.
3. `skills/autometta-card-review/SKILL.md` Require a per-card comparison before queue review.
4. `skills/autometta-run-design/SKILL.md` Require a batch and retry comparison and give a worked example.

## Constraints

Keep the existing frozen tests and digests intact. Use temporary fixtures for acceptance. The worker writes its envelope and the verifier writes an independent verdict with observed results for each criterion.

## Acceptance criteria

1. Provide scripts/readiness-headroom.sh REPO CARD BATCH RETRY. Inputs are nonnegative integer token estimates. BATCH includes CARD; reject inconsistent inputs. RETRY is additional estimated demand from retries. JSON fields cap, spent, headroom, card_shortfall, batch_shortfall and with_retry_shortfall report integer tokens. Each shortfall is at least zero. The calling chat reports any shortfall before queue review.
2. Follow the existing drain scope and expiry, repo cap and host default order. Compare estimates with remaining headroom after recorded window spend. Report an unreadable or missing spend as unknown with nonzero exit. Do not modify budgets, drain state, queues or dispatch admission, including when encountering an expired drain. The read-only path must agree with the actual resolver on the effective cap.
3. Run the frozen arithmetic and drain fixtures. Both preparation skills must name the helper and distinguish estimates, recorded spend, retry allowance and operator authority to change caps. Include a worked example in the skill guidance. Independently exercise host fallback, a drain scoped to another repo, over-cap spend, malformed input and an exactly fitting batch.

Both seats run `bash scripts/readiness-headroom-contract-smoke.sh`. The judging seat is the independent Claude verifier. Run these regression commands separately from the repository root:

- `env -u AUTOMETTA_HOME bash scripts/budget-cap-smoke.sh`

## Review decisions

RETRY adds to estimated demand. BATCH already includes CARD. For this report headroom is max(0, effective cap minus recorded spend). Report shortfall separately at CARD, BATCH, and BATCH + RETRY. A valid shortfall is an informational success. Invalid or unavailable inputs exit nonzero with an explanatory diagnostic. Resolve scoped active drain, repo, host default and the existing floor in that order. Share cap resolution where practical, keeping the existing runtime expiry cleanup and making this advisory read side-effect free. The oracle covers shortfall, exact fit, scoped and expired drains, host fallback, over-cap spend and invalid input.

The cap regression passed with its own disposable legacy controller home. Run it with AUTOMETTA_HOME unset so that its fixture owns both the cap and the tick log.

## Contract test

- **Test file:** `scripts/readiness-headroom-contract-smoke.sh`
- **Assertions digest:** `sha256:cd5c2ecf8d5b5d197d21d98f357e478413a1568bd43ab95f03ce77c8458b9519`
- **Oracle proof:** Base `d93e651` is red. There is no readiness report entry point on the base. The fixture directs a future implementation through a shortfall, an active scoped drain, an expired drain and missing spend. Base cannot provide the readiness report. A temporary arithmetic reference and two fixture skill references passed the complete frozen fixture with the hand-computed expected amounts. The acceptance check must still pass through the shipped entry point and actual guides.

## Out of scope

Fleet dispatch, provider spend authorisation, publishing, policy changes and alterations to earlier contracts.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 30 minutes
- **Spend basis:** The nine nonzero November worker rows and nine verifier rows in the repo cost log had medians of 975,595 and 972,937 cache-inclusive tokens. Allow 1.95M for one pair, including about 1.80M cached input by the sum of role medians. A diagnosed retry is another pair. The batch estimate is 7.79M first-pass plus 9.90M pooled outlier allowance (sum of role p95s). Four separate retries would add about 7.79M. Preparation checkpoint is 195k cache-inclusive per card, including the shared cold read. The wall-clock ceilings allow diagnostic replay and exceed the November role p95s of 17m06s and 11m12s. The pooled cold read used 113,248 cache-inclusive tokens (66,252 cache reads, 43,407 cache writes). At the final readiness check the shared Codex preparation turn had reached 11.20M cache-inclusive tokens, including 11.09M cached input. This exceeded the 780k batch checkpoint. Stop additional preparation experiments; any execution and its spend need the separate queue decision.

## Dispatch envelope

Write the worker evidence to `state/envelopes/178-readiness-headroom.json`. The verifier records commands, exit codes, the observed fixture values and any missing evidence in `state/verifiers/178-readiness-headroom.json`; missing evidence prevents overall PASS. Keep the verifier evidence independent of the worker's interpretation.

## Family-specific notes

Run offline fixtures locally. A missing or skipped required result prevents acceptance.
