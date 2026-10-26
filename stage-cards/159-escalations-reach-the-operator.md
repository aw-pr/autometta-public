# Stage card 159: escalations reach the operator

## Metadata

- **Authored:** 2026-10-23
- **Orchestrator:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Worker:** GPT-6.1 Sol <gpt-6-1-sol@local>
- **Verifier:** Claude Sonnet 5.5 <claude-sonnet-5-5@local>
- **Base branch:** dev
- **Run branch:** autometta/159-escalations-reach-the-operator
- **Worker effort:** high
- **Verifier effort:** high
- **Verifier panel:** false
- **Dispatch:** serial
- **Pairing rationale:** a bounded shell change with smoke-testable behaviour, so a mid tier on each side: Sol writes it on the Codex window, Sonnet verifies cross-family on the Claude window. It touches `scripts/tick.sh`, which is load-bearing, so it dispatches serially (run-design section 4). First in the run because cards 160 to 162 report through it (instrumentation first, run-design section 1).
- **Open decisions:** none
- **Cold read:** Codex (GPT-6.1 Sol, read-only) 2026-10-23; its two questions (controller escalation versus halt episode, shellcheck severity) are answered in Constraints and criterion 4.

## Surfacing concern

Every escalation Autometta raises ends as a log line, a journal entry or a `budget_halt` reason, and nothing puts it in front of the operator. On 2026-10-23 promo-flow card 36 failed twice on frozen-contract contradictions; the second episode's controller proposal sat uncommitted in a card nobody opened, and the overnight monitor gave up 30 minutes later. The same day `~/.autometta` showed the fleet phat-controller LaunchAgent logging "ESCALATION (blocking): spend authority exhausted" every 15 minutes since 2026-10-15, unread for eight days. `pc_escalate_blocking` and `pc_escalate_nonblocking` (`scripts/phat-controller.sh`) only call `log`, `pc_journal_*` and `budget_halt`.

## Objective

Every stage that enters an alert status (`scripts/alert-statuses.sh`: `failed`, `verifier_failed`, `stalled`) and every repo that becomes halted produces exactly one escalation file per episode in a shared folder, plus a desktop notification, so an operator's orchestration chat can pick it up. An episode is one (stage id, status, `started_at`, `verifier_attempts`, `stall_marker`) tuple for a stage, or one (`halt_reason`, halt time) pair for a repo.

## Inputs (read these in your own context)

