#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

self_path="scripts/$(basename "$0")"

for script_path in scripts/*.sh; do
  [[ -e "$script_path" ]] || continue
  [[ "$script_path" == "$self_path" ]] && continue

  if bash -n "$script_path"; then
    printf 'ok: %s\n' "$script_path"
  else
    printf 'fail: %s\n' "$script_path"
    exit 1
  fi
done
