#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./budget.sh
source "$script_dir/budget.sh"

# Token-usage accounting (stage 10).
#
# Verifier dispatch is fire-and-forget: this script backgrounds the
# verifier CLI and exits. Post-exit token parsing therefore lives in
# tick.sh, which reaps the verifier (artefact present, or verifier_pid
# from a prior tick no longer running) and calls
# budget_account_tokens_from_log on the captured verifier log.
#
# The parser handles both:
#   - Codex two-line:  `tokens used` then a digit run (commas tolerated)
#   - Claude inline:   `Total tokens: <N>`
# grep tokens: "tokens used" "Total tokens:"

log_msg() {
  printf '%s\n' "$1" >&2
}

extract_verifier_identity() {
  local card_path="$1"
  sed -n 's/^- \*\*Verifier:\*\* //p' "$card_path" | head -n1
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

verifier_family() {
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
  local stage_id="$3"
  local verifier_identity="$4"
  local artefact_path="$5"
  local template_path="$repo_root/templates/verifier-prompt.md"

  if [[ ! -f "$template_path" ]]; then
    template_path="$script_dir/../templates/verifier-prompt.md"
  fi

  sed \
    -e "s|<<stage-id>>|${stage_id}|g" \
    -e "s|<<stage-card-path>>|${card_path}|g" \
    -e "s|<<artefact-path>>|${artefact_path}|g" \
    -e "s|<<verifier-tier>>|${verifier_identity}|g" \
    -e "s|<<orchestrator-identity>>|phat-controller|g" \
    -e "s|<<family-specific-notes-or-none>>|None|g" \
    "$template_path"
}

update_verifier_state() {
  local state_path="$1"
  local stage_id="$2"
  local pid="$3"
  local artefact="$4"

  if ! command -v yq >/dev/null 2>&1; then
    log_msg "yq missing during verifier dispatch; tick should have halted before reaching here"
    exit 1
  fi
  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    log_msg "refusing to write non-numeric verifier_pid: ${pid}"
    exit 1
  fi
  STAGE_ID="$stage_id" PID="$pid" ARTEFACT="$artefact" yq -i \
    '(.stages[] | select(.id == strenv(STAGE_ID))).verifier_pid = (strenv(PID) | tonumber) | (.stages[] | select(.id == strenv(STAGE_ID))).verifier_artefact = strenv(ARTEFACT)' \
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
  local verifiers_dir="$repo_root/state/verifiers"

  mkdir -p "$logs_dir" "$verifiers_dir"

  local verifier_identity stage_id family log_path artefact_path pid prompt
  verifier_identity="$(extract_verifier_identity "$card_path")"
  stage_id="$(extract_stage_id "$card_path")"
  family="$(verifier_family "$verifier_identity")"
  log_path="$logs_dir/${stage_id}-verifier.log"
  artefact_path="state/verifiers/${stage_id}.json"
  prompt="$(render_prompt "$repo_root" "$card_path" "$stage_id" "$verifier_identity" "$artefact_path")"

  case "$family" in
    codex)
      codex exec --sandbox read-only "$prompt" </dev/null >"$log_path" 2>&1 &
      ;;
    claude)
      claude -p "$prompt" </dev/null >"$log_path" 2>&1 &
      ;;
    *)
      log_msg "unsupported verifier family for identity: ${verifier_identity}"
      exit 1
      ;;
  esac

  pid="$!"
  update_verifier_state "$state_path" "$stage_id" "$pid" "$artefact_path"
  printf '%s\n' "$pid"
}

main "$@"
