# memory/INDEX.md

One line per memory file. Keep entries <=150 chars: `- [Title](file.md): one-line hook`.

<!-- entries below this line -->
- [Sub-agent budget enforcement weak](feedback-subagent-budget-enforcement.md): Task-tool budgets are advisory; tighten scope, don't trust the brief.
- [Style pre-verifier check](feedback-style-constraints-pre-check.md): em-dash and AI-tell scan before the verifier; writers miss their own.
- [Cross-family verification validated](project-cross-family-verification-validated.md): Stage 0: Codex caught style faults Claude missed.
- [Card exempt from outside-files rule](feedback-acceptance-criterion-stage-card-exemption.md): the card lives outside the deliverables dir.
- [Loop name is phat-controller](decision-loop-name-phat-controller.md): Pass-2 loop layer naming decision.
- [Single tick, multi-repo subscribe](decision-single-tick-multi-repo-subscribe.md): One cron tick model, repos subscribe.
- [Identity via orchestrator skill](decision-identity-via-orchestrator-skill.md): Maintain cross-family identity equivalents.
- [Verifier handoff naming](decision-verifier-handoff-naming.md): Handoff artefact name is verifiers.
- [Failure budget via clock ticks](decision-failure-budget-clock-tick.md): Per-repo timeout counts use filesystem state.
- [state/ dir per repo](decision-state-dir-per-repo.md): All per-repo phat-controller state lives in state/ at the repo root.
- [No daemon, subscriber registry](decision-phat-controller-no-daemon-subscriber-registry.md): one-shot per cron fire; subscribers listed by file.
- [Tick implementation parameters](decision-tick-implementation-parameters.md): state branch, `tick.sh --repair`, config.yaml, stall grace 1.5x.
- [Verifier prompt mirrors stage card](feedback-verifier-prompt-mirrors-stage-card.md): Stage 4: enumerate the card's permission rules in the prompt.
- [Stage 5 silent-failure risks](feedback-stage-5-silent-failure-risks.md): yq-abort, checkout -B discards, no stall-by-elapsed-time.
- [Stage card paths must be relative](feedback-stage-card-paths-relative.md): never bake a home path into a card; template and checklist enforce it.
- [init-host macOS-specific stat](feedback-init-script-macos-specific.md): scripts/init-host.sh uses BSD `stat -f`; Linux portability needs a branch.
- [Stage 6 runtime bugs](feedback-stage-6-runtime-bugs.md): first fire surfaced 4 issues; 3 fixed in place, yq required-vs-optional needs a decision.
- [state.yaml leaks home path](feedback-state-yaml-leaks-home-path.md): committed audit trail conflicts with publish-guard; state/ gitignored.
- [tick.sh switches working-dir branch](feedback-tick-switches-working-dir-branch.md): interactive tick leaves the operator on the state branch.
- [Verifier dispatch impoverished](feedback-verifier-dispatch-impoverished.md): spawn-verifier.sh built a one-sentence prompt; use verifier-prompt.md.
- [Tick respawns verifier while worker running](feedback-tick-respawns-verifier-while-worker-running.md): no process-alive check; verifiers stack.
- [Skills layout: orchestrator + autometta-setup](decision-skills-layout-autometta-setup.md): keep the general skill; add autometta-setup.
- [Cost-log and prompt caching](decision-cost-log-and-caching.md): JSONL ledger per role, per-tier rates, OAuth-vs-API caching finding.
- [Fable-as-advisor verifier](decision-advisor-verifier.md): design-only, deferred; SDK-only, opt-in; an addition to cross-family, not a replacement.
- [Agent observability registry](decision-agent-observability-registry.md): active-agents registry, heartbeat watchdog, ticker; loop-independent.
- [Audit cards budget shorter](decision-audit-card-budgets-shorter.md): audit-only cards (written deliverables) budget 20-30 min wall-clock, not 60.
- [Auth route toggle](decision-auth-route-toggle.md): per-family subscription/api mode in .autometta.local.yaml; refs in op-refs; op-fetch wrapper.
- [LaunchAgent over cron on macOS](decision-launchagent-over-cron-on-macos.md): per-repo LaunchAgents keep GUI-session keychain credentials available.
- [MCP-served stage cards](decision-mcp-cards.md): MCP not HTTP, git SHAs not server versions, filesystem fallback; design-only until multi-machine.
- [Orchestrator commits on verifier PASS](decision-orchestrator-commits-on-verifier-pass.md): the worker never commits; FAIL leaves the tree.
- [Per-role, per-family SDK transport](decision-per-role-family-sdk-transport.md): card 28; Codex verifier SDK reuses CODEX_HOME auth.
- [Retro-grade is advisory](decision-retro-grade.md): batch retro-grade informs, never gates; it lives in memory.
- [SDK controller experiment](decision-sdk-controller-experiment.md): card 23; cron tick retained over a resident Claude Agent SDK controller.
- [Worker SDK experiment](decision-worker-sdk-experiment.md): card 98; bounded Claude Agent SDK worker route tried and parked.
- [SDK verifier prototype](decision-sdk-verifier-prototype.md): verify-sdk.py probed before touching spawn-verifier.sh; claude -p stayed production.
- [SDK verifier integration](decision-sdk-verifier-integration.md): manifest flag over per-card; cli default; own manifest untouched (15c).
- [SDK verifier prompt caching](decision-sdk-verifier-prompt-cache.md): ephemeral TTL, anthropic library switch, static/variable split, cache busters.
- [Verifier rubric schema](decision-verifier-rubric-schema.md): backward-compatible JSON Schema and manual validator for verifier artefacts.
- [Handoff envelope contract](decision-handoff-envelope.md): JSON file is the sole worker completion signal; mandatory for new stages, legacy kept.
- [Verifier panel design](decision-verifier-panel.md): N=3 majority vote, opt-in, fixed composition for v1 - stage 18 decisions.
- [Sweep stage design](decision-sweep-stage.md): opt-in parallel exploration, synthesis as worker, worktrees; design only, not built (stage 20).
- [Remote monitoring contract](decision-remote-monitoring.md): hosted routines file PRs only; no dispatch authority; three surfaces - stage 21.
- [Codex SDK runs on the subscription](project-codex-sdk-subscription-auth.md): openai-codex reuses chatgpt auth.json; openai-agents are key-only.

## Adopter findings

Banked at `memory/adopters/<repo>/` with analysis-friendly `metadata.run` frontmatter. See `skills/autometta-setup/REFERENCE.md` for the field set.

- [Dirty-tree precondition](adopters/fractals-from-the-90s/feedback-working-tree-precondition.md): outside-files rule trips on any dirty file.
- [Input vs deliverable](adopters/emergence-lab/feedback-card-input-vs-deliverable-when-userintent-needs-both.md): the card is the bug.
- [Worktree-per-run pilot](adopters/emergence-viewer/feedback-worktree-dispatch-thinned-preflight.md): replaces the dirty-tree halt.
- [Sandbox blocks localhost ports](adopters/promo-flow/feedback-sandbox-port-access-verifier-fails.md): server verification fails.
