#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

controller_home="${PHAT_CONTROLLER_HOME:-$HOME/.phat-controller}"
subscribers_dir="$controller_home/subscribers"
controller_log_dir="$controller_home/log"
status_width="${AUTOMETTA_TICKER_COLUMNS:-${COLUMNS:-$(tput cols 2>/dev/null || printf 120)}}"

print_compact_repo() {
  local repo="$1" enabled="$2" stage="$3" status="$4" budget="$5" process="$6"
  printf '%-*.*s %s %.*s\n' "$((status_width > 12 ? status_width - 12 : 1))" \
    "$((status_width > 12 ? status_width - 12 : 1))" "$repo" "$enabled" 8 "$stage"
  printf '  %-12.12s %-14.14s %.*s\n' "$status" "$budget" \
    "$((status_width > 31 ? status_width - 31 : 1))" "$process"
}

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

# A stage whose run branch could not be fast-forwarded into base is
# completed but not integrated: the commit exists only on autometta/<stage>
# and a person has to merge it. That is the common outcome whenever the
# operator commits to base during a session, and until it was printed here
# the only trace was one appended line in HANDOFF.md. Printed under the
# repo's row rather than in it, because there can be several and the
# operator needs the branch name to act on.
print_awaiting_integration() {
  local state_file="$1"
  [[ -f "$state_file" ]] || return 0
  yq -r '
    .stages[]
    | select(.integration.state == "awaiting")
    | "    awaiting integration: " + .id
      + " -> merge " + (.integration.run_branch // "?")
      + " into " + (.integration.base_branch // "?")
      + " (pushed to origin: " + (.integration.pushed // false | tostring) + ")"
  ' "$state_file" 2>/dev/null || true
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
    if (( status_width < 80 )); then print_compact_repo "$repo_name" off - - - -
    else printf '%-24s %-8s %-18s %-14s %-18s %s\n' "$repo_name" "off" "-" "-" "-" "-"; fi
    return 0
  fi

  if [[ ! -f "$state_file" ]]; then
    if (( status_width < 80 )); then print_compact_repo "$repo_name" missing - - - "$state_file"
    else printf '%-24s %-8s %-18s %-14s %-18s %s\n' "$repo_name" "missing" "-" "-" "-" "$state_file"; fi
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

  if (( status_width < 80 )); then
    print_compact_repo "$repo_name" on "$current_stage" "$status" "tick:${tick_count}/fail:${failures}" "$pid_summary"
  else
    printf '%-24s %-8s %-18s %-14s %-18s %s\n' "$repo_name" "on" "$current_stage" "$status" "ticks:${tick_count}/fail:${failures}" "$pid_summary $log_path"
  fi
  print_awaiting_integration "$state_file"
}

usage() {
  printf 'Usage: %s [--repo <path>]\n' "$(basename "$0")" >&2
  exit 1
}

resolve_path() {
  local input_path="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$input_path" 2>/dev/null || printf '%s' "$input_path"
  else
    python3 - "$input_path" <<'PY' 2>/dev/null || printf '%s' "$input_path"
import os
import sys
print(os.path.realpath(sys.argv[1]))
PY
  fi
}

main() {
  local filter_repo=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        [[ $# -ge 2 ]] || usage
        filter_repo="$(resolve_path "$2")"
        shift 2
        ;;
      -*)
        usage
        ;;
      *)
        usage
        ;;
    esac
  done

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
  if [[ -n "$filter_repo" ]]; then
    printf 'scoped to repo: %s\n' "$filter_repo"
  fi
  printf '\n'
  if (( status_width < 80 )); then
    printf '%.*s\n' "$status_width" 'repo / enabled / stage; status / budget / process'
    printf '%*s\n' "$status_width" '' | tr ' ' '-'
  else
    printf '%-24s %-8s %-18s %-14s %-18s %s\n' "repo" "enabled" "stage" "status" "budget" "process/log"
    printf '%-24s %-8s %-18s %-14s %-18s %s\n' "------------------------" "--------" "------------------" "--------------" "------------------" "-----------"
  fi

  local subscriber_file matched=0
  for subscriber_file in "$subscribers_dir"/*.yaml; do
    [[ -e "$subscriber_file" ]] || continue
    [[ "$(basename "$subscriber_file")" == "template.yaml" ]] && continue
    if [[ -n "$filter_repo" ]]; then
      local sub_repo_path sub_repo_resolved
      sub_repo_path="$(read_field "$subscriber_file" "repo_path")"
      [[ -n "$sub_repo_path" ]] || continue
      sub_repo_resolved="$(resolve_path "$sub_repo_path")"
      [[ "$sub_repo_resolved" == "$filter_repo" ]] || continue
      matched=1
    fi
    print_repo "$subscriber_file"
  done

  if [[ -n "$filter_repo" && "$matched" -eq 0 ]]; then
    printf '(no subscriber matches --repo %s)\n' "$filter_repo"
  fi
}

main "$@"
