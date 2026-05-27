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

# Locate this script so we can source the gitignored op-refs.local.sh next
# to it. BASH_SOURCE is bash-specific (and what the autometta spawn scripts
# use); for interactive sourcing from non-bash shells (zsh, fish), fall back
# to AUTOMETTA_ROOT if set, then $PWD.
_h=""
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  _h="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
fi
if [[ -z "$_h" && -n "${AUTOMETTA_ROOT:-}" ]]; then
  _h="$AUTOMETTA_ROOT"
fi
[[ -z "$_h" ]] && _h="$PWD"
[ -f "$_h/op-refs.local.sh" ] && source "$_h/op-refs.local.sh"
unset _h

export OP_REF_OPENAI_API_KEY OP_REF_ANTHROPIC_API_KEY OP_REF_CLAUDE_CODE_OAUTH_TOKEN
