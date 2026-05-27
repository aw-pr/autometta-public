#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# auth-route.sh: emit op-fetch NAME=ref pairs for a worker / verifier family
# based on the configured route. Aligned to the auth-route-security skill —
# per-route fetch only what the route needs, sanitised env via op-fetch.
#
# Usage:
#   pairs="$(scripts/auth-route.sh <family>)"
#   op-fetch $pairs -- <child-command> ...
#
#   <family> := codex | claude
#
# Output:
#   - subscription mode (codex): empty (op-fetch sanitises env; codex
#     reads ~/.codex/auth.json which is unaffected by env strip)
#   - subscription mode (claude): CLAUDE_CODE_OAUTH_TOKEN=$OP_REF_... if
#     the optional ref is set, else empty. op-fetch's env strip drops
#     the session vars `claude -p` needs to reach the macOS Keychain;
#     pinning a setup-token sidesteps keychain access entirely and works
#     from any context (LaunchAgent, cron, stripped-env shells).
#   - api mode: NAME=$OP_REF_NAME ready to splat into op-fetch
#
# Resolution order (most specific wins):
#   1. AUTOMETTA_<FAMILY>_MODE env var override
#   2. auth.<family>.mode in <repo>/.autometta.local.yaml
#   3. hard default: subscription
#
# 1Password references come from op-refs.sh + op-refs.local.sh (see
# the auth-route-security skill). This script does NOT read raw keys; it
# only emits the NAME=ref pair. op-fetch resolves the ref at exec time
# via the service-account token and exec's the child with a sanitised env.

usage() {
  printf 'usage: %s <family>\n' "$(basename "$0")" >&2
  printf '  family: codex | claude\n' >&2
  exit 1
}

[[ $# -eq 1 ]] || usage
family="$1"

case "$family" in
  codex)  ref_var="OP_REF_OPENAI_API_KEY"; env_name="OPENAI_API_KEY" ;;
  claude) ref_var="OP_REF_ANTHROPIC_API_KEY"; env_name="ANTHROPIC_API_KEY" ;;
  *)
    printf 'auth-route: unknown family %q\n' "$family" >&2
    exit 1
    ;;
esac

if [[ -n "${REPO_ROOT:-}" ]]; then
  repo_root="$REPO_ROOT"
else
  repo_root="$PWD"
fi
manifest="$repo_root/.autometta.local.yaml"

# 1. env override
override_var="AUTOMETTA_$(printf '%s' "$family" | tr '[:lower:]' '[:upper:]')_MODE"
mode="${!override_var:-}"

# 2. manifest
if [[ -z "$mode" && -f "$manifest" ]] && command -v yq >/dev/null 2>&1; then
  mode="$(yq -r ".auth.${family}.mode // \"\"" "$manifest" 2>/dev/null || true)"
fi

# 3. default
mode="${mode:-subscription}"

case "$mode" in
  subscription)
    # For claude, emit CLAUDE_CODE_OAUTH_TOKEN if the optional ref is
    # set and resolved (not the YOUR_VAULT placeholder). This is what
    # makes `claude -p` work from op-fetch's stripped env, which
    # otherwise drops the session vars needed for macOS Keychain access.
    # For codex, nothing to emit — codex reads ~/.codex/auth.json.
    if [[ "$family" == "claude" ]]; then
      sub_ref="${OP_REF_CLAUDE_CODE_OAUTH_TOKEN:-}"
      if [[ -n "$sub_ref" && "$sub_ref" != op://YOUR_VAULT/* ]]; then
        printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$sub_ref"
      fi
    fi
    exit 0
    ;;
  api)
    : # fall through to ref emission below
    ;;
  *)
    printf 'auth-route: invalid mode %q for family %s (expected subscription | api)\n' \
      "$mode" "$family" >&2
    exit 1
    ;;
esac

# api mode — emit the NAME=ref pair for op-fetch to resolve.
ref_value="${!ref_var:-}"
if [[ -z "$ref_value" || "$ref_value" == op://YOUR_VAULT/* ]]; then
  printf 'auth-route: %s is unset or unresolved placeholder for family=%s\n' \
    "$ref_var" "$family" >&2
  printf 'auth-route: copy op-refs.local.sh.example to op-refs.local.sh and set the real ref\n' >&2
  exit 1
fi

printf '%s=%s\n' "$env_name" "$ref_value"
