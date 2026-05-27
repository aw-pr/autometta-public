---
name: decision-launchagent-over-cron-on-macos
description: macOS subscriptions use per-repo LaunchAgents instead of global cron so GUI-session keychain credentials remain available.
metadata:
  type: project
---

macOS repo subscriptions install a per-repo LaunchAgent named `com.autometta.tick.<repo>` instead of relying on a global cron heartbeat. The LaunchAgent plist is generated from `.autometta/launchagent.plist.tpl` in the subscriber repo and installed into `~/Library/LaunchAgents/`.

**Why:** Cron runs outside the user's Aqua GUI session. On macOS that means tools such as Claude Code, 1Password CLI, `gh auth`, or `aws-vault` can fail to read login-keychain credentials even when they work from an interactive terminal. A LaunchAgent runs in the user's GUI launchd session, so `autometta tick` sees the same keychain-backed auth context the operator used when logging in.

**How to apply:** `autometta subscribe <repo>` writes the subscriber yaml and, on Darwin, calls `scripts/install-launchagent.sh`. Non-macOS hosts keep the cron heartbeat fallback. The installed plist is machine-local output; only the repo-local template is committed.

Cross-reference: [[decision-phat-controller-no-daemon-subscriber-registry]], [[decision-single-tick-multi-repo-subscribe]].
