# Stage card 165: one tick agent for the fleet

## Metadata

- **Authored:** 2026-10-27
- **Orchestrator:** Claude Opus 5.5 <claude-opus-5-5@local>
- **Worker:** GPT-6.1 Sol <gpt-6-1-sol@local>
- **Verifier:** Claude Sonnet 5.5 <claude-sonnet-5-5@local>
- **Base branch:** dev
- **Run branch:** autometta/165-one-tick-agent-for-the-fleet
- **Worker effort:** high
- **Verifier effort:** medium
- **Verifier panel:** false
- **Dispatch:** serial
- **Pairing rationale:** a narrow change to two installer scripts, the CLI's argument checks and two docs, testable offline against a stubbed `launchctl`. Sol writes it and Sonnet verifies cross-family, the pairing that landed 161, 162a and 164 on attempt 1 (operator choice 2026-10-27).
- **Open decisions:** none
- **Cold read:** done 2026-10-27; see Cold read below for the family and findings.

## Surfacing concern

`autometta tick` takes no repo argument: every run walks every subscriber in `$AUTOMETTA_HOME/subscribers/`. But `scripts/install-launchagent.sh <repo>` labels its agent `com.autometta.tick.<repo-basename>` and `scripts/subscribe-repo.sh` calls it once per subscribed repo, so a machine with N subscribers ends up with N LaunchAgents, each a whole-fleet tick. `scripts/status.sh` meanwhile only recognises one agent, `com.autometta.tick.fleet`, which the installer never creates.

Evidence, 2026-10-27: the operator's machine had nine `com.autometta.tick.<repo>` agents at 300 s plus a hand-made `com.autometta.tick.fleet` at 30 s. Two or three ticks were always running at once, the per-repo lock skipped most of the work ("tick already in progress"), the load average sat at 12 to 17 with nothing dispatched, and the day's tick log reached 10,000 lines by 08:00. Reducing to one agent by hand halved the load. Operator decisions the same day: the single agent is `com.autometta.tick.fleet`; installing removes any legacy per-repo agent; the repo argument becomes optional.

## Objective

`autometta install-launchagent` installs exactly one tick LaunchAgent, `com.autometta.tick.fleet`, however many times and for whichever repos it is run, and removes any legacy `com.autometta.tick.<repo>` agent it finds; `autometta uninstall-launchagent` with no argument removes that agent, and with a repo argument removes only that repo's legacy agent.

## Inputs (read these in your own context)

- `scripts/install-launchagent.sh`
- `scripts/uninstall-launchagent.sh`
- `bin/autometta` (the `install-launchagent` and `uninstall-launchagent` cases and the usage text)
- `scripts/status.sh` (first 60 lines: `loop_label`)
- `scripts/subscribe-repo.sh` (the Darwin branch near the end)
- `templates/launchagent.plist.tpl`
- `scripts/launchagent-fleet-smoke.sh`
- `MANUAL.md` (the LaunchAgent rows of the command table)
- `docs/setup.md` (the LaunchAgent section, around lines 150 to 195, and line 460)

Do not read anything else unless you need to; keep your context lean.

## Deliverables

