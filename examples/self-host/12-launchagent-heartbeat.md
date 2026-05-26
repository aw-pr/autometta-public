# Stage card 12-launchagent-heartbeat: Per-repo LaunchAgent heartbeat to replace cron on macOS

## Metadata

- **Authored:** 2026-05-26
- **Orchestrator:** Claude Opus 4.7 <claude-opus-4-7@local>
- **Worker:** Codex GPT-5.3 <codex-gpt-5-3@local>
- **Verifier:** Claude Sonnet 4.6 <claude-sonnet-4-6@local>
- **Pairing rationale:** Cross-family. Touches macOS-specific lifecycle (`launchctl`), bash plumbing in scripts/, install path in `autometta` CLI, and per-repo manifest. Claude verifier confirms LaunchAgent bootstrap is correct, plist substitution leaves no absolute paths in the committed template, and the cron fallback still works on non-macOS hosts.

## Surfacing incident

On 2026-05-26 emergence-lab stage 10's verifier died at startup with `Not logged in · Please run /login`, despite an interactively-valid `claude` session. Root cause: cron jobs run in a non-Aqua `launchd` session and macOS Keychain denies them access to the OAuth refresh token that `claude` CLI stores there interactively. Same applies to any 1Password CLI, `gh auth`, `aws-vault`, or similar tool that uses the login keychain as its credential store. The current cellar-installed cron line in `autometta init-host` is therefore fundamentally broken for `claude` workers/verifiers on macOS, and was masked only because earlier stages happened to be dispatched manually from a terminal that did have keychain access.

A LaunchAgent runs inside the user's Aqua GUI session (loaded at login), inherits keychain access, and is the macOS-native equivalent of cron for per-user scheduled work.

## Objective

Replace the cron-based heartbeat on macOS with a per-repo LaunchAgent whose plist template is committed into the subscriber repo (so it lives next to the stage cards and is reviewable as code). Keep cron as the fallback path on non-macOS hosts.

Design choices the worker must follow:

1. **Per-repo, not global.** Each subscriber repo owns its own LaunchAgent label (`com.autometta.tick.<reponame>`) and tick cadence. Allows per-repo cadence tuning, separate enable/disable, and clean teardown when a repo is unsubscribed.

2. **Plist template lives in the subscriber repo** at `.autometta/launchagent.plist.tpl`, with placeholders (`{{REPO_PATH}}`, `{{LABEL}}`, `{{INTERVAL_SECONDS}}`, `{{AUTOMETTA_BIN}}`, `{{LOG_DIR}}`) substituted at install time. The substituted plist is written to `~/Library/LaunchAgents/<label>.plist` and **not** committed; the template is committed.

3. **Aqua session loading** via `launchctl bootstrap gui/$(id -u) <plist>` (modern syntax; not `launchctl load`). Teardown via `launchctl bootout gui/$(id -u)/<label>`.

4. **Cron fallback retained** for non-Darwin hosts: the install path checks `uname` and falls back to the existing cron line when not on macOS. The `autometta init-host` subcommand keeps installing cron on Linux. No double-scheduling: if a LaunchAgent is installed on macOS, the global cron entry for that repo is **not** added (and is removed if it already exists).

5. **Per-repo lifecycle.** `autometta subscribe <repo>` on macOS calls a new `install-launchagent.sh` helper that substitutes the template and bootstraps the agent. A new `autometta uninstall-launchagent <repo>` subcommand bootouts and removes the plist (used by an `unsubscribe` flow — out of scope but the helper is needed).

6. **No new daemons, no API keys.** This card does not change auth mechanics for the underlying CLI; it just changes which scheduler invokes `autometta tick`. The 1Password service-account / `op read op://...` path (mentioned by the operator) is an alternative for genuinely headless hosts and is out of scope here — it would be a sibling card.

## Inputs (read these in your own context)

- `scripts/init-host.sh` — current cron-installation path.
- `scripts/subscribe-repo.sh` — current per-repo registration.
- `scripts/tick.sh` (read-only) — confirms the tick entrypoint signature; do not change tick logic.
- `bin/autometta` — CLI subcommand router.
- `examples/self-host/11-cost-dashboard.md` — most recent self-host card for style reference.
- `docs/setup.md` (if it exists; otherwise `README.md`) — operator-facing install docs.
- `scripts/spawn-worker.sh`, `scripts/spawn-verifier.sh` — confirm the `-C "$repo_root"` cd-fix landed in commit `9e282f3` (this card depends on that fix).

