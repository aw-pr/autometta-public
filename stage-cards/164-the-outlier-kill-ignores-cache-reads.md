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
- **Cold read:** done 2026-10-23, GPT-6.1 Sol read-only; every item is answered below or in the frozen test.

## Surfacing concern

The heartbeat's token-outlier kill compares a live dispatch's `input + cached + output` tokens against the recent median of `total_tokens` for its role (`scripts/heartbeat.sh`, `live_total` and the `comparable_by_role` baseline). Cache reads dominate both numbers and vary mostly with context width and turn count, not with runaway spend, so a wide card trips the kill while working normally.

Evidence: on 2026-10-23 card 162's first worker attempt was killed as a token outlier at 13,724,575 total tokens against a worker median of about 0.84M (16x). Of that, 13,438,000 was cached input; its uncached spend was 286,575 (236,156 input plus 50,419 output), about 4x the autometta worker median of uncached tokens (70,874 over the last ten recorded rows). Under an uncached measure it would have been left to finish. Promo-flow shows the same skew: its worker median is 9.9M total but 0.24M uncached.

For the 2026-10-23 promo-flow production run the operator removed the cache-counting kill by hand: the run's local monitor runs the heartbeat observe-only and applies a 15x uncached kill itself. This card makes that the default so no run needs a local workaround.

## Objective

The heartbeat's token-outlier warning and kill judge a live dispatch by its uncached tokens (input plus output) against the role median of uncached tokens from the cost log, so cache reads alone never warn or kill a dispatch below the total-tokens backstop.

## Inputs (read these in your own context)

- `scripts/heartbeat.sh`
- `scripts/budget.sh` (`budget_parse_dispatch_tokens_from_transcript` returns `input cached output`)
- `scripts/outlier-warning-smoke.sh`
- `docs/observability.md` (token-outlier section)
- `docs/cost-log.md` (Live outlier baseline)

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/heartbeat.sh`: the live usage map carries uncached tokens (input plus output) per pid alongside the total; the baseline is the median of `input_tokens + output_tokens` over the same recent window of `recorded` rows per role; the warning and kill multiples apply to the uncached pair. Rows without integer `input_tokens` and `output_tokens` are excluded from the uncached baseline whatever their `usage_status`; filter first, then take the last `AUTOMETTA_OUTLIER_BASELINE_WINDOW` rows. The heartbeat report records both numbers per entry (`live_uncached_tokens`, `baseline_median_uncached_tokens`) and which measure fired as `token_outlier.measure` (`uncached` or `total`). Where a role has fewer than `AUTOMETTA_OUTLIER_MIN_SAMPLES` rows with the split, judgement falls back to today's total measure at the existing warning and kill multiples, so an older cost log keeps its protection. An uncached median of zero counts as no baseline and falls back the same way. When the uncached kill and the backstop both fire, `measure` is `uncached`.
2. A total-tokens backstop (operator decision 2026-10-23): the existing total measure (input plus cached plus output against the role median of `total_tokens`) stays as a second, independent kill at `AUTOMETTA_OUTLIER_TOTAL_KILL_MULTIPLE`, default 40, 0 disables, so a dispatch that loops on cache reads alone is still stopped. Either measure reaching its kill multiple kills the dispatch. Documented beside `AUTOMETTA_OUTLIER_KILL_MULTIPLE`.
3. The frozen smoke `scripts/outlier-uncached-smoke.sh` passes; `outlier-warning-smoke.sh` gains no new failure (criterion 2). Do not edit either.
4. `docs/observability.md` and `docs/cost-log.md` describe the uncached measure, the backstop and the variables, and the stale prose is corrected: the `scripts/heartbeat.sh` header ("It never kills") and `docs/cost-log.md` ("The comparison is an observation only") both predate the kill.

## Constraints

- No change to how spend is accounted in `state/budget.json` or the cost log; only the outlier judgement changes. The 1B-style repo token caps still count every token.
- Existing variables keep their names and defaults: `AUTOMETTA_OUTLIER_MULTIPLE` (10), `AUTOMETTA_OUTLIER_KILL_MULTIPLE` (15, 0 disables), `AUTOMETTA_OUTLIER_BASELINE_WINDOW`, `AUTOMETTA_OUTLIER_MIN_SAMPLES`.
- The kill mechanics (children first, then the wrapper, worktree left standing, `outcome: killed-token-outlier`) are unchanged.
- Offline only: no network, no live agent, no spend in any smoke.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. **Worker and verifier:** `scripts/outlier-uncached-smoke.sh` exits 0. Its frozen cases: card 162's attempt (236,156 input, 13,438,000 cached, 50,419 output against ten rows with an uncached median of 71,000 and a total median of 840,000) is neither warned nor killed and its report carries the uncached figures; a 16x-uncached dispatch with little cache is killed with `measure: uncached`; `AUTOMETTA_OUTLIER_KILL_MULTIPLE=0` still disables that kill and keeps the warning; the docs name the new variable and the uncached measure; budget accounting is untouched. Base: red, first at the card 162 replay (killed at 16.3x total).
2. **Worker and verifier:** `scripts/outlier-warning-smoke.sh` shows no new failure. Base on 2026-10-23: three pre-existing FAILs (`warning fires during the live third dispatch`, `the watchdog takes no action and the agent remains alive`, both because its 25x fixture predates the 15x kill; and `tick routes heartbeat warning text through its existing logger`). Because the second kills its fixture, the script then dies at its final `wait` under `set -e` (exit 143) before printing a summary. The same three FAILs and exit 143, and nothing new, are acceptable; fixing them is out of scope.
3. **Worker and verifier:** `scripts/outlier-uncached-smoke.sh` also asserts the backstop and the fallback: a 4.2x-uncached, 41x-total dispatch is killed with `measure: total`; with `AUTOMETTA_OUTLIER_TOTAL_KILL_MULTIPLE=0` it is not; with no split rows, and with four split rows (one under the minimum), a 16x-total dispatch is still killed; `docs/cost-log.md` names the backstop variable. Base: the disabled-backstop case is red (killed at 41x total).
4. **Verifier:** `bash -n scripts/heartbeat.sh` and `shellcheck` on the changed scripts report nothing new.

## Contract test

- **Test file:** scripts/outlier-uncached-smoke.sh
- **Assertions digest:** sha256:1b0b5b85fe8b69b6f34c870515850ba00e4c953ab40a0dad4a3a86e196e6d27f
- **Oracle proof:** red on `dev` at `49516b5`: the card 162 replay is killed (`multiple=16.3x exceeded kill threshold 15.0x`). A throwaway reference in a detached worktree (uncached map and median beside the total ones, measure selection with total fallback, 40x backstop, one line in each doc), re-run after the cold-read additions, passed every assertion and left `outlier-warning-smoke.sh` at its three base failures; it was removed and not committed. Traps for the worker: a kill does not move the entry to `state/recent-agents/` until the next heartbeat pass, so the smoke reads `token_outlier.measure` from `state/heartbeat.json`; Codex transcripts report `input_tokens` inclusive of cache and `budget_parse_codex_tokens_from_transcript` already returns it exclusive, so do not subtract twice.

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
