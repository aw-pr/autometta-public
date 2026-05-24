#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
controller_home="${PHAT_CONTROLLER_HOME:-$HOME/.phat-controller}"
subscribers_dir="$controller_home/subscribers"

usage() {
  printf 'Usage: %s <repo-path>\n' "$(basename "$0")" >&2
  exit 1
}

resolve_path() {
  local input_path="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$input_path"
  else
    python3 - "$input_path" <<'PY'
import os
import sys
print(os.path.realpath(sys.argv[1]))
PY
  fi
}

if [[ $# -ne 1 ]]; then
  usage
fi

repo_path="$(resolve_path "$1")"

if [[ ! -d "$repo_path/.git" ]]; then
  printf 'MISSING git repo %s\n' "$repo_path" >&2
  exit 1
fi

if [[ ! -d "$controller_home" || ! -d "$subscribers_dir" ]]; then
  printf 'Host not initialised at %s. Run scripts/init-host.sh first.\n' "$controller_home" >&2
  exit 1
fi

repo_slug="$(basename "$repo_path")"
subscriber_file="$subscribers_dir/${repo_slug}.yaml"
state_dir="$repo_path/state"
verifiers_dir="$state_dir/verifiers"
logs_dir="$state_dir/logs"
state_file="$state_dir/state.yaml"
budget_file="$state_dir/budget.json"
gitignore_file="$repo_path/.gitignore"

mkdir -p "$state_dir" "$verifiers_dir" "$logs_dir"
printf 'PASS state dirs ready %s\n' "$state_dir"

if [[ -f "$state_file" ]]; then
  printf 'PASS state exists %s\n' "$state_file"
else
  cat > "$state_file" <<'YAML'
version: 1
current_stage: null
stages: []
last_tick_at: "1970-01-01T00:00:00Z"
tick_count: 0
clock_tick_budget_remaining: 100
halted: false
halt_reason: null
YAML
  printf 'PASS state created %s\n' "$state_file"
fi

if [[ -f "$budget_file" ]]; then
  printf 'PASS budget exists %s\n' "$budget_file"
else
  cat > "$budget_file" <<'JSON'
{
  "version": 1,
  "token_cap_total": 1000000,
  "tokens_spent": 0,
  "wall_clock_cap_seconds": 3600,
  "wall_clock_elapsed_seconds": 0,
  "clock_tick_cap": 100,
  "clock_ticks_used": 0,
  "consecutive_failure_cap": 3,
  "consecutive_failures": 0,
  "halted": false,
  "halt_reason": null,
  "halted_at": null
}
JSON
  printf 'PASS budget created %s\n' "$budget_file"
fi

if [[ -f "$gitignore_file" ]]; then
  if grep -Fxq 'state/logs/' "$gitignore_file"; then
    printf 'PASS gitignore entry exists state/logs/\n'
  else
    printf '\nstate/logs/\n' >> "$gitignore_file"
    printf 'PASS gitignore entry added state/logs/\n'
  fi
else
  cat > "$gitignore_file" <<'EOF_GITIGNORE'
state/logs/
EOF_GITIGNORE
  printf 'PASS gitignore created with state/logs/\n'
fi

if [[ -f "$subscriber_file" ]]; then
  printf 'PASS subscriber exists %s\n' "$subscriber_file"
else
  cat > "$subscriber_file" <<YAML
repo_path: "$repo_path"
weight: 100
enabled: true
YAML
  printf 'PASS subscriber created %s\n' "$subscriber_file"
fi

printf 'PASS subscribe complete %s\n' "$repo_path"
