#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

controller_home="${PHAT_CONTROLLER_HOME:-$HOME/.phat-controller}"
subscribers_dir="$controller_home/subscribers"
controller_log_dir="$controller_home/log"

read_field() {
  local file_path="$1"
  local key="$2"
  local raw
  raw="$(sed -n "s/^${key}:[[:space:]]*//p" "$file_path" | head -n1)"
  raw="${raw%\"}"
  raw="${raw#\"}"
  raw="${raw%\'}"
  raw="${raw#\'}"
  printf '%s' "$raw"
}

pid_state() {
  local pid="$1"
  if [[ -z "$pid" || "$pid" == "null" ]]; then
    printf '-'
  elif kill -0 "$pid" 2>/dev/null; then
    printf 'running:%s' "$pid"
  else
    printf 'stale:%s' "$pid"
  fi
}

latest_stage_log() {
  local repo_root="$1"
  local stage_id="$2"
  local role="$3"
  local path="$repo_root/state/logs/${stage_id}-${role}.log"
  if [[ -f "$path" ]]; then
    printf '%s' "$path"
  else
    printf '-'
  fi
}

state_value() {
  local state_file="$1"
  local filter="$2"
  yq -r "$filter" "$state_file" 2>/dev/null || printf '-'
}

print_repo() {
  local subscriber_file="$1"
  local enabled repo_root repo_name state_file budget_file current_stage halted halt_reason tick_count failures status worker_pid verifier_pid pid_summary log_path

  enabled="$(read_field "$subscriber_file" "enabled")"
  repo_root="$(read_field "$subscriber_file" "repo_path")"
  repo_name="$(basename "$repo_root")"
  state_file="$repo_root/state/state.yaml"
  budget_file="$repo_root/state/budget.json"

  if [[ "$enabled" != "true" ]]; then
    printf '%-24s %-8s %-18s %-14s %-18s %s\n' "$repo_name" "off" "-" "-" "-" "-"
    return 0
  fi

  if [[ ! -f "$state_file" ]]; then
    printf '%-24s %-8s %-18s %-14s %-18s %s\n' "$repo_name" "missing" "-" "-" "-" "$state_file"
    return 0
  fi

  current_stage="$(state_value "$state_file" '.current_stage')"
  halted="$(state_value "$state_file" '.halted // false')"
  halt_reason="$(state_value "$state_file" '.halt_reason // "-"')"
  tick_count="$(state_value "$state_file" '.tick_count // 0')"
  failures="-"
  if [[ -f "$budget_file" ]]; then
    failures="$(jq -r '.consecutive_failures // 0' "$budget_file" 2>/dev/null || printf '-')"
  fi

  if [[ "$current_stage" == "null" || -z "$current_stage" ]]; then
    current_stage="-"
    status="idle"
    pid_summary="-"
    log_path="-"
  else
    status="$(STAGE_ID="$current_stage" state_value "$state_file" '.stages[] | select(.id == strenv(STAGE_ID)) | .status')"
    worker_pid="$(STAGE_ID="$current_stage" state_value "$state_file" '.stages[] | select(.id == strenv(STAGE_ID)) | .worker_pid')"
    verifier_pid="$(STAGE_ID="$current_stage" state_value "$state_file" '.stages[] | select(.id == strenv(STAGE_ID)) | .verifier_pid')"
    if [[ -z "$status" || "$status" == "-" ]]; then
      status="missing-stage-record"
      pid_summary="-"
      log_path="-"
    elif [[ "$verifier_pid" != "null" && "$verifier_pid" != "-" && -n "$verifier_pid" ]]; then
      pid_summary="$(pid_state "$verifier_pid")"
      log_path="$(latest_stage_log "$repo_root" "$current_stage" "verifier")"
    else
      pid_summary="$(pid_state "$worker_pid")"
      log_path="$(latest_stage_log "$repo_root" "$current_stage" "worker")"
    fi
  fi

  if [[ "$halted" == "true" ]]; then
    status="halted:${halt_reason}"
  fi

  printf '%-24s %-8s %-18s %-14s %-18s %s\n' "$repo_name" "on" "$current_stage" "$status" "ticks:${tick_count}/fail:${failures}" "$pid_summary $log_path"
}

main() {
  if [[ ! -d "$subscribers_dir" ]]; then
    printf 'MISSING subscribers dir %s\n' "$subscribers_dir" >&2
    exit 1
  fi
  if ! command -v yq >/dev/null 2>&1; then
    printf 'MISSING yq required for status reads\n' >&2
    exit 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'MISSING jq required for budget reads\n' >&2
    exit 1
  fi

  printf 'phat-controller home: %s\n' "$controller_home"
  if [[ -d "$controller_log_dir" ]]; then
    local latest_log candidate
    latest_log=""
    for candidate in "$controller_log_dir"/tick-*.log; do
      [[ -e "$candidate" ]] || continue
      latest_log="$candidate"
    done
    printf 'latest controller log: %s\n' "${latest_log:-"-"}"
  fi
  printf '\n'
  printf '%-24s %-8s %-18s %-14s %-18s %s\n' "repo" "enabled" "stage" "status" "budget" "process/log"
  printf '%-24s %-8s %-18s %-14s %-18s %s\n' "------------------------" "--------" "------------------" "--------------" "------------------" "-----------"

  local subscriber_file
  for subscriber_file in "$subscribers_dir"/*.yaml; do
    [[ -e "$subscriber_file" ]] || continue
    [[ "$(basename "$subscriber_file")" == "template.yaml" ]] && continue
    print_repo "$subscriber_file"
  done
}

main "$@"
