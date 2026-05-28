#!/usr/bin/env bash
# One-shot validator for state/handoffs/*.json.
# Exits 0 for valid envelopes, non-zero with a clear message for invalid ones.
# Usage: scripts/validate-handoff-envelope.sh <path-to-envelope.json>
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
schema="$repo_root/schemas/handoff-envelope.json"

usage() {
  printf 'Usage: %s <path-to-envelope.json>\n' "$0" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
envelope="$1"

if [[ ! -f "$envelope" ]]; then
  printf 'validate-handoff-envelope: file not found: %s\n' "$envelope" >&2
  exit 2
fi

if [[ ! -f "$schema" ]]; then
  printf 'validate-handoff-envelope: schema not found: %s\n' "$schema" >&2
  exit 2
fi

# Require jq for JSON parsing.
if ! command -v jq >/dev/null 2>&1; then
  printf 'validate-handoff-envelope: jq is required but not installed\n' >&2
  exit 2
fi

# Parse the envelope.
if ! jq empty "$envelope" 2>/dev/null; then
  printf 'validate-handoff-envelope: %s is not valid JSON\n' "$envelope" >&2
  exit 1
fi

# Required fields.
stage_id="$(jq -r '.stage_id // empty' "$envelope")"
status="$(jq -r '.status // empty' "$envelope")"
deliverables_type="$(jq -r 'if .deliverables | type == "array" then "array" else "other" end' "$envelope")"
notes="$(jq -r '.notes // empty' "$envelope")"

errors=()

if [[ -z "$stage_id" ]]; then
  errors+=("missing required field: stage_id")
elif ! [[ "$stage_id" =~ ^[0-9]{2}[a-z]*-[a-z0-9-]+$ ]]; then
  errors+=("stage_id '${stage_id}' does not match pattern ^[0-9]{2}[a-z]*-[a-z0-9-]+\$")
fi

if [[ -z "$status" ]]; then
  errors+=("missing required field: status")
elif [[ "$status" != "pass" && "$status" != "fail" && "$status" != "partial" ]]; then
  errors+=("status must be pass|fail|partial, got '${status}'")
fi

if [[ "$deliverables_type" != "array" ]]; then
  errors+=("missing required field: deliverables (must be an array)")
fi

if [[ -z "$notes" ]]; then
  errors+=("missing required field: notes (must be a non-empty string)")
fi

if (( ${#errors[@]} > 0 )); then
  printf 'validate-handoff-envelope: %s\n' "${errors[@]}" >&2
  exit 1
fi

printf 'VALID: stage_id=%s status=%s deliverables=%s\n' \
  "$stage_id" \
  "$status" \
  "$(jq -r '[.deliverables[]] | length' "$envelope")"
exit 0
