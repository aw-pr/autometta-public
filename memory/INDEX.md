# memory/INDEX.md

One line per memory file. Keep entries <=150 chars: `- [Title](file.md): one-line hook`.

<!-- entries below this line -->
- [Sub-agent budget enforcement weak](feedback-subagent-budget-enforcement.md): Task-tool budgets are advisory; tighten scope, don't trust the brief.
- [Style constraints need pre-verifier check](feedback-style-constraints-pre-check.md): em-dash + AI-tell scan before verifier, not after; same-family writers are blind to their own usage.
- [Cross-family verification validated](project-cross-family-verification-validated.md): Stage 0 confirmed: Codex caught style faults Claude couldn't see in its own prose.
- [Stage card exempt from "no outside files" criterion](feedback-acceptance-criterion-stage-card-exemption.md): Stage 2 lesson: orchestrator-authored stage card always lives outside the worker's deliverables dir; criteria must exempt it.
- [Loop name is phat-controller](decision-loop-name-phat-controller.md): Pass-2 loop layer naming decision.
- [Single tick, multi-repo subscribe](decision-single-tick-multi-repo-subscribe.md): One cron tick model, repos subscribe.
- [Identity via orchestrator skill](decision-identity-via-orchestrator-skill.md): Maintain cross-family identity equivalents.
- [Verifier handoff naming](decision-verifier-handoff-naming.md): Handoff artefact name is verifiers.
- [Failure budget via clock ticks](decision-failure-budget-clock-tick.md): Per-repo timeout counts use filesystem state.
- [state/ dir per repo](decision-state-dir-per-repo.md): All per-repo phat-controller state lives in state/ at the repo root.
- [No daemon, subscriber registry](decision-phat-controller-no-daemon-subscriber-registry.md): phat-controller is one-shot per cron fire; subscribers listed by file in ~/.phat-controller/.
- [Tick implementation parameters](decision-tick-implementation-parameters.md): Branch `phat-controller/state`, `tick.sh --repair`, `~/.phat-controller/config.yaml`, stall grace 1.5x.
- [Verifier prompt mirrors stage card](feedback-verifier-prompt-mirrors-stage-card.md): Stage 4 lesson: enumerate the stage card's permission rules in the verifier prompt, not a frozen file list.
- [Stage 5 silent-failure risks](feedback-stage-5-silent-failure-risks.md): yq-abort, git-checkout-B-discards, no stall-by-elapsed-time. Fix before stage 6.
- [Stage card paths must be relative](feedback-stage-card-paths-relative.md): Never bake /Users/... into a card; template + checklist now enforce it.
- [init-host macOS-specific stat](feedback-init-script-macos-specific.md): scripts/init-host.sh:25 uses BSD `stat -f`; Linux portability needs a branch.
- [Stage 6 runtime bugs](feedback-stage-6-runtime-bugs.md): First-fire surfaced 4 issues; 3 fixed in place, yq required-vs-optional needs operator decision.
- [state.yaml leaks home path](feedback-state-yaml-leaks-home-path.md): Committed-audit-trail design conflicts with publish-guard. state/ provisionally gitignored.
- [tick.sh switches working-dir branch](feedback-tick-switches-working-dir-branch.md): Interactive tick leaves operator on phat-controller/state branch. Cron-safe, interactive-unsafe.
- [Verifier dispatch impoverished](feedback-verifier-dispatch-impoverished.md): spawn-verifier.sh builds a one-sentence prompt with no criteria, inputs, or schema. Need templates/verifier-prompt.md.
- [Tick respawns verifier while worker running](feedback-tick-respawns-verifier-while-worker-running.md): No kill -0 process-alive check; stacks verifier processes during long workers.
- [Skills layout: agent-orchestrator + autometta-setup](decision-skills-layout-autometta-setup.md): Keep general orchestrator skill; add a sibling autometta-setup skill for repo adoption.

## Adopter findings

Banked at `memory/adopters/<repo>/` with analysis-friendly `metadata.run` frontmatter. See `skills/autometta-setup/REFERENCE.md` for the field set.

- [Working-tree precondition for criterion-10](adopters/fractals-from-the-90s/feedback-working-tree-precondition.md): fractals stage 01. Criterion "no files outside deliverables" fires on any dirty tracked file; clean working tree before dispatch.
- [Verifier rubric schema](decision-verifier-rubric-schema.md): Why verifier artefacts have a backward-compatible JSON Schema and manual validator.
- [SDK verifier integration decisions](decision-sdk-verifier-integration.md): Why manifest flag over per-card, why cli default, why not mutate autometta's own manifest for 15c.
