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

When panel mode is on, `spawn-verifier.sh` delegates immediately to `spawn-verifier-panel.sh`, passing the stage's run worktree as `--work-dir`. The single-verifier path is not exercised.

## What the panel verifies

Every panellist verifies the stage's run worktree, the tree that carries the worker's diff, not the subscriber's main checkout. The two Claude SDK panellists run from the run worktree, and the Codex panellist runs `codex exec -C <run worktree>` with the same `--add-dir` grant on the subscriber's `state/` that a single Codex verifier gets, so it can still write its artefact there. Artefacts and logs stay under the subscriber's `state/` whatever the tree.

## Under the tick

The tick dispatches a panel like any verifier, and the panel runs in the background:

1. In the foreground, inside the tick's call and under its repo lock, `spawn-verifier-panel.sh` runs every preflight: both auth routes, the API key the Claude panellists need, `op-fetch`, `verify-sdk.py` and, on a Codex API route, the sibling `CODEX_HOME`. A genuine configuration fault exits non-zero here, before anything starts, and the tick treats it as a dispatch-configuration fault.
2. It then starts the panel as a background process in its own process group, disowned, records that process as the stage's `verifier_pid` with `verifier_artefact: state/verifiers/<stage-id>.json`, registers it in `state/active-agents/` with the run worktree as its working directory, and exits 0. The tick fire returns within seconds rather than waiting out the panellists.
3. The background panel dispatches the three panellists, waits for them up to the deadline, and writes the synthesis to `state/verifiers/<stage-id>.json`. It writes only its own files: the panellist artefacts and logs, the synthesis artefact and the synthesis log. It never writes `state.yaml` or `budget.json`; both belong to the tick.
4. A later tick fire finds the synthesis with the panel process gone and consumes it exactly as it consumes a single verifier's artefact. A PASS lands the run worktree; a FAIL leaves the stage at `verifier_failed` for the operator. A panel verdict never halts the repo as a dispatch-configuration fault, though a FAIL still counts towards the repo's consecutive-failure cap, as a single verifier's FAIL does.

The background panel polls for its panellists every `AUTOMETTA_PANEL_POLL_INTERVAL` seconds (whole seconds, default 10; any other value falls back to 10).

If the card declares `Verifier effort`, the panel applies it to every member. The two Claude SDK calls receive `--effort <level>`, and the Codex CLI call receives `-c model_reasoning_effort=<level>`, using the same argv helper as single-verifier dispatch. If the field is omitted, every member keeps its transport default.

## Panel composition (v1, fixed)

| Panellist | Route | Identity recorded |
|---|---|---|
| 0 | Claude Opus via SDK, `--model $AUTOMETTA_MODEL_OPUS` (currently `claude-opus-5-5`) | `Claude Opus 5 <claude-opus-5@local>` (a fixed label in `spawn-verifier-panel.sh`) |
| 1 | Claude Sonnet via SDK, `--model $AUTOMETTA_MODEL_SONNET` (currently `claude-sonnet-5-5`) | `Claude Sonnet 5.5 <claude-sonnet-5-5@local>` |
| 2 | Codex via `codex exec --model $AUTOMETTA_MODEL_CODEX` (currently `gpt-6.1-sol`) | `agent-whoami --model` for that model, currently `GPT-6.1 Sol <gpt-6-1-sol@local>` |

The model ids come from `scripts/models.sh`, so a model bump there moves the panel with it.

Both families resolve on their per-role verifier routes (`auth-route.sh <family> --role verifier`), so `auth.<family>.verifier.mode` and `AUTOMETTA_<FAMILY>_MODE_VERIFIER` apply ahead of the family-wide keys. The two Claude panellists require the Claude verifier route in api mode (for example `auth.claude.verifier.mode: api` in `.autometta.local.yaml`). If the API key is not available, the panel fails closed with an explicit error; it does not fall back to subscription or to a single verifier.

## Quorum rule

Quorum is 2 of 3. A panellist that crashes, misses the deadline or writes an unreadable artefact counts as no-vote (not a FAIL vote). PASS needs quorum and a strict PASS majority. Anything else is written as a FAIL synthesis with the real `quorum` counts, and its `additional_findings` opens with the reason: `[Panel synthesis — majority PASS]`, `[Panel synthesis — majority FAIL]`, `[Panel synthesis — no quorum]` or `[Panel synthesis — tie]`. The panel always writes a synthesis, so under the tick no quorum and a tie stop the stage at `verifier_failed` for the operator, like any FAIL.

| Votes | Result |
|---|---|
| 3 PASS, 0 FAIL | PASS |
| 2 PASS, 1 FAIL | PASS |
| 1 PASS, 2 FAIL | FAIL |
| 0 PASS, 3 FAIL | FAIL |
| 2 PASS, 0 FAIL (1 crash) | PASS: quorum met, strict majority |
| 1 PASS, 1 FAIL (1 crash) | FAIL: quorum met but a tie |
| 1 PASS, 0 FAIL (2 crashes) | FAIL: no quorum |

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

Each panellist's usage stays in its own log (`state/logs/<stage-id>-panel-{0,1,2}.log`). When the background panel finishes, it writes their sum as one `Total tokens:` line in the synthesis log, `state/logs/<stage-id>-verifier.log`; a panellist whose log reports no usage is left out of the sum and named in that log. The panel itself charges nothing. The tick records the sum once, under its repo lock, when it consumes the synthesis, in the three places a verifier's spend goes: `budget.json` `tokens_spent`, the stage's `verifier_tokens` snapshot and the cost-log verifier row. For a panel artefact (one with `panellists`) all three read the synthesis log rather than a session transcript, because the Codex panellist's transcript in the run worktree would otherwise be charged alone.

## Re-running a panel without mutating state

```sh
autometta panel <stage-id>
```

This re-dispatches the full panel synchronously, in the foreground, and prints the synthesised JSON to stdout. It exits 0 for PASS, 1 for a FAIL majority and 2 for no quorum or a tie. It does not modify `state.yaml` or `budget.json` or overwrite the canonical `state/verifiers/<stage-id>.json`; the panellist artefacts go to a temp dir. Use it to audit a prior verdict, or to check whether the current rubric agrees with the original result.