Do not read anything else unless tracing a behaviour question.

## Deliverables

Paths are relative to the autometta repo root.

1. `scripts/install-launchagent.sh` — new helper. Arguments: `<repo_path> [--interval N]`. Behaviour:
   - Detects `uname` ≠ Darwin → exits 0 with a "not macOS, skipping (cron fallback)" log line.
   - Resolves repo's `.autometta/launchagent.plist.tpl`. If missing, copies the canonical template from `templates/launchagent.plist.tpl` into the repo at that path and stages it for the caller to commit (do not commit from this script).
   - Computes `<label>` as `com.autometta.tick.<basename-of-repo>`. Validates label is alphanumeric+dot+dash.
   - Substitutes placeholders, writes substituted plist to `~/Library/LaunchAgents/<label>.plist` with mode 0644.
   - `launchctl bootout gui/$(id -u)/<label> 2>/dev/null || true` first (idempotent), then `launchctl bootstrap gui/$(id -u) <plist>`.
   - Removes any existing cron line for this repo from the user's crontab (only if cron line is present and is exactly the autometta-managed shape; never touch unrelated cron lines).
   - Prints the label and the path to the substituted plist on success.

2. `scripts/uninstall-launchagent.sh` — new helper. Arguments: `<repo_path>`. Computes label, runs `launchctl bootout`, removes the substituted plist file. No-op outside macOS. Does **not** delete the template from the repo.

3. `templates/launchagent.plist.tpl` — canonical template, with the placeholders listed above and these keys:
   - `Label`: `{{LABEL}}`
   - `ProgramArguments`: `{{AUTOMETTA_BIN}}` + `tick`
   - `RunAtLoad`: `true`
   - `StartInterval`: `{{INTERVAL_SECONDS}}` (default 300)
   - `WorkingDirectory`: `{{REPO_PATH}}`
   - `StandardOutPath`: `{{LOG_DIR}}/launchagent.out.log`
   - `StandardErrorPath`: `{{LOG_DIR}}/launchagent.err.log`
   - `EnvironmentVariables`: pass through `PATH` (Homebrew + user-local).

4. `scripts/subscribe-repo.sh` — on macOS, after the existing subscriber yaml is written, invoke `install-launchagent.sh "$repo_path"`. On non-macOS, behaviour unchanged (cron line continues to handle the heartbeat).

5. `scripts/init-host.sh` — on macOS, **do not** install the global cron line. Print an informational note pointing operators at the per-repo LaunchAgent flow. On non-macOS, behaviour unchanged.

6. `bin/autometta` — add two subcommands:
   - `autometta install-launchagent <repo-path> [--interval N]` → calls `install-launchagent.sh`.
   - `autometta uninstall-launchagent <repo-path>` → calls `uninstall-launchagent.sh`.
   Update the `--help` output to list these.

7. `docs/setup.md` (or `README.md` section) — explain the new flow:
   - macOS: per-repo LaunchAgent installed automatically on `autometta subscribe`; plist template lives at `.autometta/launchagent.plist.tpl` and can be customised before re-running install.
   - Non-macOS: cron heartbeat unchanged.
   - Migration: `crontab -l | grep autometta` to spot any existing global cron line; the install script removes it; manual cleanup steps for any pre-existing manual entries.

8. `memory/decision-launchagent-over-cron-on-macos.md` (or similar slug) — short decision memory recording why we switched, with the keychain reasoning. Follow the existing memory file format under `memory/`.

9. `examples/self-host/PLAN.md` — append a row for stage 12, status `done` (filled in by orchestrator on PASS), pointing to this card.

## Constraints

