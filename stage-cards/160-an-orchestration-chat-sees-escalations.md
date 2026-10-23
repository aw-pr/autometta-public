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
- **Cold read:** Codex (GPT-6.1 Sol, read-only) 2026-10-23, with card 161. Its two points are answered: the preserve rationale in deliverable 3 now names the real loss (requeue deletes the run branch) rather than the reaper, and the smoke now asserts an unparseable escalation leaves stderr empty.

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

1. `scripts/hooks/session-start-escalations.sh`: a Claude Code SessionStart hook. It prints nothing and exits 0 when there are no pending escalations. Otherwise it prints a short block: count, then one line per pending escalation (stamp, repo, stage, kind, first summary line, file path), capped at 10 lines with a "+N more" line, then one line naming `scripts/escalations.sh list` and the `autometta-escalations` skill. It filters to the current repo when the working directory is inside a subscriber, and shows all otherwise. "Working directory" is `$CLAUDE_PROJECT_DIR` when set, else `$PWD`; it is inside a subscriber when it equals, or sits below, the `repo_path` of an enabled entry in the subscriber registry (`scripts/subscribers.sh`), and the filter keeps escalations whose frontmatter `repo` is that `repo_path`. Each line carries the stamp (the file name's leading UTC stamp), the repo basename, the stage (or `run`), the kind, the first non-blank body line and the file's absolute path. The hook reads the folder through `escalations_dir` and must not block on stdin (Claude Code passes it session JSON). It never fails the session: any error, including a missing or unreadable folder or an unparseable file, exits 0 silently.
2. `scripts/install-escalation-hook.sh [--check] [--settings <path>]`: idempotently adds the SessionStart hook to the Claude settings file (default the user's `~/.claude/settings.json`), preserving every other key; `--check` reports installed or missing and changes nothing. It writes a timestamped backup `<settings>.bak-<UTC stamp>` before changing an existing file, and writes nothing (no change, no backup) when the hook is already present. The hook entry's command contains the absolute path to `scripts/hooks/session-start-escalations.sh`, resolved at install time. `--check` prints a line containing `installed` and exits 0, or a line containing `missing` and exits 1 (also when the settings file is absent, which it does not create). `scripts/init-host.sh` calls it with `--check` and prints the install command when missing; it does not install silently.
3. `skills/autometta-escalations/SKILL.md`: the orchestration-chat playbook. Trigger phrases include "escalations", "what's stuck", "check the queue", "work the escalations". Procedure: list pending; for each, read the escalation and its evidence; classify (frozen-contract conflict, card defect, implementation defect, infrastructure or quota, halt); propose one decision with a recommendation and wait for the operator's yes on anything that changes a criterion or a frozen contract; act through the existing skills (`autometta-oracle` for re-freezes, `autometta-requeue` for requeues and repair re-briefs, `autometta-card-review` for card defects); `ack` with a one-line note naming the commit or decision. It states that preserving a failed attempt's work must use the preserve path (`preserve_failed_work` in the tick, or `phat-controller.sh preserve`), which pins the attempt on a `wip/<stage>-attempt-N` branch and records `wip_commit`; a hand commit on the run branch is pinned nowhere and is lost when `requeue-stage.sh` deletes `autometta/<stage>`.
4. `skills/phat-controller/SKILL.md`: reduced to a pointer to `autometta-escalations` and a note that the autonomous role is being retired (card 162).
5. `scripts/session-start-escalations-smoke.sh` (frozen, written by the orchestrator; do not edit it): covers the hook (empty, one, twelve, repo filter, broken folder) and the installer (fresh settings, existing hooks preserved, idempotent second run, `--check`), all against temp files.
6. `docs/tick-loop.md`: extend card 159's Escalations section with the hook and the skill.
7. `scripts/phat-controller-smoke.sh`: its "criterion 10" section asserts the phat-controller skill's ownership table, which deliverable 4 removes. Delete only the assertions on `skill_body` there (the ownership table and the two "does not restate" checks); keep the seed and mandate assertions until card 162. Do not touch the frozen card-112 block in that file.

## Constraints

- The installer never runs against the real user settings in the smoke; the smoke passes `--settings` to a temp file.
- The hook makes no network call and starts no agent; it must finish in under one second on a folder of 100 files.
- Hook output is plain text, under 15 lines.
- No absolute home paths in committed files; the default settings path is derived from `$HOME` at run time.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. **Smoke, worker and verifier:** `scripts/session-start-escalations-smoke.sh` exits 0. It also checks that `init-host.sh` calls the installer with `--check`, that the new skill names the hand-off skills, that the phat-controller skill is under 40 lines and points at `autometta-escalations`, that `docs/tick-loop.md` names the hook and the skill, and that the hook takes under one second (best of three) on 100 escalations. Base: red (hook absent).
2. **Card 159 still green, worker and verifier:** `scripts/escalations-smoke.sh` exits 0.
3. **Skill review, verifier:** `skills/autometta-escalations/SKILL.md` covers every step in deliverable 3, names an approval point before any criterion or contract change, and hands off to the named skills rather than restating their procedures.
4. **Lint, worker:** `shellcheck -S warning` exits 0 on the hook, the installer and the smoke (info-level findings do not count).
5. **No regression, worker and verifier:** `scripts/phat-controller-smoke.sh` exits 0 (cards 161 and 162 depend on it). Base: green.

## Contract test

- **Test file:** `scripts/session-start-escalations-smoke.sh`
- **Assertions digest:** `sha256:8b5e134721440cf3026ee7878e4d093b4dfade39e75360f71e2157f39f7f78c8`
- **Oracle proof:** fails on dev at its first assertion (`scripts/hooks/session-start-escalations.sh is missing or not executable`). A throwaway reference built on card 159's throwaway reference passed every assertion, and card 159's smoke stayed green. Mutations tripped their own assertions: no subscriber filter, a 12-line cap, a duplicate install, no backup, ignoring `CLAUDE_PROJECT_DIR`. Traps: card 159's `escalation_write` double-quotes every frontmatter value (`repo: "/path"`), and the fixtures do the same, so match the repo with or without quotes; fixture paths are physical (`pwd -P`) because macOS `mktemp -d` lives under `/var`; the hook must read the escalation folder through `escalations_dir`, so `AUTOMETTA_ESCALATIONS` selects the fixture.

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
