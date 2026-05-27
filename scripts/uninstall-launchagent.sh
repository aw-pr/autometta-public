#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

usage() {
  printf 'Usage: %s <repo_path>\n' "$(basename "$0")" >&2
  exit 1
}

resolve_path() {
  local input_path="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$input_path"
  else
    python3 - "$input_path" <<'PY'
import os
import sys
print(os.path.realpath(sys.argv[1]))
PY
  fi
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'not macOS, skipping LaunchAgent uninstall\n'
  exit 0
fi

if [[ $# -ne 1 ]]; then
  usage
fi

repo_path="$(resolve_path "$1")"
repo_slug="$(basename "$repo_path")"
label="com.autometta.tick.${repo_slug}"
if [[ ! "$label" =~ ^[A-Za-z0-9.-]+$ ]]; then
  printf 'invalid LaunchAgent label from repo name: %s\n' "$label" >&2
  exit 1
fi

plist_file="$HOME/Library/LaunchAgents/${label}.plist"
uid="$(id -u)"
launchctl bootout "gui/${uid}/${label}" 2>/dev/null || true
rm -f "$plist_file"

printf 'PASS launchagent removed %s\n' "$label"
