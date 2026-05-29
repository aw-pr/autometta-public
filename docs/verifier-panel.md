# Verifier panel

An optional N=3 verification mode where three heterogeneous model instances evaluate a stage independently and the majority vote becomes the official verdict.

## When to use it

Panel mode costs roughly three times the normal verifier budget. Use it selectively:

- High-stakes stages: sandbox boundary changes, auth refactors, changes to the dispatch contract itself.
- Any stage where a single verifier failure-to-agree has repeatedly blocked good work, or single verifier approval has repeatedly passed bad work.
- Stages where you suspect rubric ambiguity and want independent readings.

Do not use it for routine stages. The cost implication is real.

## How to enable it

Set `Verifier panel: true` in the stage card's Metadata section, or export `AUTOMETTA_VERIFIER_PANEL=1` before calling `spawn-verifier.sh`. The env var overrides the card.

When panel mode is on, `spawn-verifier.sh` delegates immediately to `spawn-verifier-panel.sh`. The single-verifier path is not exercised.

## Panel composition (v1, fixed)

| Panellist | Route | Identity |
|---|---|---|
| 0 | Claude Opus 4.8 via SDK | `Claude Opus 4.8 <claude-opus-4-8@local>` |
| 1 | Claude Sonnet 4.6 via SDK | `Claude Sonnet 4.6 <claude-sonnet-4-6@local>` |
| 2 | Codex GPT-5.3 via `codex exec` | `Codex GPT-5.3 <codex-gpt-5-3@local>` |

The two Claude panellists require `auth.claude.mode: api` in `.autometta.local.yaml`. If the API key is not available, the panel fails closed with an explicit error — it does not fall back to subscription or to a single verifier.

## Quorum rule

Quorum is 2 of 3. A panellist that crashes or times out without writing its artefact counts as no-vote (not a FAIL vote). If fewer than 2 panellists return artefacts, the stage stalls with status `verifier_panel_no_quorum` and the operator must intervene.

| Votes | Result |
|---|---|
| 3 PASS, 0 FAIL | PASS |
| 2 PASS, 1 FAIL | PASS |
| 1 PASS, 2 FAIL | FAIL |
| 0 PASS, 3 FAIL | FAIL |
| 2 PASS, 0 FAIL (1 crash) | PASS — quorum met, strict majority |
| 1 PASS, 1 FAIL (1 crash) | stall — quorum met but no majority (tie with crash) |
| 1 PASS, 0 FAIL (2 crashes) | stall — quorum not met |

## Synthesised artefact

The canonical artefact at `state/verifiers/<stage-id>.json` is the synthesised result, not any individual panellist's output. It validates against `schemas/verifier-panel.json`, which extends `schemas/verifier.json` with:

- `panellists`: array of three entries, one per panellist. Each has `id`, `identity`, `artefact_path` (null if crashed), and `overall` (null if crashed).
- `quorum`: `{required, achieved}` counts.

Individual panellist artefacts are preserved at `state/verifiers/<stage-id>.panel/{opus,sonnet,codex}.json` for audit.

## Reading a split vote

A synthesised artefact with a PASS majority may still contain a failing panellist. Read the per-criterion findings in the minority artefact to understand what it flagged. If the minority finding names a real defect the majority missed, raise it with the orchestrator rather than treating the majority result as dispositive.

## Cost

The budget declared in the stage card under `Verifier wall-clock` is treated as per-panellist. Total panel cost is roughly:

- Three parallel API calls at the budget rate
- Zero extra cost for synthesis (local jq aggregation, no LLM call)
- Token cost is roughly 3x a single-verifier run of the same stage

The cost log records each panellist's tokens separately under their individual log files (`state/logs/<stage-id>-panel-{0,1,2}.log`). The synthesis step is logged with zero tokens.

## Re-running a panel without mutating state

```sh
autometta panel <stage-id>
```

This re-dispatches the full panel and prints the synthesised JSON to stdout. It does not modify `state.yaml` or overwrite the canonical `state/verifiers/<stage-id>.json`. Use it to audit a prior verdict, or to check whether the current rubric agrees with the original result.
