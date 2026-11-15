---
name: decision-launchagent-over-cron-on-macos
description: macOS subscriptions use a LaunchAgent instead of global cron so GUI-session keychain credentials remain available; one fleet agent since card 165.
metadata:
  type: project
---

macOS repo subscriptions install a LaunchAgent instead of relying on a global cron heartbeat. Since card 165 (2026-10-27) that is one fleet agent per machine, `com.autometta.tick.fleet`: every tick walks every subscriber, so the earlier per-repo `com.autometta.tick.<repo>` agents only ran overlapping whole-fleet ticks, and the installer now removes them. The plist is rendered from the subscriber repo's `.autometta/launchagent.plist.tpl` (seeded from `templates/launchagent.plist.tpl` when absent), or from the canonical template when no repo is named, and installed into `~/Library/LaunchAgents/`.

**Why:** Cron runs outside the user's Aqua GUI session. On macOS that means tools such as Claude Code, 1Password CLI, `gh auth`, or `aws-vault` can fail to read login-keychain credentials even when they work from an interactive terminal. A LaunchAgent runs in the user's GUI launchd session, so `autometta tick` sees the same keychain-backed auth context the operator used when logging in.

**How to apply:** `autometta subscribe <repo>` writes the subscriber yaml and, on Darwin, calls `scripts/install-launchagent.sh`. Non-macOS hosts keep the cron heartbeat fallback. The installed plist is machine-local output; only the repo-local template is committed.

Cross-reference: [[decision-phat-controller-no-daemon-subscriber-registry]], [[decision-single-tick-multi-repo-subscribe]].
