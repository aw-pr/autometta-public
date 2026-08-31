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
#   mode="$(scripts/auth-route.sh <family> --print-mode)"
#
#   pairs="$(scripts/auth-route.sh <family> --role verifier)"
#
#   <family> := codex | claude
#   <role>   := worker | verifier
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
#   - local mode (codex only): empty, like subscription. The dispatch still
#     goes through op-fetch so a stray OPENAI_API_KEY in the parent env is
#     stripped and cannot silently rebill a "local" run to the API.
#   - --print-mode: prints the resolved mode word itself (subscription |
#     api | local) instead of the pairs, for a caller that needs to branch
#     its dispatch command on the route rather than just fetch credentials.
#
# Resolution order (most specific wins):
#   1. AUTOMETTA_<FAMILY>_MODE_<ROLE> env var override (when --role is given)
#   2. AUTOMETTA_<FAMILY>_MODE env var override
#   3. auth.<family>.<role>.mode in <repo>/.autometta.local.yaml
#   4. auth.<family>.mode in <repo>/.autometta.local.yaml
#   5. hard default: subscription
#
# The per-role keys exist so the two sides of a gate can sit on different
# routes. The case that wants it is a local worker facing a cloud verifier:
# free weights write the code, a metered model judges it. A family-wide mode
# cannot say that, and same-family same-weights verification is the worker
# marking its own homework.
#
# local is codex-family only: it runs `codex exec --oss` against Ollama, a
# different CLI path than the api/subscription codex branches. A Claude-family
# local route would be a different CLI (no `claude --oss` equivalent) and is
# refused with a clear message rather than silently falling back.
#
# 1Password references come from op-refs.sh + op-refs.local.sh (see
# the auth-route-security skill). This script does NOT read raw keys; it
# only emits the NAME=ref pair. op-fetch resolves the ref at exec time
# via the service-account token and exec's the child with a sanitised env.

usage() {
  printf 'usage: %s <family> [--print-mode] [--role worker|verifier]\n' "$(basename "$0")" >&2
  printf '  family: codex | claude\n' >&2
  exit 1
}

[[ $# -ge 1 ]] || usage
family="$1"
shift
print_mode_only=0
role=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --print-mode) print_mode_only=1; shift ;;
    --role)
      [[ $# -ge 2 ]] || usage
      role="$2"
      case "$role" in
        worker|verifier) ;;
        *) printf 'auth-route: unknown role %q (expected worker | verifier)\n' "$role" >&2; exit 1 ;;
      esac
      shift 2
      ;;
    *) usage ;;
  esac
done

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

family_upper="$(printf '%s' "$family" | tr '[:lower:]' '[:upper:]')"

# 1. per-role env override
override_var="AUTOMETTA_${family_upper}_MODE"
mode=""
mode_source=""
if [[ -n "$role" ]]; then
  role_override_var="AUTOMETTA_${family_upper}_MODE_$(printf '%s' "$role" | tr '[:lower:]' '[:upper:]')"
  mode="${!role_override_var:-}"
  [[ -n "$mode" ]] && { override_var="$role_override_var"; mode_source="env:$role_override_var"; }
fi

# 2. family-wide env override
if [[ -z "$mode" ]]; then
  mode="${!override_var:-}"
  mode_source="env:$override_var"
fi

# 3. manifest, per-role key then family-wide
if [[ -z "$mode" && -f "$manifest" ]] && command -v yq >/dev/null 2>&1; then
  if [[ -n "$role" ]]; then
    mode="$(yq -r ".auth.${family}.${role}.mode // \"\"" "$manifest" 2>/dev/null || true)"
    [[ -n "$mode" ]] && mode_source="manifest:$manifest (auth.${family}.${role}.mode)"
  fi
  if [[ -z "$mode" ]]; then
    mode="$(yq -r ".auth.${family}.mode // \"\"" "$manifest" 2>/dev/null || true)"
    [[ -n "$mode" ]] && mode_source="manifest:$manifest"
  fi
fi

# 4. default
if [[ -z "$mode" ]]; then
  mode="subscription"
  mode_source="default"
fi

if [[ "$mode" == "local" && "$family" != "codex" ]]; then
  printf 'auth-route: auth.%s.mode: local is refused; the local route is codex-family only (a Claude-family local route would need a different CLI and a different card)\n' \
    "$family" >&2
  exit 1
fi

if [[ "$print_mode_only" -eq 1 ]]; then
  printf '%s\n' "$mode"
  exit 0
fi

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
  local)
    # codex only (enforced above). No pairs, like subscription: op-fetch
    # still runs the dispatch through env -i + allowlist, so a stray
    # OPENAI_API_KEY in the parent env is stripped rather than silently
    # rebilling a "local" run to the API.
    exit 0
    ;;
  api)
    # Metered billing spends real API credit, not subscription quota. An
    # explicit env override is a deliberate choice; a manifest-sourced api
    # mode is the silent-flip vector (the manifest is gitignored and
    # agent-writable), so warn loudly and name the source at dispatch time.
    if [[ "$mode_source" == manifest:* ]]; then
      printf 'auth-route: WARNING family=%s resolved to METERED api billing from %s — this spends metered API credit, NOT subscription quota. If unintended, set %s=subscription or remove auth.%s.mode from the manifest.\n' \
        "$family" "$mode_source" "$override_var" "$family" >&2
    else
      printf 'auth-route: note family=%s using metered api billing (source=%s)\n' \
        "$family" "$mode_source" >&2
    fi
    # fall through to ref emission below
    ;;
  *)
    printf 'auth-route: invalid mode %q for family %s (expected subscription | api | local)\n' \
      "$mode" "$family" >&2
    exit 1
    ;;
esac

# api mode — emit the NAME=ref pair for op-fetch to resolve.
ref_value="${!ref_var:-}"
if [[ -z "$ref_value" || "$ref_value" == op://YOUR_VAULT/* ]]; then
  printf 'auth-route: %s is unset or unresolved placeholder for family=%s\n' \
    "$ref_var" "$family" >&2
  printf 'auth-route: copy templates/op-refs.local.sh.tpl to op-refs.local.sh and set the real ref\n' >&2
  exit 1
fi

printf '%s=%s\n' "$env_name" "$ref_value"