- `scripts/alert-statuses.sh`
- `scripts/tick.sh` (the per-repo loop and its end-of-tick path; `preserve_failed_work` for what is preserved where)
- `scripts/budget.sh` (`budget_halt` and the `halted` / `halt_reason` fields)
- `scripts/phat-controller.sh` (`pc_escalate_blocking`, `pc_escalate_nonblocking`)
- `scripts/resolve-root.sh` (how `AUTOMETTA_HOME` is resolved)
- `docs/tick-loop.md`
- one existing `scripts/*-smoke.sh` for the smoke idiom, e.g. `scripts/budget-cap-smoke.sh`

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/escalations.sh`, sourceable and executable:
   - `escalations_dir` prints `${AUTOMETTA_ESCALATIONS:-$AUTOMETTA_HOME/escalations}`.
   - `escalation_write <repo> <stage-id-or-empty> <kind> <summary> [detail-file]` writes `pending/<UTC stamp>-<repo basename>-<stage or run>-<kind>.md` with YAML frontmatter (`repo`, `stage`, `kind`, `created`) and a body of the summary, then the detail. The stamp is `date -u +%Y%m%dT%H%M%SZ`; `repo` is the repo root path as given; the stage part is the literal `run` when the stage is empty. A write never overwrites an existing file: a second write in the same second gets a numeric suffix (`...-<kind>-2.md`). An escalation's id is its file name without `.md`. The body includes, when present, the worker envelope's `status` and `notes`, the verifier artefact path, and the paths of `state/uat/<stage>/` and the stage's worker and verifier logs. It sends a desktop notification through `osascript` unless `AUTOMETTA_NOTIFY=0`, and a notification failure never fails the write.
   - `escalations_scan <repo>` compares the repo's current alert-status stages and halt state against a ledger at `<repo>/state/escalated-episodes.json` (gitignored) and calls `escalation_write` once for each episode not yet in the ledger, then records it. For a stage episode the kind is the stage status (`failed`, `verifier_failed`, `stalled`); for a halt it is `halted`, with an empty stage, and the summary names the `halt_reason`.
   - CLI: `escalations.sh list` (pending, oldest first, one line each, the line containing the id), `escalations.sh show <id>`, `escalations.sh ack <id> [note]` (moves the file to `processed/`, appending the note and an `acked` timestamp; an unknown id exits non-zero).
2. `scripts/tick.sh` calls `escalations_scan` once per repo per tick, in `process_repo` after `_process_repo_locked` returns, whichever path it returned by (normal, halted early return or error). The scan never changes `process_repo`'s return code, and a scan failure (for example an unwritable escalations folder) never fails the tick or leaves its lock behind.
3. `pc_escalate_blocking` and `pc_escalate_nonblocking` also call `escalation_write`, with kind `controller-blocking` / `controller-nonblocking`.
4. No `.gitignore` change: `state/**` (`.gitignore` line 22) already covers `state/escalated-episodes.json`, checked 2026-10-23 with `git check-ignore -v`.
5. `scripts/escalations-smoke.sh`, run against a temporary repo fixture and `AUTOMETTA_ESCALATIONS` temp dir with `AUTOMETTA_NOTIFY=0`.
6. `docs/tick-loop.md`: a short "Escalations" section naming the folder, the episode rule, the CLI and the `AUTOMETTA_NOTIFY` switch.

## Constraints

- No agent is dispatched by anything this card adds. The scan is pure shell plus `yq`/`jq`.
- Exactly one file per episode: a second scan of an unchanged repo writes nothing; a requeued stage that fails again (new `started_at`) writes a new one.
- A controller escalation and a scan episode are separate: `pc_escalate_blocking` writes a `controller-blocking` file and halts the repo, and the next scan writes a `halted` file for that halt. Both are intended; the controller is retired in card 162.
- The scan never changes `state/state.yaml` or `state/budget.json`.
- Portable to macOS bash 3.2 only if the rest of `scripts/` already is; follow the existing scripts' shebang and idiom.
- No absolute home paths in committed files.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. **Smoke, worker and verifier:** `scripts/escalations-smoke.sh` exits 0 and asserts: a `failed` stage yields one pending file containing the envelope notes; a second scan yields no new file; a new `started_at`, `verifier_attempts` or `stall_marker` yields a new file; a halted repo yields one `halted` file; `ack` moves a file to `processed/`; `AUTOMETTA_NOTIFY=0` sends nothing, a failing notification fails nothing; the two controller escalation functions write files. The smoke is frozen: do not edit it. Base: red (script absent).
2. **Tick wiring, worker and verifier:** the smoke drives `process_repo` with its side effects stubbed and asserts the scan runs on the halted early-return path and the error path, the return code is unchanged and an unwritable folder fails nothing; `bash -n scripts/tick.sh` passes.
3. **No regression, worker and verifier:** the existing smokes that source `tick.sh` or `phat-controller.sh` still pass: `scripts/phat-controller-smoke.sh`, `scripts/budget-cap-smoke.sh`, `scripts/state-branch-smoke.sh`. Base: green (state-branch-smoke was red on dev until `1cc7742` fixed its fixture on 2026-10-23).
4. **Lint, worker:** `shellcheck -S warning scripts/escalations.sh scripts/escalations-smoke.sh` exits 0. Info-level findings (SC1091 on sourced files, SC2329 on the smoke's stubs) are expected and do not count. Base: the smoke alone exits 0.

## Contract test

- **Test file:** `scripts/escalations-smoke.sh`
- **Assertions digest:** `sha256:4e4cf8dd98b0e9c58e9810de3e1c2a3803181ba4274c91f1677c0cd3f89442d1`
- **Oracle proof:** fails on dev at its first assertion (`scripts/escalations.sh is missing`). A throwaway reference (about 80 lines of shell plus one line each in `tick.sh` and the two controller functions) passed every assertion and left criteria 3's smokes green; mutating the reference (dropping the tick call, letting the scan's status leak into `rc`, dropping the controller write, ignoring `AUTOMETTA_NOTIFY`, overwriting on collision) each tripped its own assertion. Traps the reference met: the fixture repo path is physical (`pwd -P`), because macOS `mktemp -d` lives under `/var`; `tick.sh` is sourced by `phat-controller.sh`, so sourcing `escalations.sh` from `tick.sh` reaches both.

## Out of scope

- Delivering escalations into a chat session (card 160).
- Automatic retries (card 161) and retiring the controller (card 162).
- Phone push notifications; the desktop notification is enough for now.

## Budget

- **Worker wall-clock:** 40 minutes (kill at 60)
- **Verifier wall-clock:** 20 minutes
- **Spend basis:** `state/cost-log.jsonl` on 2026-10-23: autometta role median 1.0M tokens, p95 3.7M across 81 roles. Plan 4M for the stage.

## Dispatch envelope

Write `state/envelopes/159-escalations-reach-the-operator.json` using `schemas/envelope.json`. List changed deliverables, the exact smoke commands and their results, and any criterion you could not satisfy with why. If the card itself is wrong, stop with `status: fail` and say so in `notes` rather than working round it. Do not self-verify or land your own branch. The verifier writes `state/verifiers/159-escalations-reach-the-operator.json` under the existing verifier contract.

## Family-specific notes

None
