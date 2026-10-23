#!/usr/bin/env bash
# Add the escalations SessionStart hook to the Claude settings file.
#
# Usage: install-escalation-hook.sh [--check] [--settings <path>]
#
# Idempotent: nothing is written, and no backup made, when the hook is already
# present. --check reports `installed` (exit 0) or `missing` (exit 1) and
# never creates or changes the file.
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
hook_script="$script_dir/hooks/session-start-escalations.sh"
hook_marker="hooks/session-start-escalations.sh"

settings="$HOME/.claude/settings.json"
check_only=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) check_only=1 ;;
    --settings)
      [[ $# -ge 2 ]] || { printf 'install-escalation-hook: --settings needs a path\n' >&2; exit 2; }
      settings="$2"
      shift
      ;;
    *)
      printf 'Usage: install-escalation-hook.sh [--check] [--settings <path>]\n' >&2
      exit 2
      ;;
  esac
  shift
done

hook_installed() {
  [[ -f "$settings" ]] || return 1
  jq -e --arg marker "$hook_marker" \
    '[.hooks.SessionStart[]?.hooks[]? | select((.command // "") | contains($marker))] | length > 0' \
    "$settings" >/dev/null 2>&1
}

if hook_installed; then
  printf 'installed: escalations SessionStart hook in %s\n' "$settings"
  exit 0
fi
if [[ "$check_only" == 1 ]]; then
  printf 'missing: escalations SessionStart hook in %s\n' "$settings"
  exit 1
fi

[[ -x "$hook_script" ]] || { printf 'install-escalation-hook: %s is not executable\n' "$hook_script" >&2; exit 1; }
command_line="$(printf '%q' "$hook_script")"

mkdir -p "$(dirname "$settings")"
tmp="$(mktemp "$(dirname "$settings")/.settings.XXXXXX")"
trap 'rm -f "$tmp" "$tmp.new"' EXIT
if [[ -f "$settings" ]]; then
  jq -e 'type == "object"' "$settings" >/dev/null \
    || { printf 'install-escalation-hook: %s is not a JSON object; left untouched\n' "$settings" >&2; exit 1; }
  source_json="$settings"
else
  printf '{}\n' > "$tmp"
  source_json="$tmp"
fi
jq --arg command "$command_line" \
  '.hooks.SessionStart = ((.hooks.SessionStart // []) + [{hooks: [{type: "command", command: $command}]}])' \
  "$source_json" > "$tmp.new"
mv "$tmp.new" "$tmp"

if [[ -f "$settings" ]]; then
  cp -p "$settings" "$settings.bak-$(date -u +%Y%m%dT%H%M%SZ)"
fi
cat "$tmp" > "$settings"
printf 'installed: escalations SessionStart hook in %s\n' "$settings"
