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

  local stage_id worker_identity verifier_identity exists_count
  stage_id="$(extract_stage_id "$stage_card_path")"
  worker_identity="$(extract_identity "$stage_card_path" "Worker")"
  verifier_identity="$(extract_identity "$stage_card_path" "Verifier")"

  exists_count="$(STAGE_ID="$stage_id" yq -r '.stages | map(select(.id == strenv(STAGE_ID))) | length' "$state_path")"
  if [[ "$exists_count" != "0" ]]; then
    log_msg "exists: ${stage_id}"
    exit 0
  fi

  STAGE_ID="$stage_id" WORKER="$worker_identity" VERIFIER="$verifier_identity" yq -i \
    '.stages += [{
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
    }]' "$state_path"
  log_msg "added: ${stage_id}"
}

main "$@"
