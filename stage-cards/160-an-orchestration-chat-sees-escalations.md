# Stage card 160: an orchestration chat sees escalations

## Metadata

- **Authored:** 2026-10-23
- **Orchestrator:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Worker:** Claude Sonnet 5.5 <claude-sonnet-5-5@local>
- **Verifier:** GPT-6.1 Sol <gpt-6-1-sol@local>
- **Base branch:** dev
- **Run branch:** autometta/160-an-orchestration-chat-sees-escalations
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Gate:** stage-completed: 159-escalations-reach-the-operator
- **Dispatch:** serial
- **Pairing rationale:** a hook script, an installer and a skill rewrite: prose-heavy, so Sonnet writes it; Sol verifies cross-family and alternates the worker family from card 159. It reads card 159's `scripts/escalations.sh`, hence the gate.
- **Open decisions:** none

## Surfacing concern

The operator orchestrates from interactive Claude Code chats and never reads the TUI message pane or the controller outbox (`docs/proposals/controller-as-correspondent.md`, 2026-08-27: two operator messages sat in `state/phat-controller-inbox/pending/` unanswered). Card 159 writes escalations to a folder; nothing yet brings them into the chat the operator actually uses.

## Objective

Opening a Claude Code session anywhere under a subscriber repo (or the autometta repo) shows the pending escalations, oldest first, as session context; and the operator's orchestration chat has a playbook for working them that replaces the phat-controller skill's autonomous role.

## Inputs (read these in your own context)

- `scripts/escalations.sh` (from card 159)
- `skills/phat-controller/SKILL.md`
- `skills/autometta-requeue/SKILL.md`, `skills/autometta-oracle/SKILL.md`, `skills/autometta-card-review/SKILL.md` (the skills the playbook hands off to)
- `scripts/init-host.sh` (how host setup is installed and checked)
- `docs/proposals/controller-as-correspondent.md`, `docs/proposals/orchestrator-role-review.md`

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/hooks/session-start-escalations.sh`: a Claude Code SessionStart hook. It prints nothing and exits 0 when there are no pending escalations. Otherwise it prints a short block: count, then one line per pending escalation (stamp, repo, stage, kind, first summary line, file path), capped at 10 lines with a "+N more" line, then one line naming `scripts/escalations.sh list` and the `autometta-escalations` skill. It filters to the current repo when the working directory is inside a subscriber, and shows all otherwise. It never fails the session: any error exits 0 silently.
2. `scripts/install-escalation-hook.sh [--check] [--settings <path>]`: idempotently adds the SessionStart hook to the Claude settings file (default the user's `~/.claude/settings.json`), preserving every other key; `--check` reports installed or missing and changes nothing. It writes a timestamped backup before changing the file. `scripts/init-host.sh` calls it with `--check` and prints the install command when missing; it does not install silently.
3. `skills/autometta-escalations/SKILL.md`: the orchestration-chat playbook. Trigger phrases include "escalations", "what's stuck", "check the queue", "work the escalations". Procedure: list pending; for each, read the escalation and its evidence; classify (frozen-contract conflict, card defect, implementation defect, infrastructure or quota, halt); propose one decision with a recommendation and wait for the operator's yes on anything that changes a criterion or a frozen contract; act through the existing skills (`autometta-oracle` for re-freezes, `autometta-requeue` for requeues and repair re-briefs, `autometta-card-review` for card defects); `ack` with a one-line note naming the commit or decision. It states that preserving a failed attempt's work must use the tick's preserve path, not a hand commit that leaves the worktree clean, because a clean failed worktree is reaped.
4. `skills/phat-controller/SKILL.md`: reduced to a pointer to `autometta-escalations` and a note that the autonomous role is being retired (card 162).
5. `scripts/session-start-escalations-smoke.sh`: covers the hook (empty, one, twelve, repo filter, broken folder) and the installer (fresh settings, existing hooks preserved, idempotent second run, `--check`), all against temp files.
6. `docs/tick-loop.md`: extend card 159's Escalations section with the hook and the skill.

## Constraints

- The installer never runs against the real user settings in the smoke; the smoke passes `--settings` to a temp file.
- The hook makes no network call and starts no agent; it must finish in under one second on a folder of 100 files.
- Hook output is plain text, under 15 lines.
- No absolute home paths in committed files; the default settings path is derived from `$HOME` at run time.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. **Smoke, worker and verifier:** `scripts/session-start-escalations-smoke.sh` exits 0. Base: red (absent).
2. **Card 159 still green, worker and verifier:** `scripts/escalations-smoke.sh` exits 0.
3. **Skill review, verifier:** `skills/autometta-escalations/SKILL.md` covers every step in deliverable 3, names an approval point before any criterion or contract change, and hands off to the named skills rather than restating their procedures.
4. **Lint, worker:** `shellcheck` reports no errors on the three new scripts.

## Contract test

- **Test file:** `scripts/session-start-escalations-smoke.sh`
- **Assertions digest:** to be recorded before queueing
- **Oracle proof:** pending: the orchestrating chat authors the frozen block with `autometta-oracle`, proves it red on dev and green on a reference, and records the digest here before queueing.

## Out of scope

- Installing the hook on this machine (the operator runs the installer after landing).
- Pushing escalations into an already-open chat; an open chat watches the folder itself (for example with a Monitor on `escalations.sh list`).
- Removing controller code (card 162).

## Budget

- **Worker wall-clock:** 40 minutes (kill at 60)
- **Verifier wall-clock:** 20 minutes
- **Spend basis:** autometta role median 1.0M tokens, p95 3.7M (2026-10-23). Plan 4M for the stage.

## Dispatch envelope

Write `state/envelopes/160-an-orchestration-chat-sees-escalations.json` using `schemas/envelope.json`. List changed deliverables, the exact smoke commands and their results, and any criterion you could not satisfy with why. If the card itself is wrong, stop with `status: fail` and say so in `notes`. Do not self-verify or land your own branch. The verifier writes `state/verifiers/160-an-orchestration-chat-sees-escalations.json`.

## Family-specific notes

None
