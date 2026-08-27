#!/usr/bin/env bash

set -u
set -o pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
table_path="${1:-$repo_root/docs/verifier-bake-off.md}"

if [[ ! -r "$table_path" ]]; then
  printf 'ERROR: candidate table is not readable: %s\n' "$table_path" >&2
  exit 1
fi

if ! command -v ollama >/dev/null 2>&1; then
  printf 'SKIP: Ollama is not reachable (ollama is not on PATH); candidate viability was not checked.\n'
  exit 0
fi

if ! ollama_listing="$(ollama list 2>/dev/null)"; then
  printf 'SKIP: Ollama is not reachable (ollama list failed); candidate viability was not checked.\n'
  exit 0
fi

candidates="$({
  awk -F '|' '
    /^## The candidate table/ { in_table = 1; next }
    in_table && /^## / { exit }
    in_table && $0 ~ /^\|/ {
      where = $3
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", where)
      if (where != "local Ollama") next

      candidate = $2
      model = $4
      gsub(/^[[:space:]`]+|[[:space:]`]+$/, "", candidate)
      gsub(/^[[:space:]`]+|[[:space:]`]+$/, "", model)
      if (candidate != "" && model != "") print candidate "\t" model
    }
  ' "$table_path"
} || true)"

if [[ -z "$candidates" ]]; then
  printf 'ERROR: no local Ollama candidates found in %s\n' "$table_path" >&2
  exit 1
fi

failed=0
while IFS=$'\t' read -r candidate model; do
  [[ -n "$candidate" && -n "$model" ]] || continue

  if ! printf '%s\n' "$ollama_listing" | awk 'NR > 1 { print $1 }' | grep -qxF "$model"; then
    printf '%s\tmodel=%s\tpulled=no\tthinking=unknown\tdispatchable=no\n' "$candidate" "$model"
    failed=1
    continue
  fi

  if ! model_details="$(ollama show "$model" 2>/dev/null)"; then
    printf '%s\tmodel=%s\tpulled=yes\tthinking=unknown\tdispatchable=no\n' "$candidate" "$model"
    failed=1
    continue
  fi

  if printf '%s\n' "$model_details" | grep -qiE '^[[:space:]]*thinking[[:space:]]*$'; then
    printf '%s\tmodel=%s\tpulled=yes\tthinking=yes\tdispatchable=yes\n' "$candidate" "$model"
  else
    printf '%s\tmodel=%s\tpulled=yes\tthinking=no\tdispatchable=no\n' "$candidate" "$model"
    failed=1
  fi
done <<< "$candidates"

exit "$failed"
