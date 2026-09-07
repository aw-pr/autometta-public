#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Each entry is a category shown to the operator and a path or filename to
# reject. Keep this list together so credential-bearing locations remain easy
# to audit without inspecting any candidate target.
credential_symlink_patterns=(
  "Codex configuration|$HOME/.codex"
  "Codex API configuration|$HOME/.codex-api-only"
  "Autometta configuration|$HOME/.config/autometta"
  "1Password configuration|$HOME/.config/op"
  "auth.json|auth.json"
  ".credentials.json|.credentials.json"
  "1Password reference script|op-refs*.sh"
)

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

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-root.sh
. "$script_dir/resolve-root.sh"
# Self root, not the resolved root: this check answers whether the tree it was launched from is
# complete, so pointing it at a different root would defeat the check.
autometta_root="$(autometta_self_root "$script_dir")"
if [[ -d "$autometta_root/templates" && -d "$autometta_root/scripts" && -x "$autometta_root/bin/autometta" ]]; then
  pass "autometta-root" "$autometta_root"
else
  missing "autometta-root" "run checks from a complete Autometta checkout or installed package"
fi

check_credential_symlinks() {
  local link resolved entry category pattern
  local found=0

  while IFS= read -r -d '' link; do
    resolved="$(readlink -f "$link" 2>/dev/null || true)"
    [[ -n "$resolved" ]] || continue

    for entry in "${credential_symlink_patterns[@]}"; do
      category="${entry%%|*}"
      pattern="${entry#*|}"
      case "$pattern" in
        /*)
          [[ "$resolved" == "$pattern" || "$resolved" == "$pattern/"* ]] || continue
          ;;
        *)
          [[ "${resolved##*/}" == $pattern ]] || continue
          ;;
      esac

      printf 'MISSING credential-symlink %s points to %s\n' "${link#"$autometta_root"/}" "$category"
      found=1
      break
    done
  done < <(find "$autometta_root" -path "$autometta_root/.git" -prune -o -type l -print0)

  if (( found )); then
    status=1
  else
    pass "credential-symlinks" "no credential targets"
  fi
}

check_credential_symlinks

if command -v tmux >/dev/null 2>&1; then
  pass "tmux" "optional attach viewer"
else
  warn "tmux" "optional attach viewer unavailable"
fi

# op-fetch wraps every dispatched agent (auth-route-security skill); required
# by spawn-worker.sh / spawn-verifier.sh. Subscription dispatches use it as a
# pure env sanitiser (env -i + allowlist); api dispatches use it to inject
# only the named OPENAI_API_KEY / ANTHROPIC_API_KEY ref.
if command -v op-fetch >/dev/null 2>&1; then
  pass "op-fetch" "auth-route wrapper present"
else
  missing "op-fetch" "install from the auth-route-security skill (typically ~/Scripts/op-fetch)"
fi

# op (1Password CLI) is what op-fetch ultimately calls.
if command -v op >/dev/null 2>&1; then
  pass "op" "1Password CLI"
else
  missing "op" "install the 1Password CLI"
fi

exit "$status"
