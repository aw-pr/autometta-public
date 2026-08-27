<!--
Stage card 04: phat-controller design. Authored by filling in templates/stage-card.md; this is the first stage in the self-host plan to dogfood the template literally rather than match its shape freehand. Any awkwardness in the fill-in is flagged below under "Template defects noticed". -->

# Stage card 04: phat-controller design and schemas

## Metadata

- **Authored:** 2026-05-21
- **Orchestrator:** Claude Opus 4.7 (main session)
- **Worker:** Claude Opus 4.7 (main session, T1 work, no sub-agent per the agent-orchestrator skill rule "never spawn a T0/T1 sub-agent")
- **Verifier:** Codex GPT-5.3 (`codex exec --sandbox read-only`, stdin from /dev/null)
- **Pairing rationale:** Stage 4 is T1 (failure cost is high; this design gates every pass-2 artefact). The skill's tier mapping says T1 work stays in the main reasoning session. The verifier remains cross-family per the validated belief at `memory/project-cross-family-verification-validated.md`.

## Objective

Produce the pass-2 design doc plus the two JSON schemas that the pass-2 loop will use as the contract between cron ticks. The deliverables make every decision banked in `memory/decision-*.md` concrete: where state lives, what a tick reads and writes, how the budget is enforced, how the verifier handoff names its artefact, how identity drift is handled, and how the single-tick multi-repo subscribe model is wired.

This stage produces design only. No executable code, no scripts. Stage 5 implements; this stage is the brief for stage 5.

## Inputs (read these in your own context)

- `docs/philosophy.md`
- `docs/dispatch-contract.md`
- `docs/lessons.md`
- `docs/verification.md`
- `memory/INDEX.md` and every `memory/decision-*.md` it points to
- `templates/stage-card.md`
- `templates/worker-prompt.md`

Do not read anything else; keep your context lean.

## Deliverables

All files relative to repo root. All three must be created.

1. `docs/phat-controller.md`: the pass-2 design document. Sections must cover (a) what a tick is and what one tick does end-to-end, (b) the state file `state.yaml`: location, schema reference, lifecycle, who writes it, atomicity guarantees, (c) the budget file `budget.json`: schema reference, the failure-budget-via-clock-tick decision from memory, (d) the verifier handoff artefact `verifiers/<stage-id>.json`: naming per the verifier-handoff decision in memory, fields, (e) identity resolution at tick time: how `agent-orchestrator` skill maintains family equivalents per the identity-via-orchestrator-skill decision, (f) the single-tick multi-repo subscribe model: how N repos share one cron tick, what "subscribing" means in filesystem terms, (g) failure modes and stall-detection: what does a stalled tick look like, when does the loop self-halt, (h) explicit interaction with the pass-1 dispatch contract: every tick instantiates the dispatch contract for the worker it spawns, so the seven steps continue to apply per spawned stage. The design must not over-specify; this is a brief for stage-5 implementation, not the implementation itself.
2. `schemas/state.yaml.json`: JSON Schema (draft 2020-12) describing the legal contents of `state.yaml`. Top-level fields at minimum: `version`, `repo`, `current_stage`, `stages` (array of stage records with id, status, worker, verifier, started_at, completed_at, commit), `last_tick_at`, `tick_count`, `clock_tick_budget_remaining`. Use additionalProperties: false at the top level so unknown keys fail validation.
3. `schemas/budget.json`: JSON Schema (draft 2020-12) describing the legal contents of `budget.json`. Fields at minimum: `version`, `token_cap_total`, `tokens_spent`, `wall_clock_cap_seconds`, `wall_clock_elapsed_seconds`, `clock_tick_cap`, `clock_ticks_used`, `consecutive_failure_cap`, `consecutive_failures`. Use additionalProperties: false.

## Constraints

- **Language:** British English, no em dashes anywhere, no AI-tell vocabulary (`delve`, `leverage`, `seamless`, `robust`, `comprehensive`, `tapestry`, `elegant`, case-insensitive).
- **No hallucinated mechanics.** Every decision in the design must trace back to either (a) an existing memory entry, (b) `docs/philosophy.md`, or (c) `docs/dispatch-contract.md`. If a decision is genuinely new (not anchored), call it out under a "new decisions" subsection at the end of the design doc and bank a corresponding `memory/decision-*.md` entry as part of this stage.
- **No code.** The design doc references file paths and field names; it does not include shell scripts, Python, YAML examples that pretend to be working code. Schema files ARE the only structured artefacts; they are declarative, not executable.
- **No new external dependencies.** The design must work with bash, `jq`, `git`, `codex`, `claude`, and the existing harness. No new daemons, no new package managers, no Docker.
- **Schemas must validate themselves.** Use draft 2020-12. Set `$schema` correctly. Set `$id` to a stable URL pattern (use `https://autometta.local/schemas/<name>.json` since the repo has no canonical hosting yet).
- **Future scope is explicit.** Anything not yet decidable must be parked under an explicit "Future scope" heading rather than implied or hand-waved.
- **Stage card exemption.** Per `memory/feedback-acceptance-criterion-stage-card-exemption.md`, the stage card at `examples/self-host/04-phat-controller-design.md` is authored by the orchestrator and is exempt from criterion 7 below.

