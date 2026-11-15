#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

usage() {
  printf 'Usage: %s [<repo_path>]\n' "$(basename "$0")" >&2
  exit 1
}

resolve_path() {
  local input_path="$1"
  python3 - "$input_path" <<'PY'
import os
import sys
print(os.path.realpath(sys.argv[1]))
PY
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'not macOS, skipping LaunchAgent uninstall\n'
  exit 0
fi

if [[ $# -gt 1 ]]; then
  usage
fi

label="com.autometta.tick.fleet"
if [[ $# -eq 1 ]]; then
  repo_path="$(resolve_path "$1")"
  repo_slug="$(basename "$repo_path")"
  if [[ "$repo_slug" == fleet ]]; then
    printf 'refusing repo named fleet; omit the repo argument to remove com.autometta.tick.fleet\n' >&2
    exit 1
  fi
  label="com.autometta.tick.${repo_slug}"
fi
if [[ ! "$label" =~ ^[A-Za-z0-9.-]+$ ]]; then
  printf 'invalid LaunchAgent label from repo name: %s\n' "$label" >&2
  exit 1
fi

plist_file="$HOME/Library/LaunchAgents/${label}.plist"
uid="$(id -u)"
launchctl bootout "gui/${uid}/${label}" 2>/dev/null || true
rm -f "$plist_file"

printf 'PASS launchagent removed %s\n' "$label"
if [[ $# -eq 1 ]]; then
  printf 'PASS launchagent com.autometta.tick.fleet unaffected\n'
fi