1. `scripts/install-launchagent.sh`: usage `install-launchagent.sh [<repo_path>] [--interval N]`. The label is always `com.autometta.tick.fleet`. A repo argument, when given, must still exist (keep the `MISSING repo` check) but no longer affects the label or log path. The plist is rendered from the canonical `templates/launchagent.plist.tpl` when no repo argument is given, and from the repo's `.autometta/launchagent.plist.tpl` copy as today when one is. Logs go to `$controller_home/log/launchagent.{out,err}.log`. Before bootstrapping, every `$HOME/Library/LaunchAgents/com.autometta.tick.*.plist` other than the fleet one is booted out (`launchctl bootout gui/<uid>/<label>`) and deleted, and each is named on a `PASS removed legacy launchagent <label>` line. Nothing else in that directory is touched.
2. `scripts/uninstall-launchagent.sh`: usage `uninstall-launchagent.sh [<repo_path>]`. With no argument it boots out and removes `com.autometta.tick.fleet`. With a repo argument it boots out and removes only `com.autometta.tick.<repo-basename>`, and prints a line naming `com.autometta.tick.fleet` as unaffected. The repo path need not exist (a removed repo's legacy agent must still be removable). A repo whose basename is `fleet` is refused with a non-zero exit and nothing booted out or removed, since its legacy label would be the fleet label.
3. `bin/autometta`: the `install-launchagent` and `uninstall-launchagent` cases accept zero arguments; the usage lines show the argument as optional.
4. `MANUAL.md` and `docs/setup.md`: describe one fleet LaunchAgent named `com.autometta.tick.fleet`, installed once per machine (subscribing a repo re-runs the installer, which is idempotent), and what the uninstall forms do. Remove "per-repo LaunchAgent", "once for each subscribed repo" and the `com.autometta.tick.<repo-name>` check; the check becomes `launchctl list | grep com.autometta.tick.fleet`.
5. The frozen smoke `scripts/launchagent-fleet-smoke.sh` passes. Do not edit it.

## Constraints

- `scripts/subscribe-repo.sh` keeps calling the installer with the repo path; no change to it is needed.
- `scripts/status.sh` and `scripts/status-loop-smoke.sh` are unchanged; the label they check is the one this card installs.
- `remove_managed_cron_line`, the brew-symlink binary resolution (`AUTOMETTA_LAUNCHAGENT_BIN`), `AUTOMETTA_LAUNCHAGENT_PATH` and the template's `AbandonProcessGroup` stay as they are (CLAUDE.md gotcha 9).
- No change to `scripts/tick.sh`, the subscriber files or the per-repo tick lock.
- Offline only: the card's smoke stubs `launchctl` and `crontab` and works in a temporary `HOME`; nothing touches the real launchd domain or crontab.

## Acceptance criteria

The verifier will check each of these. Failure of any one is a failure of the stage.

1. **Worker and verifier:** `scripts/launchagent-fleet-smoke.sh` exits 0. Its frozen cases: installing for one repo writes only `com.autometta.tick.fleet.plist` (Label, default interval 300, logs at `$AUTOMETTA_HOME/log/launchagent.out.log` and `.err.log`), boots out and deletes two legacy `com.autometta.tick.<repo>` plists and names both on `PASS removed legacy launchagent` lines, bootstraps nothing but the fleet plist, and neither removes nor passes to `launchctl` `com.example.unrelated` or `com.autometta.emergence-lab-stage-114-overnight`; installing for a second repo with `--interval 120` still leaves one tick plist, at 120, rendered from that repo's own template; a missing repo path is refused; `autometta install-launchagent` with no argument works and renders from the canonical template; `autometta uninstall-launchagent <repo>` boots out and removes only that repo's legacy plist and says the fleet agent is unaffected; for a repo named `fleet` it exits non-zero and leaves the fleet agent alone; bare `autometta uninstall-launchagent` removes the fleet plist; `subscribe-repo.sh` still calls the installer and `status.sh` still checks the fleet label; `MANUAL.md` and `docs/setup.md` name the fleet label and no longer describe a per-repo agent. Base: red at the first install assertion (`install did not write com.autometta.tick.fleet.plist`).
2. **Worker and verifier:** `scripts/status-loop-smoke.sh` exits 0. Base: green.
3. **Verifier:** `bash -n` on `scripts/install-launchagent.sh`, `scripts/uninstall-launchagent.sh` and `bin/autometta` passes, and `shellcheck` on the two installer scripts reports nothing beyond the base's two info notes in `install-launchagent.sh` (SC1091 on the `resolve-root.sh` source, SC2016 on the cron regex).

## Contract test

- **Test file:** scripts/launchagent-fleet-smoke.sh
- **Assertions digest:** sha256:2271a26e6f551eed3df67456343d2b26aa0f9df8d6eec83c4dd7b69b4b8f9a8c
- **Oracle proof:** red on `dev` at `992b7c8`: the first install writes `com.autometta.tick.alpha.plist`, so `install did not write com.autometta.tick.fleet.plist` fails first. The real launchd domain was checked unchanged after the run (the smoke stubs `launchctl` and `crontab` on `PATH` and sets `HOME`). Re-proved red at the same assertion after the cold-read additions. No throwaway reference was built: the change is small and every assertion reads a file, a plist key via PlistBuddy or the stub's call log, each written by the code under test; template selection is detected through a `FixtureMarker` key the smoke adds to beta's repo template. The docs assertions were checked against the base wording, which trips them (`MANUAL.md:140`, `docs/setup.md:162` and `:192`). Trap for the worker: `bin/autometta` resolves scripts through `AUTOMETTA_ROOT`, which the smoke points at the worktree, so the CLI cases exercise the worktree's scripts, not the brew install.

## Cold read

Read by GPT-6.1 Sol (Codex, read-only sandbox), 2026-10-27, against the first draft. Every item is folded in:

1. A repo whose basename is `fleet` made Deliverable 2 contradict itself: now refused (Deliverable 2), with an assertion.
2. The smoke did not check that the overnight agent was kept away from `launchctl`, and excluded only named labels from bootstrap: now every bootstrap call must name the fleet plist, and neither non-tick label may appear in the call log.
3. Exact log filenames, template selection, missing-repo rejection, both removal messages, the legacy uninstall's `bootout` and its "unaffected" line were unasserted: each now has an assertion.
4. The constraint claimed every smoke stubs `crontab`: narrowed to the card's smoke.
5. Placeholder left in this section: filled.

Sandbox evidence: the reader found nothing a Codex workspace-write seat cannot run.

## Out of scope

- Overlap between ticks: whether a tick should refuse to start while another holds the fleet, rather than the per-repo lock skipping. The single agent at 300 s removes the observed overlap.
- `scripts/uninstall-launchagent-phat-controller.sh` and the retired controller agent.
- Non-macOS cron install paths.
- Migrating `MANUAL.md` or `docs/setup.md` prose beyond the LaunchAgent rows and section named above.

## Budget

- **Worker wall-clock:** 30 minutes
- **Verifier wall-clock:** 20 minutes
- **Spend basis:** smaller than 164 (about 0.7M tokens across both roles); two short scripts and two doc passages.

## Dispatch envelope

Return the standard envelope: status, the outputs of criteria 1 to 3, and the list of changed files.

## Family-specific notes

The smoke reads plist keys with `/usr/libexec/PlistBuddy` and writes only under `mktemp -d`; both work inside the Codex workspace-write sandbox. Do not run the installer outside the smoke: without the stubs it would load an agent into the operator's real launchd domain.
