#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log_msg() {
  printf '%s\n' "$1" >&2
}

extract_worker_identity() {
  local card_path="$1"
  sed -n 's/^- \*\*Worker:\*\* //p' "$card_path" | head -n1
}

extract_stage_id() {
  local card_path="$1"
  local base
  base="$(basename "$card_path")"
  base="${base%.md}"
  if [[ ! "$base" =~ ^[0-9]{2}[a-z]*-[a-z0-9-]+$ ]]; then
    log_msg "rejecting malformed stage id derived from ${card_path}: ${base}"
    exit 1
  fi
  printf '%s\n' "$base"
}

worker_family() {
  local identity="$1"
  if [[ "$identity" == *Codex* || "$identity" == *GPT* ]]; then
    printf 'codex\n'
  elif [[ "$identity" == *Claude* ]]; then
    printf 'claude\n'
  else
    printf 'unknown\n'
  fi
}

render_prompt() {
  local repo_root="$1"
  local card_path="$2"
  local worker_identity="$3"
  local template_path="$repo_root/templates/worker-prompt.md"
  local project_name

  if [[ ! -f "$template_path" ]]; then
    template_path="$script_dir/../templates/worker-prompt.md"
  fi
  project_name="$(basename "$repo_root")"

  sed \
    -e "s|<<worker-tier>>|${worker_identity}|g" \
    -e "s|<<project-name>>|${project_name}|g" \
    -e "s|<<orchestrator-identity>>|phat-controller|g" \
    -e "s|<<stage-card-path>>|${card_path}|g" \
    -e "s|<<family-specific-notes-or-none>>|None|g" \
    "$template_path"
}

update_stage_worker_pid() {
  local state_path="$1"
  local stage_id="$2"
  local pid="$3"

  if ! command -v yq >/dev/null 2>&1; then
    log_msg "yq missing during worker dispatch; tick should have halted before reaching here"
    exit 1
  fi
  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    log_msg "refusing to write non-numeric worker_pid: ${pid}"
    exit 1
  fi
  STAGE_ID="$stage_id" PID="$pid" yq -i \
    '(.stages[] | select(.id == strenv(STAGE_ID))).worker_pid = (strenv(PID) | tonumber) | .current_stage = strenv(STAGE_ID)' \
    "$state_path"
}

main() {
  if [[ $# -ne 2 ]]; then
    log_msg "usage: $0 <stage-card-path> <repo-root>"
    exit 1
  fi

  local card_path="$1"
  local repo_root="$2"
  local state_path="$repo_root/state/state.yaml"
  local logs_dir="$repo_root/state/logs"

  mkdir -p "$logs_dir"

  local worker_identity stage_id family prompt log_path pid
  worker_identity="$(extract_worker_identity "$card_path")"
  stage_id="$(extract_stage_id "$card_path")"
  family="$(worker_family "$worker_identity")"
  prompt="$(render_prompt "$repo_root" "$card_path" "$worker_identity")"
  log_path="$logs_dir/${stage_id}-worker.log"

  case "$family" in
    codex)
      codex exec --sandbox workspace-write "$prompt" </dev/null >"$log_path" 2>&1 &
      ;;
    claude)
      claude -p "$prompt" </dev/null >"$log_path" 2>&1 &
      ;;
    *)
      log_msg "unsupported worker family for identity: ${worker_identity}"
      exit 1
      ;;
  esac

  pid="$!"
  update_stage_worker_pid "$state_path" "$stage_id" "$pid"
  printf '%s\n' "$pid"
}

main "$@"
