#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

if [[ $# -ne 1 ]]; then
  printf 'usage: %s <repo_root>\n' "$(basename "$0")" >&2
  exit 1
fi

repo_root="$(cd "$1" 2>/dev/null && pwd -P)" || {
  printf 'tui: repo not found: %s\n' "$1" >&2
  exit 1
}
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
interval="${AUTOMETTA_TUI_INTERVAL:-5}"
args=("$repo_root" "$script_dir/aggregate-dashboard.sh" --interval "$interval")

if [[ "${AUTOMETTA_TUI_CAPTURE:-false}" == true ]]; then
  args+=(--capture --width "${AUTOMETTA_TUI_COLUMNS:-119}" --height "${AUTOMETTA_TUI_ROWS:-40}")
  [[ -z "${AUTOMETTA_TUI_KEYS:-}" ]] || args+=(--keys "$AUTOMETTA_TUI_KEYS")
  [[ "${AUTOMETTA_TUI_ANSI:-false}" != true ]] || args+=(--ansi)
fi
[[ -z "${AUTOMETTA_TUI_FIXTURE_POLLS:-}" ]] || args+=(--fixture "$AUTOMETTA_TUI_FIXTURE_POLLS")

exec python3 "$script_dir/lib/tui/app.py" "${args[@]}"
