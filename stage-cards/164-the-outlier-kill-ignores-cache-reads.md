# Stage card 164: the outlier kill ignores cache reads

## Metadata

- **Authored:** 2026-10-23
- **Orchestrator:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Worker:** GPT-6.1 Sol <gpt-6-1-sol@local>
- **Verifier:** Claude Sonnet 5.5 <claude-sonnet-5-5@local>
- **Base branch:** dev
- **Run branch:** autometta/164-the-outlier-kill-ignores-cache-reads
- **Worker effort:** high
- **Verifier effort:** medium
- **Verifier panel:** false
- **Dispatch:** serial
- **Pairing rationale:** a narrow change to the heartbeat's live-usage loop and embedded python, smoke-testable offline: Sol writes it on the Codex window (operator is biasing to OpenAI this week) and Sonnet verifies cross-family, the pairing that landed 161 and 162a on attempt 1. The heartbeat runs on every fleet tick, so it dispatches serially.
- **Open decisions:** none
- **Cold read:** pending; run a Codex read-only cold read before queueing (`autometta-card-review` section 3).

## Surfacing concern

The heartbeat's token-outlier kill compares a live dispatch's `input + cached + output` tokens against the recent median of `total_tokens` for its role (`scripts/heartbeat.sh`, `live_total` and the `comparable_by_role` baseline). Cache reads dominate both numbers and vary mostly with context width and turn count, not with runaway spend, so a wide card trips the kill while working normally.

Evidence: on 2026-10-23 card 162's first worker attempt was killed as a token outlier at 13,724,575 total tokens against a worker median of about 0.84M (16x). Of that, 13,438,000 was cached input; its uncached spend was 286,575 (236,156 input plus 50,419 output), about 4x the autometta worker median of uncached tokens (70,874 over the last ten recorded rows). Under an uncached measure it would have been left to finish. Promo-flow shows the same skew: its worker median is 9.9M total but 0.24M uncached.

For the 2026-10-23 promo-flow production run the operator removed the cache-counting kill by hand: the run's local monitor runs the heartbeat observe-only and applies a 15x uncached kill itself. This card makes that the default so no run needs a local workaround.

## Objective

The heartbeat's token-outlier warning and kill judge a live dispatch by its uncached tokens (input plus output) against the role median of uncached tokens from the cost log, so cache reads alone never warn or kill a dispatch.

## Inputs (read these in your own context)

- `scripts/heartbeat.sh`
- `scripts/budget.sh` (`budget_parse_dispatch_tokens_from_transcript` returns `input cached output`)
- `scripts/outlier-warning-smoke.sh`
- `docs/observability.md` (token-outlier section)
- `docs/cost-log.md` (Live outlier baseline)

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/heartbeat.sh`: the live usage map carries uncached tokens (input plus output) per pid alongside the total; the baseline is the median of `input_tokens + output_tokens` over the same recent window of `recorded` rows per role; the warning and kill multiples apply to the uncached pair. Rows without the split (`total_only`) are excluded from the uncached baseline. The heartbeat report records both numbers (`live_uncached_tokens`, `baseline_median_uncached_tokens`) and which measure fired.
2. A total-tokens backstop (operator decision 2026-10-23): the existing total measure (input plus cached plus output against the role median of `total_tokens`) stays as a second, independent kill at `AUTOMETTA_OUTLIER_TOTAL_KILL_MULTIPLE`, default 40, 0 disables, so a dispatch that loops on cache reads alone is still stopped. Either measure reaching its kill multiple kills the dispatch. Documented beside `AUTOMETTA_OUTLIER_KILL_MULTIPLE`.
3. A new offline smoke, `scripts/outlier-uncached-smoke.sh`, plus any updates the existing `outlier-warning-smoke.sh` needs to stay green.
4. `docs/observability.md` and `docs/cost-log.md` describe the uncached measure, the backstop and the variables.

## Constraints

- No change to how spend is accounted in `state/budget.json` or the cost log; only the outlier judgement changes. The 1B-style repo token caps still count every token.
- Existing variables keep their names and defaults: `AUTOMETTA_OUTLIER_MULTIPLE` (10), `AUTOMETTA_OUTLIER_KILL_MULTIPLE` (15, 0 disables), `AUTOMETTA_OUTLIER_BASELINE_WINDOW`, `AUTOMETTA_OUTLIER_MIN_SAMPLES`.
- The kill mechanics (children first, then the wrapper, worktree left standing, `outcome: killed-token-outlier`) are unchanged.
- Offline only: no network, no live agent, no spend in any smoke.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. **Worker and verifier:** `scripts/outlier-uncached-smoke.sh` exits 0. It replays card 162's attempt (live 236,156 input, 13,438,000 cached, 50,419 output against a baseline of ten rows whose uncached median is about 70K and total median about 0.84M) and asserts no kill and no warning; and replays a dispatch whose uncached tokens reach 15x the uncached median with little cache and asserts the kill. Red on the clean base (the first case is killed).
2. **Worker and verifier:** `scripts/outlier-warning-smoke.sh` keeps its current result on the base (it is red there for an unrelated pre-existing reason; record its base output and show no new failure).
3. **Worker and verifier:** the new smoke also asserts the backstop: a dispatch with uncached tokens under 15x but total tokens at 40x the total median is killed, and with `AUTOMETTA_OUTLIER_TOTAL_KILL_MULTIPLE=0` the same dispatch is not.
4. **Verifier:** `bash -n scripts/heartbeat.sh` and `shellcheck` on the changed scripts report nothing new.

## Contract test

- **Test file:** pending; `scripts/outlier-uncached-smoke.sh`, to be frozen through `autometta-oracle`.
- **Assertions digest:** pending
- **Oracle proof:** pending

## Out of scope

- Per-card token allowances.
- The fleet LaunchAgent's `AUTOMETTA_OUTLIER_KILL_MULTIPLE=40`, set by hand as a workaround for the cache-heavy measure. Once this lands it would mean 40x uncached; the operator resets it to the default afterwards, outside this card.
- The quota window reserve and curfew.
- Card 163's durable kill record (`state/kills/<stage>.json`); this card only changes what triggers a kill.

## Budget

- **Worker wall-clock:** 45 minutes
- **Verifier wall-clock:** 25 minutes
- **Spend basis:** comparable to 162a (about 0.7M tokens across both roles).

## Dispatch envelope

Return the standard envelope: status, the smoke outputs for criteria 1 to 3, the base outputs recorded for comparison, and the list of changed files.

## Family-specific notes

Codex transcripts report `cached_input_tokens` inside the input total on some CLI versions; confirm `budget_parse_codex_tokens_from_transcript` returns input exclusive of cache before subtracting anything, and say which in the envelope.
