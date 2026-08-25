#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

log_msg() {
  printf '%s\n' "$1" >&2
}

extract_identity() {
  local card_path="$1"
  local field="$2"
  sed -n "s/^- \\*\\*${field}:\\*\\* //p" "$card_path" | head -n1
}

extract_gate() {
  local card_path="$1"
  local gate_line
  gate_line="$(grep -m1 -E '^- \*\*Gate' "$card_path" || true)"

  if [[ -z "$gate_line" ]]; then
    printf '\t\n'
  elif [[ "$gate_line" =~ ^-\ \*\*Gate:\*\*\ queue-empty([.]([[:space:]].*)?)?$ ]]; then
    printf 'queue_empty\t\n'
  elif [[ "$gate_line" =~ ^-\ \*\*Gate:\*\*\ stage-completed:\ ([0-9]{2}[a-z]*-[a-z0-9-]+)([.]([[:space:]].*)?)?$ ]]; then
    printf 'stage_completed\t%s\n' "${BASH_REMATCH[1]}"
  else
    log_msg "refusing unparseable Gate line: ${gate_line}"
    exit 1
  fi
}

extract_path_claims() {
  local card_path="$1"
  local claims_line claims_text claim
  claims_line="$(grep -m1 -E '^- \*\*Path claims' "$card_path" || true)"

  if [[ -z "$claims_line" ]]; then
    printf '[]\n'
    return 0
  fi
  if [[ ! "$claims_line" =~ ^-\ \*\*Path\ claims:\*\*\ (.+)$ ]]; then
    log_msg "refusing unparseable Path claims line: ${claims_line}"
    exit 1
  fi
  claims_text="${BASH_REMATCH[1]}"

  local claims_json='[]'
  while IFS= read -r claim; do
    claim="$(printf '%s' "$claim" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s:/*$::')"
    if [[ -z "$claim" || "$claim" = /* || "$claim" =~ (^|/)\.\.?(/|$) \
       || "$claim" =~ // || ! "$claim" =~ ^[A-Za-z0-9._/-]+$ ]]; then
      log_msg "refusing unparseable Path claims line: ${claims_line}"
      exit 1
    fi
    claims_json="$(jq -c --arg claim "$claim" '. + [$claim]' <<<"$claims_json")"
  done < <(printf '%s\n' "$claims_text" | tr ',' '\n')

  if [[ "$(jq 'length' <<<"$claims_json")" == "0" ]]; then
    log_msg "refusing unparseable Path claims line: ${claims_line}"
    exit 1
  fi
  jq -c 'unique' <<<"$claims_json"
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

main() {
  if [[ $# -ne 2 ]]; then
    log_msg "usage: $0 <repo-root> <stage-card-path>"
    exit 1
  fi

  local repo_root="$1"
  local stage_card_path="$2"
  local state_path="$repo_root/state/state.yaml"

  if [[ ! -f "$stage_card_path" ]]; then
    log_msg "missing stage card: $stage_card_path"
    exit 1
  fi
  if [[ ! -f "$state_path" ]]; then
    log_msg "missing state file: $state_path"
    exit 1
  fi
  if ! command -v yq >/dev/null 2>&1; then
    log_msg "yq is required"
    exit 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    log_msg "jq is required"
    exit 1
  fi

  local stage_id worker_identity verifier_identity gate_type gate_stage_id gate_json path_claims_json path_claims_state_json exists_count
  stage_id="$(extract_stage_id "$stage_card_path")"
  worker_identity="$(extract_identity "$stage_card_path" "Worker")"
  verifier_identity="$(extract_identity "$stage_card_path" "Verifier")"
  IFS=$'\t' read -r gate_type gate_stage_id < <(extract_gate "$stage_card_path")
  path_claims_json="$(extract_path_claims "$stage_card_path")"
  path_claims_state_json="$(jq -cn --argjson claims "$path_claims_json" \
    '$claims | if length > 0 then {path_claims:.} else {} end')"
  case "$gate_type" in
    stage_completed)
      gate_json="$(jq -cn --arg stage_id "$gate_stage_id" \
        '{gate:{type:"stage_completed",stage_id:$stage_id}}')"
      ;;
    queue_empty)
      gate_json='{"gate":{"type":"queue_empty"}}'
      ;;
    "") gate_json='{}' ;;
  esac

  exists_count="$(STAGE_ID="$stage_id" yq -r '.stages | map(select(.id == strenv(STAGE_ID))) | length' "$state_path")"
  if [[ "$exists_count" != "0" ]]; then
    log_msg "exists: ${stage_id}"
    exit 0
  fi

  STAGE_ID="$stage_id" WORKER="$worker_identity" VERIFIER="$verifier_identity" \
    GATE_JSON="$gate_json" PATH_CLAIMS_STATE_JSON="$path_claims_state_json" yq -i \
    '.stages += [({
      "id": strenv(STAGE_ID),
      "status": "pending",
      "worker": strenv(WORKER),
      "verifier": strenv(VERIFIER),
      "started_at": null,
      "worker_pid": null,
      "verifier_pid": null,
      "verifier_artefact": null,
      "verifier_attempts": 0,
      "completed_at": null
    } + (strenv(GATE_JSON) | from_json)
      + (strenv(PATH_CLAIMS_STATE_JSON) | from_json))]' "$state_path"
  log_msg "added: ${stage_id}"
}

main "$@"
