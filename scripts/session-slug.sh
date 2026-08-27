#!/usr/bin/env bash
# Shared tmux session-name slug helper. Sourced by attach.sh (the spawner,
# which builds "autometta-$(session_slug "$repo_path")") and tick.sh (the
# idle-dash reaper, which has to reverse-match a live "autometta-<slug>"
# session name back to a subscriber's repo_path). Both sides must compute
# the same slug for the same path or the reaper and the spawner drift out
# of sync with each other.
session_slug() {
  basename "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^[:alnum:]_.-]/-/g; s/^-*//; s/-*$//'
}
