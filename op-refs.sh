#!/usr/bin/env bash
# Single source of truth for this repo's 1Password references.
# COMMITTED. Placeholders only; sources the private override at the bottom.
#
# Per the auth-route-security skill: no real op:// string, vault name, or
# username appears anywhere in this committed file. Operator copies
# op-refs.local.sh.example -> op-refs.local.sh (gitignored) and replaces
# YOUR_VAULT / YOUR_ITEM placeholders with the real values.
#
# Wrappers source this file and pass the named refs to op-fetch:
#   source "$autometta_root/op-refs.sh"
#   op-fetch OPENAI_API_KEY="$OP_REF_OPENAI_API_KEY" -- codex exec ...

: "${OP_REF_OPENAI_API_KEY:=op://YOUR_VAULT/openai-api-key/credential}"
: "${OP_REF_ANTHROPIC_API_KEY:=op://YOUR_VAULT/anthropic-api-key/credential}"
: "${OP_REF_CLAUDE_CODE_OAUTH_TOKEN:=op://YOUR_VAULT/claude-code-oauth-token/credential}"

# Resolution order for op-refs.local.sh (first existing file wins):
#   1. $AUTOMETTA_LOCAL_REFS  — explicit operator override.
#   2. $XDG_CONFIG_HOME/autometta/op-refs.local.sh  (default
#      $HOME/.config/autometta/op-refs.local.sh) — machine-wide store
#      that the brew-installed CLI can also see.
#   3. Next to this script — the development checkout case.
_xdg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/autometta"
_script_dir=""
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
fi
for _candidate in \
  "${AUTOMETTA_LOCAL_REFS:-}" \
  "$_xdg_dir/op-refs.local.sh" \
  "${_script_dir:+$_script_dir/op-refs.local.sh}"
do
  if [[ -n "$_candidate" && -f "$_candidate" ]]; then
    # shellcheck source=/dev/null
    source "$_candidate"
    break
  fi
done
unset _xdg_dir _script_dir _candidate

export OP_REF_OPENAI_API_KEY OP_REF_ANTHROPIC_API_KEY OP_REF_CLAUDE_CODE_OAUTH_TOKEN