## Acceptance criteria

The verifier checks each independently. Failure of any one is a failure of the stage.

1. **Three files exist** at the named paths and are non-empty.
2. **Design completeness:** `docs/phat-controller.md` contains a dedicated section for each of the eight topics (a) to (h) listed in Deliverables item 1. Section headings make the mapping obvious.
3. **Schemas validate as JSON Schema draft 2020-12.** Both schema files parse as valid JSON, have a `$schema` field set to draft 2020-12, an `$id` field, and `additionalProperties: false` at the top level.
4. **Required fields present.** `schemas/state.yaml.json` covers at minimum the field list named in Deliverables item 2. `schemas/budget.json` covers at minimum the field list named in Deliverables item 3.
5. **Style audit:** `grep -c '-' docs/phat-controller.md` returns 0. JSON files are exempt from the em-dash check (JSON has no prose). Banned-vocabulary scan on `docs/phat-controller.md` returns no matches.
6. **Anchored decisions:** every decision in the design doc is either traceable to a memory entry, `docs/philosophy.md`, or `docs/dispatch-contract.md`, OR called out under a "new decisions" subsection AND backed by a corresponding `memory/decision-*.md` entry committed in this same stage.
7. **No files outside the deliverables set are modified by the worker** (the orchestrator-authored stage card is exempt; new `memory/decision-*.md` entries are part of the deliverables set if any are created under the "anchored decisions" rule).

## Out of scope

- Implementation. `scripts/tick.sh`, `scripts/spawn-worker.sh`, `scripts/spawn-verifier.sh`, `scripts/budget.sh` are stage 5.
- Execution. Nothing in stage 4 runs the loop.
- Edits to `README.md`, `CLAUDE.md`, `AGENTS.md`, `docs/philosophy.md`, `~/.claude/*` (per the overnight autonomy contract in `examples/self-host/PLAN.md`).
- Edits to `templates/` unless a template defect is discovered while filling this card in.
- Edits to `examples/fractals-stage-cards/`.

## Budget

- **Worker wall-clock:** 25 minutes (T1 design, three deliverables, two of which are schemas).
- **Verifier wall-clock:** 10 minutes (structural checks plus schema validation).

## Verifier handoff

When all three files are written, the orchestrator runs the pre-verifier style scan plus a `jq empty` validity check on each schema. If either fails, fix in place and re-scan before handing to the verifier. The verifier runs as `codex exec --sandbox read-only` with the verifier prompt at `/tmp/autometta-stage-04-verify-prompt.txt` (created at dispatch time).

## Family-specific notes

- The worker is the main orchestrator session (Claude Opus 4.7). No separate dispatch mechanism; the orchestrator writes the three files directly using the Write tool and reads no inputs beyond the list above.
- The verifier is `codex exec --sandbox read-only "$(cat /tmp/autometta-stage-04-verify-prompt.txt)" </dev/null > /tmp/codex-stage-04.log 2>&1`. The stdin redirect mitigates gotcha 1.

## Template defects noticed (filled in during this dogfooding pass)

- The template has no slot for "what tier is this stage" beyond the worker identity line. For T1 stages where the orchestrator IS the worker, the template's "Worker" field reads awkwardly; "Worker: Claude Opus 4.7 (main session)" is unambiguous but tells the reader nothing about why this is not a sub-agent dispatch. Resolution: kept the awkward fill-in here and noted it; a template amendment is worth considering at stage 5 prep but is out of scope for stage 4.
- The template's "Family-specific notes" placeholder collapses two related but distinct concerns: harness-specific dispatch mechanics (which I want a separate slot for) and family-specific lessons that should propagate forward. For stage 4 the placeholder works because they coincide, but if a future stage has only one of the two, the placeholder will be a forcing function.
- No defects worth fixing immediately.
