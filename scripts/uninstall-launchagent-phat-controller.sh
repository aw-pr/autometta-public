#!/usr/bin/env bash
# Remove the retired phat-controller LaunchAgent. Kept so a machine that still
# has one installed can clean up; safe to run when nothing is installed.
set -euo pipefail
IFS=$'\n\t'

usage() {
  printf 'Usage: %s\n' "$(basename "$0")" >&2
  exit 1
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'not macOS, skipping phat-controller LaunchAgent uninstall\n'
  exit 0
fi

if [[ $# -ne 0 ]]; then
  usage
fi
label="com.autometta.phat-controller.fleet"

plist_file="$HOME/Library/LaunchAgents/${label}.plist"
uid="$(id -u)"
launchctl bootout "gui/${uid}/${label}" 2>/dev/null || true
if [[ -e "$plist_file" ]]; then
  rm -f "$plist_file"
  printf 'PASS launchagent removed %s\n' "$label"
else
  printf 'PASS launchagent %s not installed, nothing to remove\n' "$label"
fi
