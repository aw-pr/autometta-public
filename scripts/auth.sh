#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# auth.sh: backs `autometta auth status` and `autometta auth check`.
# Aligned to the auth-route-security skill — surfaces routes and resolves
# refs through op-fetch / op-refs.sh, never reads raw keys here.
#
# Subcommands:
#   status            Per-family table: mode + redacted ref source.
#   check <family>    Verify the route plumbing without spending a token:
#                     subscription -> "subscription (no key fetch)"
#                     api          -> resolves the ref via op-fetch --print
#                                      and reports PASS with redacted credential.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
autometta_root="$(cd "$script_dir/.." && pwd)"
repo_root="${REPO_ROOT:-$PWD}"
manifest="$repo_root/.autometta.local.yaml"

usage() {
  cat <<'USAGE'
Usage:
  autometta auth status
  autometta auth check <family>

  family: codex | claude
USAGE
  exit 1
}

source_op_refs() {
  if [[ -f "$autometta_root/op-refs.sh" ]]; then
    # shellcheck source=/dev/null
    source "$autometta_root/op-refs.sh"
  fi
}

redact() {
  local value="$1"
  local n=${#value}
  if (( n <= 8 )); then
    printf '****'
  else
    printf '%s****%s' "${value:0:4}" "${value: -2}"
  fi
}

ref_var_for() {
  case "$1" in
    codex)  printf 'OP_REF_OPENAI_API_KEY' ;;
    claude) printf 'OP_REF_ANTHROPIC_API_KEY' ;;
    *) return 1 ;;
  esac
}

env_var_for() {
  case "$1" in
    codex)  printf 'OPENAI_API_KEY' ;;
    claude) printf 'ANTHROPIC_API_KEY' ;;
    *) return 1 ;;
  esac
}

resolve_mode() {
  local family="$1"
  local override_var="AUTOMETTA_$(printf '%s' "$family" | tr '[:lower:]' '[:upper:]')_MODE"
  local mode="${!override_var:-}"
  local provenance=""
  if [[ -n "$mode" ]]; then
    provenance="env"
  elif [[ -f "$manifest" ]] && command -v yq >/dev/null 2>&1; then
    mode="$(yq -r ".auth.${family}.mode // \"\"" "$manifest" 2>/dev/null || true)"
    [[ -n "$mode" ]] && provenance="manifest"
  fi
  if [[ -z "$mode" ]]; then
    mode="subscription"
    provenance="default"
  fi
  printf '%s\t%s' "$mode" "$provenance"
}

cmd_status() {
  source_op_refs
  printf 'Auth routes for repo: %s\n' "$repo_root"
  printf 'Manifest: %s\n' "$([[ -f $manifest ]] && printf '%s' "$manifest" || printf '(none)')"
  printf 'op-refs:  %s\n' "$autometta_root/op-refs.sh ($([[ -f $autometta_root/op-refs.local.sh ]] && printf 'local override present' || printf 'placeholders only'))"
  printf 'op-fetch: %s\n' "$(command -v op-fetch || printf 'MISSING (api mode will fail)')"
  printf '\n'
  printf '%-7s  %-13s  %-10s  %s\n' "Family" "Mode" "Provenance" "Ref / status"
  printf '%-7s  %-13s  %-10s  %s\n' "------" "-------------" "----------" "-------------"
  for family in codex claude; do
    local result mode provenance
    result="$(resolve_mode "$family")"
    mode="${result%%	*}"
    provenance="${result#*	}"
    local ref_status
    if [[ "$mode" == "subscription" ]]; then
      ref_status="-"
    else
      local ref_var
      ref_var="$(ref_var_for "$family")"
      local ref_value="${!ref_var:-}"
      if [[ -z "$ref_value" ]]; then
        ref_status="$ref_var unset"
      elif [[ "$ref_value" == op://YOUR_VAULT/* ]]; then
        ref_status="$ref_var = placeholder (set op-refs.local.sh)"
      else
        ref_status="$ref_var set (op:// redacted)"
      fi
    fi
    printf '%-7s  %-13s  %-10s  %s\n' "$family" "$mode" "$provenance" "$ref_status"
  done
}

cmd_check() {
  local family="${1:-}"
  [[ -n "$family" ]] || usage
  local env_var
  if ! env_var="$(env_var_for "$family")"; then
    printf 'FAIL  unknown family: %s\n' "$family" >&2
    exit 1
  fi

  source_op_refs

  local result mode
  result="$(resolve_mode "$family")"
  mode="${result%%	*}"

  if [[ "$mode" == "subscription" ]]; then
    printf 'subscription  %s  (no key fetch; op-fetch will sanitise env)\n' "$family"
    return 0
  fi

  if [[ "$mode" != "api" ]]; then
    printf 'FAIL          %s  invalid mode: %s\n' "$family" "$mode" >&2
    exit 1
  fi

  local ref_var ref_value
  ref_var="$(ref_var_for "$family")"
  ref_value="${!ref_var:-}"
  if [[ -z "$ref_value" || "$ref_value" == op://YOUR_VAULT/* ]]; then
    printf 'FAIL          %s  %s unset or placeholder (set op-refs.local.sh)\n' "$family" "$ref_var" >&2
    exit 1
  fi
  if ! command -v op-fetch >/dev/null 2>&1; then
    printf 'FAIL          %s  op-fetch not on PATH (api mode requires it)\n' "$family" >&2
    exit 1
  fi
  # op-fetch --print resolves via the service-account token; if that succeeds,
  # the dispatch path will too. The resolved key never lands on disk and is
  # redacted before printing.
  local resolved
  if ! resolved="$(op-fetch --print "$ref_value" 2>/dev/null)" || [[ -z "$resolved" ]]; then
    printf 'FAIL          %s  op-fetch could not resolve %s (1P helper locked / wrong ref / SA token missing)\n' \
      "$family" "$ref_var" >&2
    exit 1
  fi
  printf 'PASS          %s  %s -> %s (env %s)\n' "$family" "$ref_var" "$(redact "$resolved")" "$env_var"
}

[[ $# -ge 1 ]] || usage
sub="$1"
shift
case "$sub" in
  status) cmd_status "$@" ;;
  check)  cmd_check "$@" ;;
  -h|--help|help) usage ;;
  *) printf 'unknown subcommand: %s\n' "$sub" >&2; usage ;;
esac
