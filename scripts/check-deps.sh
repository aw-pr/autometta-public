#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

status=0

pass() {
  local name="$1"
  local reason="${2:-}"
  if [[ -n "$reason" ]]; then
    printf 'PASS %s %s\n' "$name" "$reason"
  else
    printf 'PASS %s\n' "$name"
  fi
}

missing() {
  local name="$1"
  local reason="${2:-required command not found}"
  printf 'MISSING %s %s\n' "$name" "$reason"
  status=1
}

warn() {
  local name="$1"
  local reason="$2"
  printf 'WARN %s %s\n' "$name" "$reason"
}

if command -v bash >/dev/null 2>&1; then
  bash_version="$(bash -c 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"' 2>/dev/null || true)"
  bash_major="$(printf '%s' "$bash_version" | cut -d. -f1)"
  bash_minor="$(printf '%s' "$bash_version" | cut -d. -f2)"
  if [[ "$bash_major" =~ ^[0-9]+$ ]] && [[ "$bash_minor" =~ ^[0-9]+$ ]] && \
     { (( bash_major > 3 )) || { (( bash_major == 3 )) && (( bash_minor >= 2 )); }; }; then
    pass "bash" "version ${bash_version}"
  else
    missing "bash" "version 3.2+ required (autometta scripts do not use bash 4+ features)"
  fi
else
  missing "bash"
fi

for cmd in jq git codex claude python3 yq; do
  if command -v "$cmd" >/dev/null 2>&1; then
    pass "$cmd"
  else
    missing "$cmd"
  fi
done

# agent-whoami is required by tick.sh to attribute state-branch commits to
# the correct per-agent author. It ships from mcp-hub/scripts; if missing,
# install it on PATH (see mcp-hub-dev-rules.md) or symlink from this repo.
if command -v agent-whoami >/dev/null 2>&1; then
  pass "agent-whoami"
else
  missing "agent-whoami" "install from mcp-hub/scripts/agent-whoami onto PATH"
fi

exit "$status"