- Do not change `tick.sh` or any worker/verifier logic. This card is scheduler-side only.
- Do not introduce a daemon, persistent server, websocket, or anything that survives shell exit beyond launchd itself.
- Do not write absolute paths into committed files. `templates/launchagent.plist.tpl` is committed; it must use placeholders. The substituted user-local plist is **not** committed — gitignore the substituted output if it ever lands inside the repo accidentally.
- Plist label must be deterministic per repo (`com.autometta.tick.<basename>`); reject names that produce a non-canonical label.
- `launchctl bootstrap` syntax must use `gui/$(id -u)`, not the deprecated `load -w` form. Idempotent re-runs must not error.
- On macOS, after `autometta subscribe <repo>` runs, `launchctl list | grep com.autometta.tick.<basename>` must show the agent and the next-tick countdown should advance.
- On non-macOS hosts, the change must be a strict no-op behaviourally — cron continues to drive ticks.
- No new external dependencies (no `plist` Python lib, no `xmllint` requirement). Use envsubst-style sed substitution with simple `{{KEY}}` placeholders.
- `npm run verify` does not apply (no JS in this repo). Smoke gate: `scripts/health-check.sh` continues to pass, and a manual `autometta tick` from inside an emergence-lab-style subscriber repo continues to dispatch.
- Atomic commit. Author identity tracks the worker.
- Do NOT run `git commit` from the worker. Orchestrator commits on verifier-pass.

## Acceptance criteria

1. `scripts/install-launchagent.sh` exists, is executable, and exits 0 with a "not macOS" log line when run on a host where `uname` ≠ Darwin.
2. On macOS: running `bin/autometta install-launchagent /Users/AnthonyWest/repos/emergence-lab` substitutes the template, writes `~/Library/LaunchAgents/com.autometta.tick.emergence-lab.plist`, bootstraps it under `gui/$(id -u)`, and `launchctl list | grep com.autometta.tick.emergence-lab` produces a line. Repeated runs are idempotent (no errors, plist is re-substituted, agent is re-bootstrapped).
3. `templates/launchagent.plist.tpl` contains no absolute paths and uses placeholders for every host-specific value.
4. `scripts/subscribe-repo.sh` on macOS invokes the install helper after writing the subscriber yaml; on Linux it does not.
5. `scripts/init-host.sh` on macOS does not write a cron line; on Linux it does (unchanged behaviour).
6. `bin/autometta --help` lists `install-launchagent` and `uninstall-launchagent`.
7. `docs/setup.md` (or the `README.md` install section) describes the macOS flow and the non-macOS fallback. The migration note for users with an existing cron entry is present and accurate.
8. A new decision memory under `memory/` records the keychain rationale and references this card.
9. `examples/self-host/PLAN.md` has a row for stage 12 (status to be filled by orchestrator).
10. The cd-fix from commit `9e282f3` is **not** reverted (regression guard).
11. Bundle/package size delta is irrelevant here (shell repo). Worker reports the diff stat (`git diff --stat`) in the verifier handoff.
12. No files outside the deliverables set are modified — except this stage card itself.

## Out of scope

- 1Password service-account `op read`/`op run` integration for headless API-key injection. Worth a sibling card if we ever need a genuinely headless host (Linux server, CI runner) running claude verifiers — but not needed for the macOS Aqua-session case.
- Switching `claude` or `codex` to API-key auth as a primary mechanism.
- `WatchPaths` event-driven dispatch on stage-card directories (instead of `StartInterval`). Nice-to-have for low-latency dispatch but adds plist complexity; defer.
- A GUI for managing per-repo LaunchAgents (next to or inside `autometta dashboard`).
- Lifecycle integration with `autometta unsubscribe <repo>` — that subcommand doesn't exist yet; this card just provides the helper it'll need.
- Cross-user / multi-user installs (assume single-operator machine, per the existing autometta scope).

## Budget

- **Worker wall-clock:** 60 minutes.
- **Verifier wall-clock:** 25 minutes (includes a manual `launchctl bootstrap` + check that the agent fires once).

## Verifier handoff

Worker returns:

- List of modified/created files (`git diff --stat`).
- Confirmation that on a Darwin host the per-repo plist is written, bootstrapped, and visible in `launchctl list`.
- Confirmation that on a non-Darwin host (or with `uname` mocked) the install script no-ops cleanly.
- A one-line confirmation that no `git commit` was invoked from the worker phase.

## Family-specific notes

- Codex worker: `</dev/null` stdin redirect; **do not run `git commit`**. Leave changes uncommitted. Use `-C <repo_root>` semantics where the script wraps further child processes.
- Claude verifier: cross-family. Verify the LaunchAgent actually loads — read `launchctl list` output, check the substituted plist for placeholder leakage. Static-only verification is **not sufficient** for this card; require evidence of a live bootstrap on the verifier's host (or a clear note if the verifier is running in a context where it cannot test that — in which case the verdict is conditional PASS pending operator manual test).
