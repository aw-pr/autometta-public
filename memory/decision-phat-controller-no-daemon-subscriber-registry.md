---
name: decision-phat-controller-no-daemon-subscriber-registry
description: phat-controller runs as one process per cron fire with no resident daemon. A singleton subscriber registry at ~/.phat-controller/ lists repos by file.
metadata:
  type: project
---

phat-controller is a non-resident program: one process per cron fire, exits when done. A singleton home directory at `${PHAT_CONTROLLER_HOME:-$HOME/.phat-controller}` holds a `subscribers/` directory with one yaml file per subscribed repo, plus a `log/` directory for daily rotated tick logs, plus a `config.yaml` for top-level controller settings.

**Why:** The "cron + tick > daemon" belief from `docs/philosophy.md` is load-bearing: a tick that reads state, makes one transition, writes state, and exits is easier to reason about, debug, kill, and resume than any long-lived process. The subscriber registry needs a discovery surface (the controller has to know which repos to iterate on each fire) but the discovery surface itself should not require a running service. A directory of files is the simplest interface that admits hand-edits, easy unsubscribe (`rm`), and zero IPC.

**How to apply:** Stage 5's `scripts/tick.sh` reads `$PHAT_CONTROLLER_HOME/subscribers/*.yaml`, sorts by the `weight` field, and iterates. Each subscriber file names an absolute repo path, a poll-order weight, and an enabled flag. Subscribing is `cp subscribers/template.yaml subscribers/<repo-slug>.yaml` then editing. Unsubscribing is `rm` of the file. The controller never writes to `subscribers/` itself; that directory is hand-managed.

Cross-reference: [[decision-loop-name-phat-controller]], [[decision-single-tick-multi-repo-subscribe]], [[decision-state-dir-per-repo]].
