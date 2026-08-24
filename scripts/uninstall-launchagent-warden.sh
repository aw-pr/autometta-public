#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

usage() {
  printf 'Usage: %s\n' "$(basename "$0")" >&2
  exit 1
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'not macOS, skipping warden LaunchAgent uninstall\n'
  exit 0
fi

if [[ $# -ne 0 ]]; then
  usage
fi
label="com.autometta.warden.fleet"

plist_file="$HOME/Library/LaunchAgents/${label}.plist"
uid="$(id -u)"
launchctl bootout "gui/${uid}/${label}" 2>/dev/null || true
rm -f "$plist_file"

printf 'PASS launchagent removed %s\n' "$label"
