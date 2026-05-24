---
name: feedback-stage-6-runtime-bugs
description: Stage 6 first-fire surfaced four issues invisible to static validation. Three fixed in place; one (yq-required-vs-optional) needs an operator decision.
metadata:
  type: feedback
---

Stage 6 dry-run (Option B, infrastructure setup + one tick on an empty backlog) surfaced four issues that the stage-5 and stage-5b static verifiers could not have caught. Three were fixed in place during the dry run; the fourth needs an operator decision.

**1. `check-deps.sh` over-strict on bash version (fixed).** The check required bash >= 4, but the scripts only use POSIX-ish bash features that work on macOS's default bash 3.2.57. Relaxed to bash >= 3.2 in the same commit. Real cost of the original strictness: a fresh macOS host would have failed setup without explanation, pushing the operator to install Homebrew bash unnecessarily.

**2. `tick.sh` subscriber parser did not strip quotes (fixed).** `subscribe-repo.sh` writes `repo_path: "/abs/path"` (quoted); `tick.sh::read_subscriber_field` used a sed strip that left the quotes in the value, so `[[ -d "$repo_path" ]]` failed on a literal quote-wrapped string. Patched `read_subscriber_field` to strip surrounding single or double quotes. Accepts both quoted and unquoted forms (template.yaml uses unquoted).

**3. `tick.sh` iterated `template.yaml` as a subscriber (fixed).** The `subscribers/*.yaml` glob picked up the example template that init-host.sh writes alongside real subscriber files. Added a basename check skipping `template.yaml` in `sort_subscribers`.

**4. `yq` is functionally required despite being marked optional (NOT fixed; needs decision).** `check-deps.sh`, the README setup, and the design all say `yq` is optional. But `tick.sh::state_apply_json` calls `yq -P` unconditionally for state.yaml writes, and the stage-5a hardening then halts cleanly via `budget_halt "$repo_root" "yq-missing"` when it is absent. The hardening worked exactly as designed (clean halt with reason, not a silent crash), but the underlying contradiction remains. Three resolution options:

- (a) Mark `yq` as required everywhere (check-deps, docs/setup.md section 1, README mention, design doc). Simplest, most honest. One `brew install yq` for operators.
- (b) Replace yq with a pure-shell yaml writer. `state.yaml` has a fixed shape; a cat-heredoc per state field is feasible but verbose. Removes the dep but adds maintenance.
- (c) Replace `state.yaml` with `state.json` so jq alone suffices. Larger surgery (schema rename, subscribe-repo.sh writes JSON, tick.sh re-plumbs every yaml read/write) but technically cleanest.

**Why:** First time the loop ran on a clean machine. Static verifiers checked `bash -n` and structural patterns; they could not check inter-script contracts or actual filesystem behaviour. Stage 6 is exactly the stage that catches these classes of bug.

**How to apply:** When implementing pass-2 scripts, parallel operator-style smoke tests (run check-deps, init-host, subscribe-repo end-to-end in CI or in a fresh container) would catch issues 1-3 mechanically. Issue 4 needs a human read of "is this dep truly optional?" before declaring it so.

Cross-reference: [[feedback-stage-5-silent-failure-risks]] (where the yq-required issue was first flagged but resolved at the halting layer, not at the dependency-marking layer); [[feedback-init-script-macos-specific]] (other portability concern).
